//
//  SystemAudio.swift
//  tabmenu
//

import CoreAudio
import Foundation

nonisolated struct AudioOutputDevice: Identifiable, Equatable, Sendable {
    let id: AudioDeviceID
    let name: String
}

/// Reads and controls the audio hardware through CoreAudio.
///
/// Used instead of AppleScript because several callers react to key presses, where a process
/// spawn per keystroke would be far too slow.
nonisolated enum SystemAudio {
    // MARK: - Output volume

    static func outputVolume() -> Double? {
        guard let device = defaultOutputDevice() else { return nil }
        if isMuted(device) { return 0 }

        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
        return status == noErr ? Double(volume) : nil
    }

    static func setOutputVolume(_ value: Double) {
        guard let device = defaultOutputDevice() else { return }
        var volume = Float32(min(max(value, 0), 1))
        let size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectSetPropertyData(device, &address, 0, nil, size, &volume)
    }

    // MARK: - Output devices

    /// Every device that can play audio, for the switcher in the notch.
    static func outputDevices() -> [AudioOutputDevice] {
        allDevices().compactMap { device in
            guard hasStreams(device, scope: kAudioDevicePropertyScopeOutput),
                  let name = deviceName(device)
            else { return nil }
            return AudioOutputDevice(id: device, name: name)
        }
    }

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        defaultOutputDevice()
    }

    /// UID of the current default output, needed to anchor mixer aggregates to it.
    static func defaultOutputDeviceUID() -> String? {
        guard let device = defaultOutputDevice() else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var reference: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &reference) == noErr,
              let reference
        else { return nil }
        return reference.takeRetainedValue() as String
    }

    static func setDefaultOutputDevice(_ id: AudioDeviceID) {
        var device = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &device)
    }

    // MARK: - Microphone

    /// Processes currently capturing audio input, for the caller to judge.
    ///
    /// Uses the per-process object list rather than device "running somewhere": a combined
    /// headset reports itself running while merely playing music, which would make every
    /// song look like an open microphone. Raw results still include system daemons — Siri's
    /// wake-word listener holds an input stream around the clock — so the caller filters.
    static func microphoneCaptureCandidates() -> [(pid: pid_t, bundleID: String?)] {
        AudioProcessRegistry.snapshot()
            .filter { process in
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioProcessPropertyIsRunningInput,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var running: UInt32 = 0
                var size = UInt32(MemoryLayout<UInt32>.size)
                return AudioObjectGetPropertyData(process.objectID, &address, 0, nil, &size, &running) == noErr
                    && running == 1
            }
            .map { ($0.pid, $0.bundleID) }
    }

    static func isInputMuted() -> Bool {
        guard let device = defaultInputDevice() else { return false }
        var address = inputMuteAddress()
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr else { return false }
        return muted == 1
    }

    /// Flips the system-wide microphone mute and returns the new state, or `nil` when the
    /// toggle could not happen: no input device, mute not settable, or the write failed.
    @discardableResult
    static func toggleInputMute() -> Bool? {
        guard let device = defaultInputDevice() else { return nil }
        var address = inputMuteAddress()

        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else {
            return nil
        }

        var muted: UInt32 = isInputMuted() ? 0 : 1
        let size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectSetPropertyData(device, &address, 0, nil, size, &muted) == noErr else { return nil }
        return muted == 1
    }

    // MARK: - Devices

    private static func allDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices
        ) == noErr else { return [] }
        return devices
    }

    private static func hasStreams(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func deviceName(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name
        else { return nil }
        return name.takeRetainedValue() as String
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    }

    private static func defaultInputDevice() -> AudioDeviceID? {
        defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
    }

    private static func inputMuteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func isMuted(_ device: AudioDeviceID) -> Bool {
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted)
        return status == noErr && muted == 1
    }
}

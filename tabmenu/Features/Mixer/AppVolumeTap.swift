//
//  AppVolumeTap.swift
//  MagicPlus
//

import CoreAudio
import Foundation
import os

/// Volume control for one application's audio, built on macOS process taps.
///
/// The tap mutes the app in the system mixdown and hands us its samples; a private
/// aggregate device replays them into the real output with our gain applied. Destroying
/// the pipeline unmutes the app again, so 100% volume simply means "no tap".
final class AppVolumeTap {
    private static let logger = Logger(subsystem: "com.tabmenu", category: "Mixer")

    /// Read on the realtime audio thread; aligned 32-bit loads are atomic on arm64, and a
    /// stale value for one buffer is inaudible.
    nonisolated(unsafe) var gain: Float32

    private var tapID = AudioObjectID(0)
    private var aggregateID = AudioObjectID(0)
    private var procID: AudioDeviceIOProcID?

    /// Fails when the tap or aggregate cannot be created — most commonly because the
    /// system-audio-recording permission has not been granted yet.
    init?(processObjects: [AudioObjectID], outputDeviceUID: String, name: String, gain: Float32) {
        self.gain = gain

        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.name = "MagicPlus \(name)"
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true

        var tapID = AudioObjectID(0)
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != 0 else {
            Self.logger.error("tap creation failed: \(status)")
            return nil
        }
        self.tapID = tapID

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MagicPlus Mixer",
            kAudioAggregateDeviceUIDKey: "com.tabmenu.mixer.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ],
            kAudioAggregateDeviceTapAutoStartKey: true
        ]

        var aggregateID = AudioObjectID(0)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID != 0 else {
            Self.logger.error("aggregate creation failed: \(status)")
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }
        self.aggregateID = aggregateID

        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcID(
            aggregateID,
            volumeApplyingIOProc,
            Unmanaged.passUnretained(self).toOpaque(),
            &procID
        )
        guard status == noErr, let procID else {
            Self.logger.error("IOProc creation failed: \(status)")
            destroyDevices()
            return nil
        }
        self.procID = procID

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            Self.logger.error("device start failed: \(status)")
            stop()
            return nil
        }

        Self.logger.notice("tap running for \(name, privacy: .public)")
    }

    deinit { stop() }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        destroyDevices()
    }

    private func destroyDevices() {
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
    }
}

/// Realtime callback: writes the tapped samples into the output, scaled by the gain.
/// Runs on the audio thread — no allocation, no locks, no Swift runtime beyond arithmetic.
private let volumeApplyingIOProc: AudioDeviceIOProc = { _, _, inInputData, _, outOutputData, _, clientData in
    guard let clientData else { return noErr }
    let tap = Unmanaged<AppVolumeTap>.fromOpaque(clientData).takeUnretainedValue()
    let gain = tap.gain

    let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
    let output = UnsafeMutableAudioBufferListPointer(outOutputData)

    for (index, outBuffer) in output.enumerated() {
        guard let outData = outBuffer.mData else { continue }
        let outSamples = outData.assumingMemoryBound(to: Float32.self)
        let outCount = Int(outBuffer.mDataByteSize) / MemoryLayout<Float32>.size

        guard index < input.count,
              let inData = input[index].mData
        else {
            // No tapped audio for this buffer: emit silence, never garbage.
            for sample in 0..<outCount { outSamples[sample] = 0 }
            continue
        }

        let inSamples = inData.assumingMemoryBound(to: Float32.self)
        let inCount = Int(input[index].mDataByteSize) / MemoryLayout<Float32>.size
        let copyCount = min(inCount, outCount)

        for sample in 0..<copyCount {
            outSamples[sample] = inSamples[sample] * gain
        }
        for sample in copyCount..<outCount {
            outSamples[sample] = 0
        }
    }
    return noErr
}

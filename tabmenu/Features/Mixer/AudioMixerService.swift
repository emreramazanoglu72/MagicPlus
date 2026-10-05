//
//  AudioMixerService.swift
//  MagicPlus
//

import AppKit
import CoreAudio
import Observation
import os

/// One row of the mixer: an application producing audio, with its own volume.
struct MixerApp: Identifiable, Equatable {
    /// Bundle identifier, or "pid:N" for bare processes.
    let id: String
    let name: String
    let icon: NSImage?
    let isPlaying: Bool
    let volume: Double
    let processObjects: [AudioObjectID]

    static func == (lhs: MixerApp, rhs: MixerApp) -> Bool {
        lhs.id == rhs.id && lhs.isPlaying == rhs.isPlaying && lhs.volume == rhs.volume
    }
}

/// Per-application volume control.
///
/// 100% means the app plays untouched. Anything lower engages a process tap that replays
/// the app's audio at the chosen gain — see `AppVolumeTap`. Volumes are remembered per
/// bundle and re-applied when the app plays again.
@Observable
@MainActor
final class AudioMixerService {
    private(set) var apps: [MixerApp] = []
    /// Set when a tap could not be created, which almost always means the
    /// system-audio-recording permission is missing.
    private(set) var needsPermission = false

    @ObservationIgnored private let logger = Logger(subsystem: "com.tabmenu", category: "Mixer")
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private var taps: [String: AppVolumeTap] = [:]
    /// Name and icon are immutable per group key; resolving them on every 2-second refresh
    /// is wasted work. Entries are pruned when their process group disappears.
    @ObservationIgnored private var identityCache: [String: (name: String, icon: NSImage?)] = [:]

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    // MARK: - Refresh

    /// Rebuilds the app list from the live audio processes and re-applies stored volumes
    /// to anything that started playing since last look.
    func refresh() {
        let stored = preferences.mixerVolumes
        let groups = Self.groupedProcesses(AudioProcessRegistry.snapshot())

        apps = groups
            .map { group in
                let volume = stored[group.key] ?? 1.0
                let identity = cachedIdentity(for: group.key, pid: group.anyPID)
                return MixerApp(
                    id: group.key,
                    name: identity.name,
                    icon: identity.icon,
                    isPlaying: group.isPlaying,
                    volume: taps[group.key]?.gain.asDouble ?? volume,
                    processObjects: group.objects
                )
            }
            .sorted(by: Self.rowOrder)

        // Apps whose remembered volume is below full get their tap back automatically.
        for app in apps where app.isPlaying && taps[app.id] == nil {
            if let volume = stored[app.id], volume < 0.999 {
                engageTap(for: app, volume: volume)
            }
        }

        // Taps for apps that stopped existing are torn down, and their cached identity with
        // them — a recycled pid must not inherit a dead process's name.
        let liveIDs = Set(groups.map(\.key))
        for (key, tap) in taps where !liveIDs.contains(key) {
            tap.stop()
            taps.removeValue(forKey: key)
        }
        for key in identityCache.keys where !liveIDs.contains(key) {
            identityCache.removeValue(forKey: key)
        }
    }

    /// Re-engages remembered per-app volumes without waiting for the mixer pane to open,
    /// so a saved 40% Spotify stays 40% straight after app relaunch. Idempotent — refresh()
    /// only creates taps that are missing — and harmless when no audio apps are running.
    func applyPersistedVolumes() {
        guard preferences.mixerVolumes.values.contains(where: { $0 < 0.999 }) else { return }
        refresh()
    }

    // MARK: - Volume

    func setVolume(_ volume: Double, for app: MixerApp) {
        let clamped = Self.clampVolume(volume)
        preferences.setMixerVolume(clamped, for: app.id)

        if clamped >= 0.999 {
            // Full volume: the tap is pure overhead, so the app goes back to its normal path.
            taps[app.id]?.stop()
            taps.removeValue(forKey: app.id)
        } else if let tap = taps[app.id] {
            tap.gain = Float32(clamped)
        } else {
            engageTap(for: app, volume: clamped)
        }

        apps = apps
            .map { $0.id == app.id ? withVolume($0, clamped) : $0 }
            .sorted(by: Self.rowOrder)
    }

    func stopAll() {
        for tap in taps.values { tap.stop() }
        taps.removeAll()
    }

    // MARK: - Internals

    private func engageTap(for app: MixerApp, volume: Double) {
        guard !app.processObjects.isEmpty,
              let outputUID = SystemAudio.defaultOutputDeviceUID()
        else { return }

        if let tap = AppVolumeTap(
            processObjects: app.processObjects,
            outputDeviceUID: outputUID,
            name: app.name,
            gain: Float32(Self.clampVolume(volume))
        ) {
            taps[app.id] = tap
            needsPermission = false
        } else {
            needsPermission = true
            logger.error("could not engage tap for \(app.name, privacy: .public)")
        }
    }

    private func cachedIdentity(for key: String, pid: pid_t) -> (name: String, icon: NSImage?) {
        if let cached = identityCache[key] { return cached }
        let identity = (Self.displayName(for: key, pid: pid), Self.icon(for: key, pid: pid))
        identityCache[key] = identity
        return identity
    }

    private func withVolume(_ app: MixerApp, _ volume: Double) -> MixerApp {
        MixerApp(
            id: app.id, name: app.name, icon: app.icon,
            isPlaying: app.isPlaying, volume: volume, processObjects: app.processObjects
        )
    }

    // MARK: - Pure rules (tested)

    nonisolated static func clampVolume(_ volume: Double) -> Double {
        min(max(volume, 0), 1)
    }

    /// Helper bundles ("com.google.Chrome.helper") control the same audio as their parent;
    /// grouping by the trimmed identifier gives the user one slider per app.
    nonisolated static func groupKey(forBundleID bundleID: String?, pid: pid_t) -> String {
        guard var bundleID, !bundleID.isEmpty else { return "pid:\(pid)" }
        for suffix in [".helper", ".Helper"] where bundleID.hasSuffix(suffix) {
            bundleID = String(bundleID.dropLast(suffix.count))
        }
        return bundleID
    }

    /// Playing apps first, then alphabetical, so live audio is always at the top.
    nonisolated static func rowOrder(_ lhs: MixerApp, _ rhs: MixerApp) -> Bool {
        if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    // MARK: - Grouping

    private struct ProcessGroup {
        let key: String
        let objects: [AudioObjectID]
        let anyPID: pid_t
        let isPlaying: Bool
    }

    private static func groupedProcesses(_ processes: [AudioProcessInfo]) -> [ProcessGroup] {
        var byKey: [String: (objects: [AudioObjectID], pid: pid_t, playing: Bool)] = [:]
        for process in processes {
            let key = groupKey(forBundleID: process.bundleID, pid: process.pid)
            var entry = byKey[key] ?? ([], process.pid, false)
            entry.objects.append(process.objectID)
            entry.playing = entry.playing || process.isPlaying
            byKey[key] = entry
        }
        return byKey.map { ProcessGroup(key: $0.key, objects: $0.value.objects, anyPID: $0.value.pid, isPlaying: $0.value.playing) }
    }

    private static func displayName(for key: String, pid: pid_t) -> String {
        if let application = NSRunningApplication(processIdentifier: pid),
           let name = application.localizedName {
            return name
        }
        if !key.hasPrefix("pid:"),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return key
    }

    private static func icon(for key: String, pid: pid_t) -> NSImage? {
        if let application = NSRunningApplication(processIdentifier: pid), let icon = application.icon {
            return icon
        }
        guard !key.hasPrefix("pid:"),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

// MARK: - Process registry

nonisolated struct AudioProcessInfo {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isPlaying: Bool
}

/// Reads the system's audio process objects: everything that has registered with Core Audio,
/// flagged with whether it is producing output right now.
nonisolated enum AudioProcessRegistry {
    static func snapshot() -> [AudioProcessInfo] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects
        ) == noErr else { return [] }

        return objects.compactMap { object in
            var pid: pid_t = -1
            guard scalar(object, kAudioProcessPropertyPID, &pid), pid > 0 else { return nil }

            var running: UInt32 = 0
            _ = scalar(object, kAudioProcessPropertyIsRunningOutput, &running)

            return AudioProcessInfo(
                objectID: object,
                pid: pid,
                bundleID: bundleID(of: object),
                isPlaying: running == 1
            )
        }
    }

    /// Reads a fixed-size property into `value`.
    ///
    /// `BitwiseCopyable` is the whole safety argument: Core Audio writes raw bytes over whatever it
    /// is given, which is only ever correct for a type that holds no references. Without the
    /// constraint the compiler can only warn that a `T` containing an object reference would be
    /// silently corrupted here, and it is right to.
    private static func scalar<T: BitwiseCopyable>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ value: inout T
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutableBytes(of: &value) { buffer in
            guard let destination = buffer.baseAddress else { return false }
            return AudioObjectGetPropertyData(object, &address, 0, nil, &size, destination) == noErr
        }
    }

    private static func bundleID(of object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var reference: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &reference) == noErr,
              let reference
        else { return nil }
        let value = reference.takeRetainedValue() as String
        return value.isEmpty ? nil : value
    }
}

private extension Float32 {
    var asDouble: Double { Double(self) }
}

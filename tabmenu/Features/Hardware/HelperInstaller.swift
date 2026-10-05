//
//  HelperInstaller.swift
//  tabmenu
//

import Foundation
import Observation
import ServiceManagement
import os

/// Installs, talks to, and removes the privileged helper.
///
/// The helper is the only part of MagicPlus that runs as root, it is registered only when the
/// user switches on a feature that needs it, and removing it is one call away. Until it is
/// installed everything else in the app works exactly as before.
@Observable
@MainActor
final class HelperInstaller {
    enum State: Equatable {
        case notInstalled
        /// Registered, but the user still has to allow it in System Settings → Login Items.
        case requiresApproval
        case installed
        /// The build cannot register a daemon at all — an unsigned local build, typically.
        case unavailable(String)

        var isInstalled: Bool { self == .installed }
    }

    private(set) var state: State = .notInstalled

    @ObservationIgnored private let logger = Logger(subsystem: "com.tabmenu", category: "Helper")
    @ObservationIgnored private var connection: NSXPCConnection?

    private var service: SMAppService {
        SMAppService.daemon(plistName: HelperConstants.daemonPlistName)
    }

    // MARK: - Installation

    func refreshState() {
        switch service.status {
        case .enabled:
            state = .installed
        case .requiresApproval:
            state = .requiresApproval
        case .notRegistered:
            state = .notInstalled
        case .notFound:
            state = .unavailable(
                String(
                    localized: "The helper is missing from this build of MagicPlus.",
                    comment: "Privileged helper cannot be found"
                )
            )
        @unknown default:
            state = .notInstalled
        }
    }

    /// Registers the daemon with launchd. macOS asks the user to approve it the first time,
    /// in System Settings → General → Login Items.
    func install() {
        do {
            try service.register()
            logger.notice("helper registered")
        } catch {
            logger.error("helper registration failed: \(error.localizedDescription, privacy: .public)")
            state = .unavailable(error.localizedDescription)
            return
        }
        refreshState()
    }

    func remove() {
        restoreSynchronously()
        invalidateConnection()
        do {
            try service.unregister()
            logger.notice("helper unregistered")
        } catch {
            logger.error("helper removal failed: \(error.localizedDescription, privacy: .public)")
        }
        refreshState()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - Talking to it

    private func makeConnection() -> NSXPCConnection? {
        if let connection { return connection }
        guard state.isInstalled else { return nil }

        let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    private func invalidateConnection() {
        connection?.invalidate()
        connection = nil
    }

    /// Runs one request against the helper. A helper that is missing, stale or unreachable
    /// answers with the fallback rather than throwing, because every caller's next move is
    /// the same either way: leave the hardware alone and say so in the UI.
    func call<Value: Sendable>(
        fallback: Value,
        _ body: @escaping @Sendable (HelperProtocol, @escaping @Sendable (Value) -> Void) -> Void
    ) async -> Value {
        guard let connection = makeConnection() else { return fallback }

        return await withCheckedContinuation { continuation in
            let once = ResumeOnce<Value>(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { [logger] error in
                logger.error("helper call failed: \(error.localizedDescription, privacy: .public)")
                once.resume(fallback)
            }
            guard let helper = proxy as? HelperProtocol else {
                once.resume(fallback)
                return
            }
            body(helper) { value in once.resume(value) }
        }
    }

    /// Used on the way out of the app, where there is no time left to await anything: the
    /// synchronous proxy blocks until the helper has actually put the hardware back.
    func restoreSynchronously() {
        guard let connection, state.isInstalled else { return }
        let proxy = connection.synchronousRemoteObjectProxyWithErrorHandler { [logger] error in
            logger.error("final restore failed: \(error.localizedDescription, privacy: .public)")
        }
        (proxy as? HelperProtocol)?.restoreDefaults { _ in }
    }
}

/// A continuation may only be resumed once, and both the reply and the error handler can
/// arrive, from different queues. This makes the race harmless.
nonisolated private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let continuation: CheckedContinuation<Value, Never>
    private let lock = NSLock()
    private var hasResumed = false

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        lock.lock()
        let shouldResume = !hasResumed
        hasResumed = true
        lock.unlock()
        guard shouldResume else { return }
        continuation.resume(returning: value)
    }
}

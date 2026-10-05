//
//  BrowserBridgeServer.swift
//  tabmenu
//

import Foundation
import Network
import os

/// The loopback listener the browser extension talks to.
///
/// This is the piece that makes real interception possible: no API lets a native app see a
/// browser's traffic, so the browser has to come to it. JDownloader has listened on a local
/// port for the same reason for twenty years.
///
/// It binds to 127.0.0.1 and nothing else, so nothing off the machine can reach it, and it
/// answers one request per connection and hangs up. Deciding *what* a request is allowed to do
/// is not its job — that belongs to the handler, which knows about pairing.
nonisolated final class BrowserBridgeServer: @unchecked Sendable {
    /// Ports tried in order. A fixed range means the extension can find the app without the
    /// user copying a port number from one window into another.
    static let portRange: ClosedRange<UInt16> = 27717...27726

    private let logger = Logger(subsystem: "com.tabmenu", category: "Bridge")
    private let queue = DispatchQueue(label: "com.tabmenu.bridge")
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse

    private var listener: NWListener?
    private(set) var port: UInt16?

    /// - Parameter handler: Answers a parsed request. Called off the main thread.
    init(handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) {
        self.handler = handler
    }

    // MARK: - Lifecycle

    /// Starts on the first free port in the range. Returns the port, or `nil` when every one of
    /// them is taken — which in practice means another copy of this app is already listening.
    @discardableResult
    func start() -> UInt16? {
        guard listener == nil else { return port }

        for candidate in Self.portRange {
            guard let listener = makeListener(on: candidate) else { continue }
            self.listener = listener
            self.port = candidate
            listener.start(queue: queue)
            logger.notice("bridge listening on \(candidate, privacy: .public)")
            return candidate
        }
        logger.error("no free port in the bridge range")
        return nil
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
    }

    private func makeListener(on port: UInt16) -> NWListener? {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        // Bound to loopback explicitly as well: nothing outside this machine may reach it.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .init(rawValue: port)!)
        parameters.allowLocalEndpointReuse = false

        guard let listener = try? NWListener(using: parameters) else { return nil }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.logger.error("bridge failed: \(error.localizedDescription, privacy: .public)")
                self?.stop()
            }
        }
        return listener
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, parser: HTTPRequestParser())
    }

    private func receive(on connection: NWConnection, parser: HTTPRequestParser) {
        var parser = parser
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if let error {
                logger.debug("bridge connection ended: \(error.localizedDescription, privacy: .public)")
                connection.cancel()
                return
            }
            if let data, !data.isEmpty { parser.append(data) }

            switch parser.next() {
            case .needsMoreData:
                if isComplete {
                    connection.cancel()
                    return
                }
                receive(on: connection, parser: parser)

            case .failure(let status, let message):
                send(HTTPResponse.error(status, message), on: connection)

            case .request(let request):
                Task { [weak self] in
                    guard let self else { return }
                    let response = await handler(request)
                    send(response, on: connection)
                }
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.wireFormat, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

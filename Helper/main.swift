//
//  main.swift
//  MagicPlusHelper
//
//  A launchd daemon that exists for one reason: the SMC refuses writes from anyone but root,
//  and holding a battery below full is an SMC write. It runs only while MagicPlus is running,
//  answers a fixed set of requests, and puts the hardware back the way it found it on every
//  path out — including the one where the app dies without saying goodbye.
//

import Foundation
import os

private let logger = Logger(subsystem: HelperConstants.machServiceName, category: "Listener")

/// Hands every accepted connection the same service object.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service = HelperService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = delegate

// Only code signed by the same team, carrying the app's identifier, may connect. Without
// this, any process on the machine could reach a service running as root. If the signature
// cannot be established the daemon refuses to serve at all rather than serving everyone.
guard let requirement = CodeSigningRequirement.forApplication() else {
    logger.error("no team identifier in this build's signature; refusing to expose the service")
    exit(EXIT_FAILURE)
}
listener.setConnectionCodeSigningRequirement(requirement)

// launchd stops a daemon by signalling it. Charging must not stay held back afterwards, so
// the default handlers are replaced with ones that restore the hardware first.
let signalSources = [SIGTERM, SIGINT].map { signalNumber -> DispatchSourceSignal in
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        delegate.service.restore()
        exit(EXIT_SUCCESS)
    }
    source.resume()
    return source
}

listener.resume()
logger.notice("helper \(HelperConstants.version, privacy: .public) listening")
withExtendedLifetime(signalSources) {
    dispatchMain()
}

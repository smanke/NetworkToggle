import Foundation
import NetworkToggleKit
import os

private let log = Logger(subsystem: NetworkToggleIDs.helperMachService, category: "listener")

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = HelperService()

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = service
        connection.resume()
        log.info("Accepted connection from pid \(connection.processIdentifier)")
        return true
    }
}

let listener = NSXPCListener(machServiceName: NetworkToggleIDs.helperMachService)

// The real access control. Without this any process on the machine could drive a
// root daemon; with it, only a binary signed as the app by this team gets through,
// and the check is done by the kernel rather than by inspecting a spoofable PID.
listener.setConnectionCodeSigningRequirement(NetworkToggleIDs.appRequirement)

let delegate = ListenerDelegate()
listener.delegate = delegate
listener.resume()
log.info("NetworkToggle helper \(HelperVersion.current) listening")
dispatchMain()

import Foundation
import SystemConfiguration
import CoreWLAN
import NetworkToggleKit
import os

private let log = Logger(subsystem: NetworkToggleIDs.helperMachService, category: "helper")

/// Runs as root under launchd. Every entry point here is reachable by anything that can
/// talk to the mach service, so the listener pins the caller's code signature and each
/// method re-validates its own arguments before touching system configuration.
final class HelperService: NSObject, HelperProtocol {

    func helperVersion(reply: @escaping (Int) -> Void) {
        reply(HelperVersion.current)
    }

    func setServiceOrder(_ serviceIDs: [String], reply: @escaping (String?) -> Void) {
        reply(commitOrder { current in
            // Refuse anything that is not a straight permutation. A caller that passed a
            // truncated list would otherwise silently unrank every service it omitted.
            guard Set(serviceIDs) == Set(current) else {
                throw HelperError.orderMismatch(sent: serviceIDs.count, expected: current.count)
            }
            return serviceIDs
        })
    }

    func promoteService(_ serviceID: String, reply: @escaping (String?) -> Void) {
        reply(commitOrder { current in
            guard current.contains(serviceID) else {
                throw HelperError.unknownService(serviceID)
            }
            return [serviceID] + current.filter { $0 != serviceID }
        })
    }

    func setWiFiPower(_ on: Bool, bsdName: String, reply: @escaping (String?) -> Void) {
        guard let interface = CWWiFiClient.shared().interface(withName: bsdName) else {
            reply("No Wi-Fi interface named \(bsdName).")
            return
        }
        do {
            try interface.setPower(on)
            log.info("Wi-Fi \(bsdName, privacy: .public) power set to \(on)")
            reply(nil)
        } catch {
            reply(error.localizedDescription)
        }
    }

    func uninstall(reply: @escaping (String?) -> Void) {
        reply(nil)
        // Give the reply time to travel back before launchd tears the process down.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
    }

    // MARK: - Commit

    /// Opens SCPreferences, hands the current order to `transform`, and writes the result
    /// back. Session-locked so a concurrent System Settings edit cannot interleave.
    private func commitOrder(_ transform: ([String]) throws -> [String]) -> String? {
        guard let prefs = SCPreferencesCreate(nil, "NetworkToggleHelper" as CFString, nil) else {
            return "Could not open the network preferences."
        }
        guard SCPreferencesLock(prefs, true) else {
            return "Another process is holding the network configuration lock."
        }
        defer { SCPreferencesUnlock(prefs) }

        guard let set = SCNetworkSetCopyCurrent(prefs) else {
            return "No active network location."
        }
        guard let current = SCNetworkSetGetServiceOrder(set) as? [String] else {
            return "Could not read the current service order."
        }

        let desired: [String]
        do {
            desired = try transform(current)
        } catch {
            return (error as? HelperError)?.message ?? error.localizedDescription
        }

        guard desired != current else { return nil }

        guard SCNetworkSetSetServiceOrder(set, desired as CFArray) else {
            return scError("Could not set the service order")
        }
        guard SCPreferencesCommitChanges(prefs) else {
            return scError("Could not save the network configuration")
        }
        guard SCPreferencesApplyChanges(prefs) else {
            return scError("Saved the configuration but could not apply it")
        }

        log.info("Service order committed: \(desired.joined(separator: ","), privacy: .public)")
        return nil
    }

    private func scError(_ prefix: String) -> String {
        let code = SCError()
        let detail = String(cString: SCErrorString(code))
        return "\(prefix): \(detail) (\(code))"
    }
}

private enum HelperError: Error {
    case orderMismatch(sent: Int, expected: Int)
    case unknownService(String)

    var message: String {
        switch self {
        case let .orderMismatch(sent, expected):
            return "Refusing to write a service order of \(sent) entries over one of \(expected)."
        case let .unknownService(id):
            return "No configured network service with ID \(id)."
        }
    }
}

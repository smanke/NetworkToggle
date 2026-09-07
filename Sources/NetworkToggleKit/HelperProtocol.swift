import Foundation

/// Everything the privileged daemon will do on the app's behalf. Deliberately tiny:
/// each method is a single, auditable system-configuration write.
@objc public protocol HelperProtocol {
    /// Build number of the running helper, so the app can detect a stale install.
    func helperVersion(reply: @escaping (Int) -> Void)

    /// Rewrite the global network service order. `serviceIDs` must be a permutation of
    /// the set currently in SCPreferences; the helper rejects anything else rather than
    /// dropping or inventing services.
    func setServiceOrder(_ serviceIDs: [String], reply: @escaping (String?) -> Void)

    /// Convenience used by auto-switch: hoist one service to the top, leaving the
    /// relative order of everything else untouched.
    func promoteService(_ serviceID: String, reply: @escaping (String?) -> Void)

    /// Power a Wi-Fi interface on or off. Forcing a reconnect is how open sockets and
    /// VPN tunnels get moved onto the wired link; nothing else migrates them.
    func setWiFiPower(_ on: Bool, bsdName: String, reply: @escaping (String?) -> Void)

    /// Uninstall: the helper unloads its own daemon so the user can remove the app cleanly.
    func uninstall(reply: @escaping (String?) -> Void)
}

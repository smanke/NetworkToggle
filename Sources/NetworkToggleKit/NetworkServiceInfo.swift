import Foundation
import SystemConfiguration

/// One configured network service, as it appears in System Settings > Network.
public struct NetworkServiceInfo: Identifiable, Hashable, Sendable {
    public let id: String          // SCNetworkService identifier, stable across renames
    public let name: String        // "Wi-Fi", "USB 10/100/1000 LAN"
    public let bsdName: String?    // en0, en8 — nil for services with no live interface
    public let interfaceType: String?  // kSCNetworkInterfaceTypeIEEE80211, ...Ethernet, ...
    public let isEnabled: Bool

    public var isWiFi: Bool { interfaceType == (kSCNetworkInterfaceTypeIEEE80211 as String) }

    /// Wired covers plain Ethernet plus the USB and Thunderbolt adapters docks present,
    /// all of which report as Ethernet interfaces, and link aggregates built from them.
    /// Thunderbolt Bridge is deliberately excluded: it is a host-to-host link, never an
    /// uplink, and promoting it would take the machine off the network.
    public var isWired: Bool {
        interfaceType == (kSCNetworkInterfaceTypeEthernet as String)
            || interfaceType == (kSCNetworkInterfaceTypeBond as String)
    }

    public init(id: String, name: String, bsdName: String?, interfaceType: String?, isEnabled: Bool) {
        self.id = id
        self.name = name
        self.bsdName = bsdName
        self.interfaceType = interfaceType
        self.isEnabled = isEnabled
    }
}

/// Reads the persisted network configuration. Reading needs no privilege — only the
/// commit does — so the app uses this directly and the helper uses it to validate
/// whatever order it is asked to write.
public enum NetworkConfiguration {

    public static func makePreferences(name: String) -> SCPreferences? {
        SCPreferencesCreate(nil, name as CFString, nil)
    }

    public static func services(in prefs: SCPreferences) -> [NetworkServiceInfo] {
        guard let set = SCNetworkSetCopyCurrent(prefs),
              let ordered = SCNetworkSetGetServiceOrder(set) as? [String]
        else { return [] }

        guard let all = SCNetworkSetCopyServices(set) as? [SCNetworkService] else { return [] }

        var byID: [String: NetworkServiceInfo] = [:]
        for service in all {
            guard let id = SCNetworkServiceGetServiceID(service) as String? else { continue }
            let interface = SCNetworkServiceGetInterface(service)
            byID[id] = NetworkServiceInfo(
                id: id,
                name: (SCNetworkServiceGetName(service) as String?) ?? "Unnamed service",
                bsdName: interface.flatMap { SCNetworkInterfaceGetBSDName($0) as String? },
                interfaceType: interface.flatMap { SCNetworkInterfaceGetInterfaceType($0) as String? },
                isEnabled: SCNetworkServiceGetEnabled(service)
            )
        }

        // Present them in the system's own order. Anything the set knows about but the
        // order array omits goes to the back, which is where macOS treats it as ranking.
        var result = ordered.compactMap { byID[$0] }
        let seen = Set(result.map(\.id))
        result += byID.values.filter { !seen.contains($0.id) }.sorted { $0.name < $1.name }
        return result
    }

    public static func serviceOrder(in prefs: SCPreferences) -> [String] {
        guard let set = SCNetworkSetCopyCurrent(prefs),
              let ordered = SCNetworkSetGetServiceOrder(set) as? [String]
        else { return [] }
        return ordered
    }

    /// A read-only snapshot for callers that do not want to manage an SCPreferences handle.
    public static func currentServices(name: String = "NetworkToggleRead") -> [NetworkServiceInfo] {
        guard let prefs = makePreferences(name: name) else { return [] }
        return services(in: prefs)
    }
}

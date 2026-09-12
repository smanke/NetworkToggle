import Foundation
import SystemConfiguration
import Observation
import NetworkToggleKit
import os

private let log = Logger(subsystem: NetworkToggleIDs.appBundleID, category: "monitor")

/// A network service plus everything currently true about it.
struct ServiceStatus: Identifiable, Hashable {
    let service: NetworkServiceInfo
    var linkUp: Bool
    var ipv4: String?
    var router: String?
    var speedMbps: Int?
    /// Carrying the machine's traffic. With a full-tunnel VPN up, macOS names the tunnel
    /// as primary; this stays true for the physical connection underneath it, because
    /// that is still the one doing the work.
    var isPrimary: Bool
    /// The VPN's encrypted traffic leaves through this connection.
    var carriesVPN = false

    var id: String { service.id }
    var name: String { service.name }
    var bsdName: String? { service.bsdName }

    /// Has an address *and* a gateway. Promoting a service without both is how you end
    /// up with a machine that believes it is online and cannot reach anything, so this
    /// gates every automatic action.
    var isUsable: Bool { linkUp && ipv4 != nil && router != nil }

    /// A wired service that is ready to carry traffic but is not the one being used.
    var isIdleWired: Bool { service.isWired && isUsable && !isPrimary }

    var speedLabel: String? {
        guard let speedMbps else { return nil }
        if speedMbps >= 1000 {
            let gbps = Double(speedMbps) / 1000
            return gbps == gbps.rounded()
                ? "\(Int(gbps)) Gbps"
                : String(format: "%.1f Gbps", gbps)
        }
        return "\(speedMbps) Mbps"
    }
}

/// A VPN tunnel and the physical connection it rides on.
struct VPNStatus: Hashable {
    let serviceID: String
    let name: String
    let tunnelInterface: String
    let tunnelAddress: String?
    let serverAddress: String?
    /// BSD name of the physical interface carrying the tunnel, when it can be determined.
    let carrierBSDName: String?
    /// True for a full tunnel, where macOS routes everything through the VPN.
    let isPrimary: Bool
}

@Observable
@MainActor
final class NetworkMonitor {
    private(set) var statuses: [ServiceStatus] = []
    private(set) var primaryServiceID: String?
    private(set) var vpn: VPNStatus?

    @ObservationIgnored private var vpnNames: [String: String] = [:]

    private var store: SCDynamicStore?
    private var runLoopSource: CFRunLoopSource?
    private var refreshTask: Task<Void, Never>?

    /// Fired when a wired service becomes newly usable, for the auto-switch policy.
    var onWiredBecameAvailable: ((ServiceStatus) -> Void)?
    /// Fired when a network service appears that we have never seen before — the
    /// signature of plugging in a dock whose Ethernet adapter macOS has not met.
    var onNewServiceAppeared: (([NetworkServiceInfo]) -> Void)?

    private var knownServiceIDs: Set<String> = []
    private var previouslyUsableWired: Set<String> = []

    var primary: ServiceStatus? { statuses.first { $0.isPrimary } }
    var vpnCarrier: ServiceStatus? { statuses.first { $0.carriesVPN } }
    var wiFi: ServiceStatus? { statuses.first { $0.service.isWiFi } }
    var idleWired: [ServiceStatus] { statuses.filter(\.isIdleWired) }

    // MARK: - Lifecycle

    func start() {
        knownServiceIDs = Set(NetworkConfiguration.currentServices().map(\.id))
        refresh()
        installDynamicStore()
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        store = nil
        refreshTask?.cancel()
    }

    /// Watches the configuration agent rather than polling. A dock plugging in changes
    /// a Link key within a second; the global IPv4 key changes once macOS has actually
    /// decided which service is primary.
    private func installDynamicStore() {
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            let monitor = Unmanaged<NetworkMonitor>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in monitor.scheduleRefresh() }
        }

        guard let store = SCDynamicStoreCreate(
            nil, "NetworkToggleMonitor" as CFString, callback, &context
        ) else {
            log.error("Could not create the dynamic store; falling back to no live updates.")
            return
        }

        let patterns: [String] = [
            "State:/Network/Global/IPv4",
            "State:/Network/Interface/[^/]+/Link",
            "State:/Network/Service/[^/]+/IPv4",
            "Setup:/Network/Global/IPv4",
        ]
        SCDynamicStoreSetNotificationKeys(store, nil, patterns as CFArray)

        guard let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        self.store = store
        self.runLoopSource = source
    }

    /// Interface changes arrive in bursts — link up, then address, then router. Coalesce
    /// them so the UI updates once with a settled picture instead of three times with
    /// half-configured ones.
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    // MARK: - Reading state

    func refresh() {
        let services = NetworkConfiguration.currentServices()
        let store = self.store ?? SCDynamicStoreCreate(nil, "NetworkToggleRead" as CFString, nil, nil)

        var primaryService: String?
        if let store,
           let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
            primaryService = global["PrimaryService"] as? String
        }
        primaryServiceID = primaryService

        statuses = services.map { service in
            var linkUp = false
            var ipv4: String?
            var router: String?

            if let store, let bsd = service.bsdName {
                let linkKey = "State:/Network/Interface/\(bsd)/Link" as CFString
                if let link = SCDynamicStoreCopyValue(store, linkKey) as? [String: Any] {
                    linkUp = (link["Active"] as? Bool) ?? false
                }
            }

            if let store {
                let key = "State:/Network/Service/\(service.id)/IPv4" as CFString
                if let dict = SCDynamicStoreCopyValue(store, key) as? [String: Any] {
                    // A self-assigned 169.254 address means DHCP never answered. It is an
                    // address, but routing through it breaks everything, so drop it here.
                    ipv4 = (dict["Addresses"] as? [String])?.first { !$0.hasPrefix("169.254.") }
                    router = dict["Router"] as? String
                }
            }

            return ServiceStatus(
                service: service,
                linkUp: linkUp,
                ipv4: ipv4,
                router: router,
                speedMbps: service.bsdName.flatMap {
                    LinkSpeed.mbps(forBSDName: $0, isWiFi: service.isWiFi)
                },
                // A tunnel is never the carrier, even when it is the service macOS names.
                isPrimary: service.id == primaryService && !service.isTunnel
            )
        }

        applyVPNState(store: store, services: services, primaryService: primaryService)

        detectNewServices(services)
        detectWiredArrival()
    }

    // MARK: - VPN

    /// Finds an active tunnel and re-points "primary" at the physical connection under it.
    ///
    /// Without this, a full-tunnel VPN makes macOS report the tunnel's own service as
    /// primary. That service is not in the network configuration — NetworkExtension VPNs
    /// publish it under a session UUID — so no listed connection matched, the app decided
    /// nothing was connected, and it offered to "switch" to the Ethernet link that was
    /// already carrying the VPN.
    private func applyVPNState(store: SCDynamicStore?, services: [NetworkServiceInfo], primaryService: String?) {
        guard let store,
              let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String]
        else {
            vpn = nil
            return
        }

        let configured = Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) })

        struct Candidate {
            let serviceID: String
            let state: [String: Any]
            let interface: String
        }
        let candidates: [Candidate] = keys.compactMap { key in
            let parts = key.split(separator: "/")
            guard parts.count == 5,
                  let state = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  let interface = state["InterfaceName"] as? String
            else { return nil }
            let serviceID = String(parts[3])
            let isTunnel = state["ServerAddress"] != nil
                || NetworkServiceInfo.isTunnelInterface(interface)
                || configured[serviceID]?.isTunnel == true
            return isTunnel ? Candidate(serviceID: serviceID, state: state, interface: interface) : nil
        }

        // The one routing everything wins; otherwise one that names a server is a real VPN
        // rather than an incidental utun from some other system component.
        guard let chosen = candidates.first(where: { $0.serviceID == primaryService })
                ?? candidates.first(where: { $0.state["ServerAddress"] != nil })
                ?? candidates.first
        else {
            if vpn != nil { log.info("VPN down") }
            vpn = nil
            return
        }

        let server = chosen.state["ServerAddress"] as? String
        let isPrimary = chosen.serviceID == primaryService
        let carrier = carrierInterface(for: chosen.state, server: server, isPrimary: isPrimary)

        let name: String
        if let configuredName = configured[chosen.serviceID]?.name {
            name = configuredName
        } else if let cached = vpnNames[chosen.serviceID] {
            name = cached
        } else {
            name = VPNNameResolver.enabledVPNApplicationName() ?? "VPN"
            vpnNames[chosen.serviceID] = name
        }

        let status = VPNStatus(
            serviceID: chosen.serviceID,
            name: name,
            tunnelInterface: chosen.interface,
            tunnelAddress: (chosen.state["Addresses"] as? [String])?.first,
            serverAddress: server,
            carrierBSDName: carrier,
            isPrimary: isPrimary
        )
        if status != vpn {
            log.info("VPN \(name, privacy: .public) on \(chosen.interface, privacy: .public) via \(carrier ?? "unknown", privacy: .public)")
            Diagnostics.note("vpn=\(name) tunnel=\(chosen.interface) server=\(server ?? "-") carrier=\(carrier ?? "unknown") full=\(isPrimary)")
        }
        vpn = status

        for index in statuses.indices {
            let carries = carrier != nil && statuses[index].bsdName == carrier
            statuses[index].carriesVPN = carries
            // With a full tunnel the carrier is what is actually in use. With a split
            // tunnel macOS still names a physical primary, and that answer stands.
            if isPrimary { statuses[index].isPrimary = carries }
        }
    }

    /// Which physical interface the tunnel's own packets leave through.
    ///
    /// A NetworkExtension VPN excludes its server from the tunnel and pins that route to
    /// an interface, which is the authoritative answer — confirmed against the kernel's
    /// host route and the provider's live socket. Configd-managed VPNs publish no such
    /// entry, and for those the server is reached through the highest-ranked working
    /// physical connection, so that is used instead.
    private func carrierInterface(for state: [String: Any], server: String?, isPrimary: Bool) -> String? {
        if let server,
           let excluded = state["ExcludedRoutes"] as? [[String: Any]],
           let route = excluded.first(where: { $0["DestinationAddress"] as? String == server }),
           let interface = route["InterfaceName"] as? String {
            return interface
        }
        if !isPrimary, let physical = statuses.first(where: \.isPrimary) {
            return physical.bsdName
        }
        return statuses.first { !$0.service.isTunnel && $0.isUsable }?.bsdName
    }

    private func detectNewServices(_ services: [NetworkServiceInfo]) {
        let currentIDs = Set(services.map(\.id))
        let added = currentIDs.subtracting(knownServiceIDs)
        knownServiceIDs = currentIDs
        guard !added.isEmpty else { return }

        // Only wired arrivals are interesting: a new dock's adapter gets a brand-new
        // service appended to the bottom of the order, below Wi-Fi, where it will never
        // win. That is the bug this app exists to fix.
        let newWired = services.filter { added.contains($0.id) && $0.isWired }
        guard !newWired.isEmpty else { return }
        log.info("New wired service(s): \(newWired.map(\.name).joined(separator: ", "), privacy: .public)")
        onNewServiceAppeared?(newWired)
    }

    private func detectWiredArrival() {
        let usableWired = Set(statuses.filter { $0.service.isWired && $0.isUsable }.map(\.id))
        let arrived = usableWired.subtracting(previouslyUsableWired)
        previouslyUsableWired = usableWired

        guard let first = arrived.compactMap({ id in statuses.first { $0.id == id } })
            .first(where: { !$0.isPrimary })
        else { return }
        onWiredBecameAvailable?(first)
    }
}

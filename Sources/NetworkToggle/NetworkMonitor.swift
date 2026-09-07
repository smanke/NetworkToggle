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
    var isPrimary: Bool

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

@Observable
@MainActor
final class NetworkMonitor {
    private(set) var statuses: [ServiceStatus] = []
    private(set) var primaryServiceID: String?

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
                isPrimary: service.id == primaryService
            )
        }

        detectNewServices(services)
        detectWiredArrival()
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

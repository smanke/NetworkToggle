import Foundation
import Observation
import UserNotifications
import NetworkToggleKit
import os

private let log = Logger(subsystem: NetworkToggleIDs.appBundleID, category: "switch")

/// Turns user intent and monitor events into privileged calls, and keeps enough history
/// to undo the last change.
@Observable
@MainActor
final class SwitchController {
    private(set) var busyMessage: String?
    private(set) var lastError: String?
    private(set) var lastAction: String?
    private(set) var undoableOrder: [String]?

    private let monitor: NetworkMonitor
    private let helper: HelperClient
    private let notifier: WiredArrivalNotifier
    private let settings = AppSettings.shared

    /// Services the user has already declined to promote, so a dock they deliberately
    /// keep at the bottom does not re-prompt on every reconnect.
    private var declinedServiceIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "declinedServices") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "declinedServices") }
    }

    init(monitor: NetworkMonitor, helper: HelperClient, notifier: WiredArrivalNotifier) {
        self.monitor = monitor
        self.helper = helper
        self.notifier = notifier

        monitor.onWiredBecameAvailable = { [weak self] status in
            Task { @MainActor in await self?.handleWiredArrival(status) }
        }
        monitor.onNewServiceAppeared = { [weak self] services in
            Task { @MainActor in await self?.handleNewServices(services) }
        }
    }

    // MARK: - Manual actions

    func switchTo(_ status: ServiceStatus, force: Bool) async {
        guard status.isUsable else {
            lastError = "\(status.name) has no working connection yet."
            return
        }
        await run("Switching to \(status.name)…") {
            self.captureUndoState()
            try await self.helper.promote(status.id)
            if force { try await self.moveConnectionsOffWiFi() }
            self.lastAction = force
                ? "Switched to \(status.name) and reconnected."
                : "Switched to \(status.name)."
        }
    }

    /// Takes up an offer made by a notification, which carries the service id rather than
    /// a snapshot that may be stale by the time someone clicks.
    func switchTo(serviceID: String, force: Bool) async {
        monitor.refresh()
        guard let status = monitor.statuses.first(where: { $0.id == serviceID }) else {
            lastError = "That connection is no longer available."
            return
        }
        await switchTo(status, force: force)
    }

    /// Writes a whole order at once — what the drag-and-drop list commits.
    func applyOrder(_ ids: [String]) async {
        await run("Saving connection order…") {
            self.captureUndoState()
            try await self.helper.setServiceOrder(ids)
            self.lastAction = "Connection order saved."
        }
    }

    func undo() async {
        guard let undoableOrder else { return }
        await run("Restoring previous order…") {
            try await self.helper.setServiceOrder(undoableOrder)
            self.undoableOrder = nil
            self.lastAction = "Previous order restored."
        }
    }

    /// Turns Wi-Fi off until nothing is left on its address, then back on. Returns how many
    /// connections were still on Wi-Fi when it gave up waiting.
    ///
    /// A quick off/on moves nothing. Measured: Wi-Fi came back with the same address within
    /// five seconds and two stranded file-share connections simply resumed on it. Held off,
    /// the same connections re-established over Ethernet within eight seconds, so this
    /// watches the helper's connection list and only turns Wi-Fi back on once they have
    /// gone, or after 30 seconds. Wi-Fi is turned back on even if waiting fails.
    @discardableResult
    private func moveConnectionsOffWiFi() async throws -> Int {
        guard let wifi = monitor.wiFi, let bsd = wifi.bsdName else { return 0 }
        let address = wifi.ipv4

        try await helper.setWiFiPower(false, bsdName: bsd)
        var remaining = 0
        do {
            let deadline = ContinuousClock.now + .seconds(30)
            try await Task.sleep(for: .seconds(2))
            while let address, ContinuousClock.now < deadline {
                let connections = await helper.establishedConnections() ?? []
                remaining = connections.filter { $0.localAddress == address }.count
                if remaining == 0 { break }
                try await Task.sleep(for: .seconds(1))
            }
        } catch {
            try await helper.setWiFiPower(true, bsdName: bsd)
            throw error
        }
        try await helper.setWiFiPower(true, bsdName: bsd)
        Diagnostics.note("moved off Wi-Fi: \(remaining) connection(s) still on \(address ?? "?") when Wi-Fi came back")
        return remaining
    }

    /// Moves connections left on Wi-Fi after another connection became active.
    func moveConnectionsToActive() async {
        let active = monitor.vpnCarrier?.name ?? monitor.primary?.name ?? "the active connection"
        await run("Moving connections to \(active)…") {
            let remaining = try await self.moveConnectionsOffWiFi()
            self.lastAction = remaining == 0
                ? "Moved everything off Wi-Fi to \(active)."
                : "\(remaining) connection\(remaining == 1 ? "" : "s") stayed on Wi-Fi."
        }
    }

    func toggleWiFi(on: Bool) async {
        guard let wifi = monitor.wiFi, let bsd = wifi.bsdName else { return }
        await run(on ? "Turning Wi-Fi on…" : "Turning Wi-Fi off…") {
            try await self.helper.setWiFiPower(on, bsdName: bsd)
            self.lastAction = on ? "Wi-Fi on." : "Wi-Fi off."
        }
    }

    private func captureUndoState() {
        guard let prefs = NetworkConfiguration.makePreferences(name: "NetworkToggleUndo") else { return }
        let order = NetworkConfiguration.serviceOrder(in: prefs)
        if !order.isEmpty { undoableOrder = order }
    }

    private func run(_ message: String, _ body: @escaping () async throws -> Void) async {
        busyMessage = message
        lastError = nil
        defer { busyMessage = nil }
        do {
            try await body()
            Diagnostics.note("\(message) succeeded")
            monitor.refresh()
        } catch {
            Diagnostics.note("\(message) failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
            log.error("\(message, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Automatic behaviour

    /// Development affordance: replays a dock arrival through the monitor's own detection.
    func simulateWiredArrival() async {
        monitor.refresh()
        monitor.simulateWiredArrival()
    }

    private func handleWiredArrival(_ status: ServiceStatus) async {
        guard settings.wiredArrival != .ignore, helper.state.isReady else { return }

        // Let DHCP, the router advertisement and any dock-side link training finish.
        try? await Task.sleep(for: .seconds(settings.settleDelaySeconds))
        monitor.refresh()

        guard let fresh = monitor.statuses.first(where: { $0.id == status.id }),
              fresh.isUsable,
              let router = fresh.router
        else { return }

        // macOS switches on its own when the wired connection already outranks Wi-Fi, which
        // is the usual setup — so there is nothing to offer, only something to report, with
        // the way back one click away.
        if fresh.isPrimary || fresh.carriesVPN {
            await notifier.confirm(fresh, revertTo: monitor.wiFi)
            return
        }

        // The guard that matters. A dock whose uplink is dead looks fully configured;
        // only a reply from the gateway distinguishes it from a working one. No reply
        // means we ask rather than act.
        // macOS's own ARP evidence first: an app cannot ping. ICMP from an ordinary app is
        // dropped in silence unless local-network permission has been granted — verified by
        // sending one and never hearing back while /sbin/ping answered in 6 ms — so a probe
        // on its own would refuse every switch forever.
        let gatewayAnswered = fresh.gatewayConfirmed ? true : await GatewayProbe.reachable(router)
        guard gatewayAnswered else {
            Diagnostics.note("gateway \(router) unconfirmed on \(fresh.bsdName ?? "?"); not offering")
            log.info("Gateway \(router, privacy: .public) did not answer; not auto-switching.")
            await notify(
                title: "Wired connection not responding",
                body: "\(fresh.name) is connected but its gateway isn’t answering. Staying on Wi-Fi."
            )
            return
        }

        guard settings.wiredArrival == .automatically else {
            // Ask, and let the notification's Switch button do it.
            await notifier.offer(fresh, force: settings.autoSwitchForcesReconnect)
            return
        }

        await switchTo(fresh, force: settings.autoSwitchForcesReconnect)
        await notify(
            title: "Switched to \(fresh.name)",
            body: fresh.speedLabel.map { "Now using the wired connection at \($0)." }
                ?? "Now using the wired connection."
        )
    }

    private func handleNewServices(_ services: [NetworkServiceInfo]) async {
        guard settings.promptForNewServices, helper.state.isReady else { return }
        for service in services where !declinedServiceIDs.contains(service.id) {
            await notify(
                title: "New wired connection found",
                body: "“\(service.name)” ranks below Wi-Fi. Open NetworkToggle to promote it.",
                identifier: "new-service-\(service.id)"
            )
        }
    }

    func decline(_ service: NetworkServiceInfo) {
        declinedServiceIDs.insert(service.id)
    }

    func clearDeclined() {
        declinedServiceIDs = []
    }

    private func notify(title: String, body: String, identifier: String = UUID().uuidString) async {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try? await center.add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        )
    }
}

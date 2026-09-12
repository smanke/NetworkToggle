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
    private let settings = AppSettings.shared

    /// Services the user has already declined to promote, so a dock they deliberately
    /// keep at the bottom does not re-prompt on every reconnect.
    private var declinedServiceIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "declinedServices") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "declinedServices") }
    }

    init(monitor: NetworkMonitor, helper: HelperClient) {
        self.monitor = monitor
        self.helper = helper

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
            if force { try await self.bounceWiFi() }
            self.lastAction = force
                ? "Switched to \(status.name) and reconnected."
                : "Switched to \(status.name)."
        }
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

    /// Cycling Wi-Fi is the only thing that moves already-open sockets. Existing TCP
    /// connections stay bound to their original source address for as long as they live,
    /// so reordering alone leaves a VPN tunnel or a long-lived session on Wi-Fi forever.
    private func bounceWiFi() async throws {
        guard let wifi = monitor.wiFi, let bsd = wifi.bsdName else { return }
        try await helper.setWiFiPower(false, bsdName: bsd)
        try await Task.sleep(for: .seconds(2))
        try await helper.setWiFiPower(true, bsdName: bsd)
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

    private func handleWiredArrival(_ status: ServiceStatus) async {
        guard settings.autoSwitch, helper.state.isReady else { return }

        // Let DHCP, the router advertisement and any dock-side link training finish.
        try? await Task.sleep(for: .seconds(settings.settleDelaySeconds))
        monitor.refresh()

        guard let fresh = monitor.statuses.first(where: { $0.id == status.id }),
              fresh.isUsable, !fresh.isPrimary,
              let router = fresh.router
        else { return }

        // The guard that matters. A dock whose uplink is dead looks fully configured;
        // only a reply from the gateway distinguishes it from a working one. No reply
        // means we ask rather than act.
        guard await GatewayProbe.reachable(router) else {
            log.info("Gateway \(router, privacy: .public) did not answer; not auto-switching.")
            await notify(
                title: "Wired connection not responding",
                body: "\(fresh.name) is connected but its gateway isn’t answering. Staying on Wi-Fi."
            )
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

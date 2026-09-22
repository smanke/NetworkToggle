import SwiftUI
import Observation
import NetworkToggleKit

/// Owns the app's long-lived objects and starts them at launch.
///
/// This deliberately does not hang off a view's `.task`: the menu bar item is an
/// indicator and the auto-switch policy runs unattended, so both have to be live from
/// the moment the app starts, not from the first time someone opens the popover.
@Observable
@MainActor
final class AppModel {
    let monitor = NetworkMonitor()
    let helper = HelperClient()
    let meter = ThroughputMeter()
    let strandedMonitor: StrandedTrafficMonitor
    let strandedMeter = ThroughputMeter()
    let notifier = WiredArrivalNotifier()
    private(set) var controller: SwitchController!

    @ObservationIgnored private var previewWindow: NSWindow?
    @ObservationIgnored private var helperStateTimer: Task<Void, Never>?

    init() {
        strandedMonitor = StrandedTrafficMonitor(helper: helper)
        controller = SwitchController(monitor: monitor, helper: helper, notifier: notifier)
        notifier.start()
        notifier.onMoveTraffic = { [weak self] in
            Task { @MainActor in await self?.controller.moveConnectionsToActive() }
        }
        notifier.onSwitch = { [weak self] serviceID, force in
            Task { @MainActor in await self?.controller.switchTo(serviceID: serviceID, force: force) }
        }
        helper.refreshState()
        monitor.start()
        openPreviewWindowIfRequested()
        scheduleLaunchUpdateCheck()
        retireStaleHelper()
        startHelperStateWatch()
    }

    /// Approval for a privileged helper is granted outside the app — in System Settings,
    /// possibly minutes after the request — and SMAppService has no change notification.
    /// Without this poll the setup card stays on screen forever after the user has
    /// already allowed it, which looks exactly like the app being broken.
    private func startHelperStateWatch() {
        helperStateTimer?.cancel()
        helperStateTimer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                self.helper.refreshState()
                // Once it is ready there is nothing left to watch for; a helper that is
                // later removed re-arms the watch through refreshHelperState().
                if self.helper.state.isReady {
                    self.helperStateTimer = nil
                    return
                }
            }
        }
    }

    /// Called when the menu opens, so the state is current the moment it is looked at
    /// rather than up to one poll interval stale.
    func refreshHelperState() {
        helper.refreshState()
        if !helper.state.isReady, helperStateTimer == nil {
            startHelperStateWatch()
        }
    }

    /// Deferred so startup is not waiting on the network, and silent unless there is
    /// something to offer.
    private func scheduleLaunchUpdateCheck() {
        guard AppSettings.shared.checkForUpdatesAtLaunch else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            UpdateController.checkForUpdates(silent: true)
        }
    }

    /// An update replaces the helper binary inside the bundle, but launchd keeps the
    /// already-running daemon alive. Asking a stale one to exit lets launchd start the
    /// new build on the next request; the registration and the user's approval survive,
    /// because the code signing requirement is pinned to the team rather than a hash.
    private func retireStaleHelper() {
        guard helper.state.isReady else { return }
        Task { @MainActor in
            let probe = await helper.probe()
            switch probe {
            case let .version(build) where build < HelperVersion.current:
                Diagnostics.note("Retiring helper build \(build); bundle carries \(HelperVersion.current)")
                await helper.retireRunningHelper()
            case .signatureMismatch:
                Diagnostics.note("Running helper fails its signature check — an update replaced its binary. Asking it to exit.")
                await helper.restartUnverifiedHelper()
            default:
                Diagnostics.note("helper: \(probe), bundle carries build \(HelperVersion.current)")
                return
            }
            // Give launchd a moment, then confirm the replacement is the new build.
            try? await Task.sleep(for: .seconds(1))
            Diagnostics.note("helper after restart: \(await helper.probe())")
        }
    }

    /// Development affordance: NETWORKTOGGLE_UI_PREVIEW=1 puts the popover's contents in an
    /// ordinary window, the only way to see and screenshot the UI without driving the
    /// menu bar through the accessibility APIs. Built with AppKit so the shipping scene
    /// graph stays exactly the menu bar item and Settings.
    private func openPreviewWindowIfRequested() {
        guard ProcessInfo.processInfo.environment["NETWORKTOGGLE_UI_PREVIEW"] == "1" else { return }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 660),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "NetworkToggle Preview"
        window.contentView = NSHostingView(
            rootView: MenuContentView(monitor: monitor, helper: helper, controller: controller, meter: meter,
                            strandedMonitor: strandedMonitor, strandedMeter: strandedMeter)
        )
        window.center()
        previewWindow = window

        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

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
    private(set) var controller: SwitchController!

    @ObservationIgnored private var previewWindow: NSWindow?

    init() {
        controller = SwitchController(monitor: monitor, helper: helper)
        helper.refreshState()
        monitor.start()
        openPreviewWindowIfRequested()
        scheduleLaunchUpdateCheck()
        retireStaleHelper()
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
            guard let installed = await helper.installedHelperVersion(),
                  installed < HelperVersion.current
            else { return }
            Diagnostics.note("Retiring helper build \(installed); bundle carries \(HelperVersion.current)")
            await helper.retireRunningHelper()
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
            rootView: MenuContentView(monitor: monitor, helper: helper, controller: controller)
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

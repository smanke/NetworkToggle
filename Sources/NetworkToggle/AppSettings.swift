import Foundation
import Observation

@Observable
@MainActor
final class AppSettings {
    static let shared = AppSettings()

    enum WiredArrival: String, CaseIterable, Identifiable {
        /// Notify with a Switch button and wait to be told.
        case ask
        /// Promote the wired connection as soon as it proves usable.
        case automatically
        case ignore

        var id: String { rawValue }

        var label: String {
            switch self {
            case .ask: "Ask me"
            case .automatically: "Switch automatically"
            case .ignore: "Do nothing"
            }
        }
    }

    /// What to do when a wired connection becomes usable while something else is active.
    var wiredArrival: WiredArrival { didSet { store(wiredArrival.rawValue, "wiredArrival") } }

    /// Whether auto-switch also bounces Wi-Fi. Off by default: reordering is silent,
    /// bouncing Wi-Fi drops every open connection, and doing that unattended is rude.
    var autoSwitchForcesReconnect: Bool { didSet { store(autoSwitchForcesReconnect, "autoSwitchForce") } }

    /// Offer to promote wired services macOS has just created for an unfamiliar dock.
    var promptForNewServices: Bool { didSet { store(promptForNewServices, "promptNewServices") } }

    /// How long to let a freshly connected interface settle before judging it.
    var settleDelaySeconds: Int { didSet { store(settleDelaySeconds, "settleDelay") } }

    /// Show the active interface's name next to the menu bar icon.
    var showNameInMenuBar: Bool { didSet { store(showNameInMenuBar, "showNameInMenuBar") } }

    /// Look for a newer release shortly after launch. Silent unless there is something
    /// to install, so it cannot turn into a dialog on every launch.
    var checkForUpdatesAtLaunch: Bool { didSet { store(checkForUpdatesAtLaunch, "checkForUpdatesAtLaunch") } }

    /// A version the user chose to skip. The launch check stays quiet about it; asking
    /// again every launch would just be nagging. Checking manually still offers it.
    /// Stored rather than computed off UserDefaults so @Observable tracks it and the
    /// "stop skipping" control in Settings disappears the moment it is used.
    var skippedUpdateVersion: String? {
        didSet { defaults.set(skippedUpdateVersion, forKey: "skippedUpdateVersion") }
    }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            "autoSwitch": true,
            "autoSwitchForce": false,
            "promptNewServices": true,
            "settleDelay": 4,
            "showNameInMenuBar": false,
            "checkForUpdatesAtLaunch": true,
        ])
        // Migrated from the old on/off switch: anyone who had automatic switching on now
        // gets asked first, which is the same trigger with the decision handed back.
        if let stored = defaults.string(forKey: "wiredArrival"), let behaviour = WiredArrival(rawValue: stored) {
            wiredArrival = behaviour
        } else {
            wiredArrival = defaults.bool(forKey: "autoSwitch") ? .ask : .ignore
        }
        autoSwitchForcesReconnect = defaults.bool(forKey: "autoSwitchForce")
        promptForNewServices = defaults.bool(forKey: "promptNewServices")
        settleDelaySeconds = defaults.integer(forKey: "settleDelay")
        showNameInMenuBar = defaults.bool(forKey: "showNameInMenuBar")
        checkForUpdatesAtLaunch = defaults.bool(forKey: "checkForUpdatesAtLaunch")
        skippedUpdateVersion = defaults.string(forKey: "skippedUpdateVersion")
    }

    private func store(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}

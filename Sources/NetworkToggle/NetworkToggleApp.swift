import SwiftUI
import NetworkToggleKit

@main
struct NetworkToggleApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(
                monitor: model.monitor,
                helper: model.helper,
                controller: model.controller,
                onAppear: { model.refreshHelperState() }
            )
        } label: {
            MenuBarLabel(monitor: model.monitor)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(helper: model.helper, controller: model.controller)
        }
    }
}

/// The menu bar item itself is the indicator: an RJ45 plug that is solid while a wired
/// connection is carrying traffic, hollow while it is not, and badged the moment a
/// better wired link is sitting idle.
struct MenuBarLabel: View {
    let monitor: NetworkMonitor
    @State private var settings = AppSettings.shared

    private var icon: NSImage {
        guard let primary = monitor.primary else {
            return ConnectorShape.menuBarImage(filled: false, slashed: true)
        }
        if primary.service.isWired {
            return ConnectorShape.menuBarImage(filled: true)
        }
        return ConnectorShape.menuBarImage(filled: false, badged: !monitor.idleWired.isEmpty)
    }

    private var accessibilityDescription: String {
        guard let primary = monitor.primary else { return "No network connection" }
        if monitor.idleWired.isEmpty { return "Network: \(primary.name)" }
        return "Network: \(primary.name). A wired connection is available."
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: icon)
            if settings.showNameInMenuBar, let name = monitor.primary?.name {
                Text(name)
            }
        }
        .accessibilityLabel(accessibilityDescription)
    }
}

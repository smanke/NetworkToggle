import SwiftUI
import NetworkToggleKit

struct MenuContentView: View {
    let monitor: NetworkMonitor
    let helper: HelperClient
    let controller: SwitchController
    var onAppear: () -> Void = {}

    @Environment(\.openSettings) private var openSettings
    @State private var settings = AppSettings.shared

    /// Optimistic copy of the order while a drag is being committed, so rows do not snap
    /// back for the moment between the drop and the configuration agent catching up.
    @State private var draftOrder: [String]?

    @State private var showDisconnected = false

    /// A Mac lists more services than System Settings shows — the internal USB4 ports
    /// alone add three that will never carry traffic. Hiding them by default keeps the
    /// connection you are actually using at the top of the popover.
    private var visibleRows: [ServiceStatus] {
        showDisconnected ? rows : rows.filter { $0.linkUp || $0.isPrimary }
    }

    private var hiddenCount: Int { rows.count - visibleRows.count }

    private var rows: [ServiceStatus] {
        guard let draftOrder else { return monitor.statuses }
        let byID = Dictionary(uniqueKeysWithValues: monitor.statuses.map { ($0.id, $0) })
        return draftOrder.compactMap { byID[$0] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ActiveConnectionCard(status: monitor.primary)

            // The list is readable without any privilege, so it stays visible during
            // setup — seeing the order is half of what this app is for. Only the
            // controls that write are withheld.
            priorityList

            if helper.state.isReady {
                actions
            } else {
                HelperSetupCard(helper: helper)
            }

            StatusLine(controller: controller)

            Divider().padding(.horizontal, 14)
            footer
        }
        .padding(.vertical, 12)
        .frame(width: 340)
        .onAppear {
            // Opening the menu is the moment the state has to be right: approval may
            // have been granted in System Settings since it was last read.
            onAppear()
            monitor.refresh()
        }
        .onChange(of: monitor.statuses.map(\.id)) { _, newValue in
            if draftOrder.map(Set.init) != Set(newValue) { draftOrder = nil }
        }
    }

    // MARK: - Priority list

    private var priorityList: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("Connection priority")

            List {
                ForEach(visibleRows) { status in
                    ServiceRow(status: status, canSwitch: helper.state.isReady) {
                        Task { await controller.switchTo(status, force: false) }
                    }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                    .listRowBackground(Color.clear)
                }
                .onMove(perform: move)
                .moveDisabled(!helper.state.isReady)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDisabled(visibleRows.count <= 7)
            .frame(height: CGFloat(max(1, min(visibleRows.count, 7))) * 46)
            .padding(.horizontal, 8)

            if hiddenCount > 0 || showDisconnected {
                Button {
                    withAnimation(.snappy) { showDisconnected.toggle() }
                } label: {
                    Label(
                        showDisconnected
                            ? "Hide disconnected"
                            : "Show \(hiddenCount) disconnected",
                        systemImage: showDisconnected ? "chevron.up" : "chevron.down"
                    )
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
            }

            Text(helper.state.isReady
                 ? "Drag to reorder. macOS uses the topmost connection that is working."
                 : "macOS uses the topmost connection that is working. Finish setup to reorder.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
        }
    }

    /// Writes straight through to the OS service order — the same list System Settings
    /// exposes only behind "Set Service Order…" in a modal sheet.
    ///
    /// The visible rows can be a subset, so the drag is applied by resequencing the ids
    /// that occupy the visible slots and leaving every hidden service in the absolute
    /// position it already held. The result is still a permutation of the full order,
    /// which is what the helper insists on.
    private func move(from offsets: IndexSet, to destination: Int) {
        var visibleIDs = visibleRows.map(\.id)
        visibleIDs.move(fromOffsets: offsets, toOffset: destination)

        var full = rows.map(\.id)
        let visibleSet = Set(visibleRows.map(\.id))
        var next = visibleIDs.makeIterator()
        for index in full.indices where visibleSet.contains(full[index]) {
            if let id = next.next() { full[index] = id }
        }

        draftOrder = full
        Task { await controller.applyOrder(full) }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        let target = monitor.idleWired.first
        VStack(spacing: 6) {
            Button {
                if let target { Task { await controller.switchTo(target, force: false) } }
            } label: {
                Label(
                    target.map { "Switch to \($0.name)" } ?? "No idle wired connection",
                    systemImage: "arrow.right"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.glassProminent)
            .disabled(target == nil)

            Button {
                if let target { Task { await controller.switchTo(target, force: true) } }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Label("Switch and force reconnect", systemImage: "bolt")
                    Text("Bounces Wi-Fi so open connections and VPNs move too")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.glass)
            .disabled(target == nil)
        }
        .padding(.horizontal, 14)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 2) {
            if let wifi = monitor.wiFi, let bsd = wifi.bsdName, helper.state.isReady {
                MenuRowButton(
                    title: wifi.linkUp ? "Turn Wi-Fi off" : "Turn Wi-Fi on",
                    systemImage: wifi.linkUp ? "wifi.slash" : "wifi"
                ) {
                    Task { await controller.toggleWiFi(on: !wifi.linkUp) }
                }
                .help("Interface \(bsd)")
            }

            if controller.undoableOrder != nil {
                MenuRowButton(title: "Undo last change", systemImage: "arrow.uturn.backward") {
                    Task { await controller.undo() }
                }
            }

            MenuRowButton(title: "Check for Updates…", systemImage: "arrow.down.circle") {
                UpdateController.checkForUpdates()
            }
            .help("Download and install the latest release from GitHub, then restart.")

            MenuRowButton(title: "Settings…", systemImage: "gearshape") {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
            MenuRowButton(title: "Quit NetworkToggle", systemImage: "power") {
                NSApp.terminate(nil)
            }

            // Version last, as a non-actionable footer — the quickest way to confirm
            // which build is actually running.
            Divider().padding(.vertical, 4)
            Text("\(AppInfo.name) \(AppInfo.displayVersion)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.bottom, 2)
        }
        .padding(.horizontal, 8)
    }
}

// MARK: - Pieces

struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
    }
}

struct ActiveConnectionCard: View {
    let status: ServiceStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("Active connection")

            HStack(spacing: 10) {
                Image(systemName: status?.service.isWiFi == true ? "wifi" : "cable.connector")
                    .font(.system(size: 18))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(status == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(status?.name ?? "Not connected")
                        .fontWeight(.medium)
                    if let status {
                        Text(detail(for: status))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
            .padding(.horizontal, 12)
        }
    }

    private func detail(for status: ServiceStatus) -> String {
        [status.ipv4, status.speedLabel, status.bsdName]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

struct ServiceRow: View {
    let status: ServiceStatus
    let canSwitch: Bool
    let onUse: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.quaternary)
                .opacity(canSwitch ? 1 : 0.35)

            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(status.isPrimary ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 0) {
                Text(status.name)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if status.isPrimary {
                Badge(text: "Active", tint: .green)
            } else if status.isUsable {
                if isHovering && canSwitch {
                    Button("Use", action: onUse)
                        .buttonStyle(.borderless)
                        .font(.caption)
                } else {
                    Badge(text: "Ready", tint: .secondary)
                }
            } else if status.linkUp {
                Badge(text: "No address", tint: .orange)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(height: 44)
        .contentShape(.rect)
        .background(
            status.isPrimary ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.clear),
            in: .rect(cornerRadius: 10)
        )
        .onHover { isHovering = $0 }
        .opacity(status.service.isEnabled ? 1 : 0.45)
    }

    private var icon: String {
        if status.service.isWiFi { return "wifi" }
        if status.service.isWired { return "cable.connector" }
        return "network"
    }

    private var subtitle: String {
        var parts: [String] = []
        if let ipv4 = status.ipv4 { parts.append(ipv4) } else if !status.linkUp { parts.append("Not connected") }
        if let speed = status.speedLabel { parts.append(speed) }
        if let bsd = status.bsdName { parts.append(bsd) }
        return parts.joined(separator: " · ")
    }
}

struct Badge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(tint == .secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.quaternary.opacity(0.6), in: .capsule)
    }
}

struct MenuRowButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(
            isHovering ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
            in: .rect(cornerRadius: 7)
        )
        .onHover { isHovering = $0 }
    }
}

struct StatusLine: View {
    let controller: SwitchController

    var body: some View {
        Group {
            if let busy = controller.busyMessage {
                Label(busy, systemImage: "progress.indicator")
                    .foregroundStyle(.secondary)
            } else if let error = controller.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if let action = controller.lastAction {
                Label(action, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct HelperSetupCard: View {
    let helper: HelperClient

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Setup needed", systemImage: "lock.shield")
                .font(.callout)
                .fontWeight(.medium)

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch helper.state {
            case .requiresApproval:
                Button("Open Login Items settings") { helper.openLoginItemsSettings() }
                    .buttonStyle(.glassProminent)
            case .notInstalled, .failed:
                HStack {
                    Button("Install helper") { helper.install() }
                        .buttonStyle(.glassProminent)
                    Button("Open Login Items") { helper.openLoginItemsSettings() }
                        .buttonStyle(.glass)
                }
            case .ready:
                EmptyView()
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
        .padding(.horizontal, 12)
    }

    private var message: String {
        switch helper.state {
        case .notInstalled:
            "Changing the connection order is a system setting, so NetworkToggle needs a small "
            + "privileged helper. You approve it once."
        case .requiresApproval:
            "Turn NetworkToggle on under Login Items & Extensions, then reopen this menu."
        case let .failed(reason):
            reason
        case .ready:
            ""
        }
    }
}

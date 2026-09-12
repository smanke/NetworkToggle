import SwiftUI
import NetworkToggleKit

struct MenuContentView: View {
    let monitor: NetworkMonitor
    let helper: HelperClient
    let controller: SwitchController
    var onAppear: () -> Void = {}

    @Environment(\.openSettings) private var openSettings
    @State private var settings = AppSettings.shared
    @State private var updates = UpdateAvailability.shared

    /// Optimistic copy of the order while a drag is being committed, so rows do not snap
    /// back for the moment between the drop and the configuration agent catching up.
    @State private var draftOrder: [String]?

    @State private var showDisconnected = false

    /// The row being dragged, and how far. Reordering tracks the mouse directly rather
    /// than using List's built-in move: that rides an AppKit table drag session, which
    /// the menu bar panel never delivers — rows could be dragged in a normal window and
    /// did nothing at all in the actual menu.
    @State private var draggingID: String?
    @State private var dragOffset: CGFloat = 0
    private let rowHeight: CGFloat = 46

    /// A change held back because it would pull the physical connection out from under a
    /// running VPN. Measured on NordVPN: moving Wi-Fi above the Ethernet link carrying the
    /// tunnel re-routed its server but its socket stayed bound to the Ethernet address,
    /// and the tunnel carried nothing until the order was put back.
    @State private var pendingChange: PendingChange?

    private enum PendingChange {
        case order([String])
        case switchTo(ServiceStatus, force: Bool)
    }

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
            ActiveConnectionCard(status: monitor.primary, vpn: monitor.vpn, carrier: monitor.vpnCarrier)

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

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(visibleRows.enumerated()), id: \.element.id) { index, status in
                        ServiceRow(status: status, canSwitch: helper.state.isReady) {
                            request(.switchTo(status, force: false))
                        }
                        .frame(height: rowHeight)
                        .offset(y: offset(forRowAt: index, id: status.id))
                        .zIndex(draggingID == status.id ? 1 : 0)
                        .gesture(reorderGesture(for: status, at: index), including: helper.state.isReady ? .all : .subviews)
                        .contextMenu {
                            if helper.state.isReady, index > 0 {
                                Button("Move to Top") { move(from: IndexSet(integer: index), to: 0) }
                            }
                        }
                    }
                }
                .animation(.snappy(duration: 0.2), value: draggingID == nil ? 0 : projectedIndex)
            }
            .scrollDisabled(visibleRows.count <= 7 || draggingID != nil)
            .frame(height: CGFloat(max(1, min(visibleRows.count, 7))) * rowHeight)
            .padding(.horizontal, 8)

            if let pendingChange {
                VPNInterruptionNotice(
                    vpnName: monitor.vpn?.name ?? "The VPN",
                    carrierName: monitor.vpnCarrier?.name ?? "its current connection",
                    onConfirm: { commit(pendingChange); self.pendingChange = nil },
                    onCancel: { self.pendingChange = nil; draftOrder = nil }
                )
            }

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
                .fixedSize(horizontal: false, vertical: true)
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
        Diagnostics.note("move: offsets=\(Array(offsets)) destination=\(destination) visible=\(visibleRows.map(\.name))")
        var visibleIDs = visibleRows.map(\.id)
        visibleIDs.move(fromOffsets: offsets, toOffset: destination)

        var full = rows.map(\.id)
        let visibleSet = Set(visibleRows.map(\.id))
        var next = visibleIDs.makeIterator()
        for index in full.indices where visibleSet.contains(full[index]) {
            if let id = next.next() { full[index] = id }
        }

        request(.order(full))
    }

    // MARK: - Drag tracking

    private func reorderGesture(for status: ServiceStatus, at index: Int) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                draggingID = status.id
                dragOffset = value.translation.height
            }
            .onEnded { _ in
                let destination = projectedIndex
                draggingID = nil
                dragOffset = 0
                guard destination != index else { return }
                // move(fromOffsets:toOffset:) takes an insertion point in the original
                // array, which sits one past the target when moving downwards.
                move(from: IndexSet(integer: index), to: destination > index ? destination + 1 : destination)
            }
    }

    /// Where the dragged row would land if released now.
    private var projectedIndex: Int {
        guard let draggingID, let from = visibleRows.firstIndex(where: { $0.id == draggingID }) else { return 0 }
        let shift = Int((dragOffset / rowHeight).rounded())
        return min(max(from + shift, 0), visibleRows.count - 1)
    }

    /// The dragged row follows the pointer; the rows it passes step aside to show the gap.
    private func offset(forRowAt index: Int, id: String) -> CGFloat {
        guard let draggingID, let from = visibleRows.firstIndex(where: { $0.id == draggingID }) else { return 0 }
        if id == draggingID { return dragOffset }
        let to = projectedIndex
        if from < to, index > from, index <= to { return -rowHeight }
        if from > to, index >= to, index < from { return rowHeight }
        return 0
    }

    // MARK: - VPN guard

    private func request(_ change: PendingChange) {
        if interruptsVPN(change) {
            if case let .order(ids) = change { draftOrder = ids }
            pendingChange = change
        } else {
            commit(change)
        }
    }

    private func commit(_ change: PendingChange) {
        switch change {
        case let .order(ids):
            draftOrder = ids
            Task { await controller.applyOrder(ids) }
        case let .switchTo(status, force):
            Task { await controller.switchTo(status, force: force) }
        }
    }

    /// Whether a change would move traffic off the physical connection a full-tunnel VPN
    /// is riding on. A split tunnel keeps its own route and is left alone.
    private func interruptsVPN(_ change: PendingChange) -> Bool {
        guard let vpn = monitor.vpn, vpn.isPrimary, let carrier = vpn.carrierBSDName else { return false }
        switch change {
        case let .switchTo(status, _):
            return status.bsdName != carrier
        case let .order(ids):
            let byID = Dictionary(uniqueKeysWithValues: monitor.statuses.map { ($0.id, $0) })
            let newTop = ids.lazy.compactMap { byID[$0] }.first { $0.isUsable && !$0.service.isTunnel }
            return newTop.map { $0.bsdName != carrier } ?? false
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        let target = monitor.idleWired.first
        VStack(spacing: 6) {
            Button {
                if let target { request(.switchTo(target, force: false)) }
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
                if let target { request(.switchTo(target, force: true)) }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Label("Switch and force reconnect", systemImage: "bolt")
                    // Not "and VPNs": measured on NordVPN, moving its connection strands the
                    // tunnel rather than carrying it across.
                    Text("Bounces Wi-Fi so open connections move too")
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

            if let pending = updates.pending {
                MenuRowButton(title: "Update to \(pending)…", systemImage: "arrow.down.circle.fill") {
                    UpdateController.checkForUpdates()
                }
                .help("A newer release is available. Downloading and installing it needs your confirmation.")
            } else {
                MenuRowButton(title: "Check for Updates…", systemImage: "arrow.down.circle") {
                    UpdateController.checkForUpdates()
                }
                .help("Download and install the latest release from GitHub, then restart.")
            }

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
    var vpn: VPNStatus? = nil
    var carrier: ServiceStatus? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("Active connection")

            VStack(alignment: .leading, spacing: 8) {
                if let vpn {
                    // The tunnel first, since that is where traffic appears to go, then the
                    // physical connection it rides on — which is the part this app changes.
                    ConnectionLine(
                        systemImage: "lock.shield",
                        title: vpn.name,
                        detail: [vpn.tunnelAddress, vpn.serverAddress.map { "server \($0)" }, vpn.tunnelInterface]
                            .compactMap { $0 }.joined(separator: " · "),
                        isActive: true
                    )
                    if let carrier {
                        ConnectionLine(
                            systemImage: carrier.service.isWiFi ? "wifi" : "cable.connector",
                            title: "over \(carrier.name)",
                            detail: detail(for: carrier),
                            isActive: true
                        )
                        .padding(.leading, 14)
                    } else {
                        Text("Can’t tell which connection the VPN is using.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 32)
                    }
                } else {
                    ConnectionLine(
                        systemImage: status?.service.isWiFi == true ? "wifi" : "cable.connector",
                        title: status?.name ?? "Not connected",
                        detail: status.map(detail(for:)),
                        isActive: status != nil
                    )
                }
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

private struct ConnectionLine: View {
    let systemImage: String
    let title: String
    let detail: String?
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 18))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct VPNInterruptionNotice: View {
    let vpnName: String
    let carrierName: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("This will interrupt \(vpnName)", systemImage: "exclamationmark.triangle")
                .font(.callout)
                .fontWeight(.medium)
            Text("\(vpnName) is running over \(carrierName). Moving traffic to another connection "
                 + "stops the tunnel until you disconnect and reconnect \(vpnName).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Change anyway", action: onConfirm)
                    .buttonStyle(.glassProminent)
                Button("Cancel", action: onCancel)
                    .buttonStyle(.glass)
            }
        }
        .padding(12)
        .background(.orange.opacity(0.10), in: .rect(cornerRadius: 12))
        .padding(.horizontal, 12)
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
                Badge(text: status.carriesVPN ? "Active · VPN" : "Active", tint: .green)
            } else if status.carriesVPN {
                Badge(text: "VPN", tint: .green)
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

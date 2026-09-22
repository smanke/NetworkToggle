import AppKit
import SwiftUI
import NetworkToggleKit
import os

private let log = Logger(subsystem: NetworkToggleIDs.appBundleID, category: "wired-arrival")

/// Offers a wired connection the moment one becomes usable, as a small panel near the
/// menu bar with one button to take it and one to decline.
///
/// Not a system notification: macOS puts a banner's actions behind an "Options" menu
/// unless the user has set this app's notifications to Alerts, so the two choices could
/// never sit side by side with equal weight. A panel the app draws itself always shows
/// both. It does not take focus, so it cannot interrupt typing, and it clears itself
/// after half a minute if nobody answers.
@MainActor
final class WiredArrivalNotifier {
    /// Called with the service to switch to, and whether to move open connections as well.
    var onSwitch: ((String, Bool) -> Void)?
    /// Called to pull connections still running over Wi-Fi across to the active connection.
    var onMoveTraffic: (() -> Void)?

    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?

    /// The last offer made, so a link that flaps does not reopen this repeatedly.
    private var lastOffer: (serviceID: String, at: ContinuousClock.Instant)?

    private static let visibleFor = Duration.seconds(30)

    func start() {}

    /// Offers `status`, unless the same one was offered in the last minute.
    func offer(_ status: ServiceStatus, force: Bool) async {
        guard notRepeated(status) else { return }
        present(status: status, force: force, alreadyActive: nil, strandedOnWiFi: 0)
        Diagnostics.note("wired arrival: offered \(status.name)")
        log.notice("Offered \(status.name, privacy: .public)")
    }

    /// Says a wired connection took over, with a way straight back.
    ///
    /// macOS switches on its own whenever the wired connection outranks Wi-Fi, which is the
    /// usual setup — so plugging a dock back in produced no offer at all, because there was
    /// nothing left to offer. Saying so is the difference between the app looking broken and
    /// looking like it is doing its job.
    func confirm(_ status: ServiceStatus, revertTo wifi: ServiceStatus?, strandedOnWiFi: Int) async {
        guard notRepeated(status) else { return }
        present(status: status, force: false, alreadyActive: wifi, strandedOnWiFi: strandedOnWiFi)
        Diagnostics.note("wired arrival: confirmed \(status.name) (already active)")
        log.notice("Confirmed \(status.name, privacy: .public) already active")
    }

    private func notRepeated(_ status: ServiceStatus) -> Bool {
        if let lastOffer, lastOffer.serviceID == status.id, ContinuousClock.now - lastOffer.at < .seconds(60) {
            return false
        }
        lastOffer = (status.id, .now)
        return true
    }

    func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func present(status: ServiceStatus, force: Bool, alreadyActive wifi: ServiceStatus?, strandedOnWiFi: Int) {
        dismiss()

        let serviceID = status.id
        // Already active: the choice is whether to stay, and the red button goes back to
        // Wi-Fi. Not yet active: the choice is whether to switch at all.
        // New connections already take the wired link; the ones opened while you were on
        // Wi-Fi stay there until something moves them, which is the whole point of the
        // green button here.
        let hasStranded = wifi != nil && strandedOnWiFi > 0
        let view = WiredArrivalOffer(
            title: wifi == nil ? "\(status.name) is available" : "Now on \(status.name)",
            detail: [status.speedLabel, status.ipv4].compactMap { $0 }.joined(separator: " · "),
            question: wifi == nil
                ? "Switch from Wi-Fi to this wired connection?"
                : hasStranded
                    ? "\(strandedOnWiFi) connection\(strandedOnWiFi == 1 ? "" : "s") opened earlier "
                      + "\(strandedOnWiFi == 1 ? "is" : "are") still going over Wi-Fi. Moving them turns "
                      + "Wi-Fi off briefly."
                    : "macOS moved you off Wi-Fi when it was plugged in.",
            acceptTitle: wifi == nil ? "Switch" : (hasStranded ? "Move traffic over" : "Keep it"),
            declineTitle: wifi == nil ? "Stay on Wi-Fi" : "Back to Wi-Fi",
            accept: { [weak self] in
                Diagnostics.note("wired arrival: accepted (stranded=\(strandedOnWiFi))")
                self?.dismiss()
                if wifi == nil {
                    self?.onSwitch?(serviceID, force)
                } else if hasStranded {
                    self?.onMoveTraffic?()
                }
            },
            decline: { [weak self] in
                Diagnostics.note("wired arrival: declined")
                self?.dismiss()
                if let wifi { self?.onSwitch?(wifi.id, false) }
            }
        )

        let hosting = NSHostingView(rootView: view)
        hosting.frame.size = hosting.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        // Top right, just under the menu bar, where a notification would have appeared.
        if let screen = NSScreen.main {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: area.maxX - hosting.fittingSize.width - 16,
                y: area.maxY - hosting.fittingSize.height - 12
            ))
        }
        panel.orderFrontRegardless()
        self.panel = panel

        dismissal = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.visibleFor)
            guard !Task.isCancelled else { return }
            Diagnostics.note("wired arrival: offer timed out")
            self?.dismiss()
        }
    }
}

private struct WiredArrivalOffer: View {
    let title: String
    let detail: String
    let question: String
    let acceptTitle: String
    let declineTitle: String
    let accept: () -> Void
    let decline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: ConnectorShape.menuBarImage(filled: true))
                    .renderingMode(.template)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .fontWeight(.medium)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            Text(question)
                .font(.caption)
                .foregroundStyle(.secondary)

            // Two buttons of equal weight: the colour says which is which, so neither is
            // the one you land on by accident. Drawn rather than tinted, because a panel
            // that never takes focus renders standard controls in their inactive grey.
            HStack(spacing: 8) {
                OfferButton(title: acceptTitle, systemImage: "checkmark.circle.fill",
                            colour: .green, filled: true, action: accept)
                OfferButton(title: declineTitle, systemImage: "xmark.circle.fill",
                            colour: .red, filled: false, action: decline)
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
    }
}

private struct OfferButton: View {
    let title: String
    let systemImage: String
    let colour: Color
    let filled: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout)
                .fontWeight(.medium)
                .lineLimit(1)
                .foregroundStyle(filled ? AnyShapeStyle(.white) : AnyShapeStyle(colour))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    filled ? AnyShapeStyle(colour) : AnyShapeStyle(colour.opacity(0.15)),
                    in: .capsule
                )
                .overlay(Capsule().strokeBorder(colour.opacity(filled ? 0 : 0.35)))
                .brightness(isHovering ? (filled ? 0.06 : 0.03) : 0)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

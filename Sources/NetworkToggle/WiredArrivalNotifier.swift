import AppKit
import UserNotifications
import NetworkToggleKit

/// Offers a wired connection the moment one becomes usable, as a notification with a
/// Switch button.
///
/// A notification rather than a window because this happens while you are working in
/// something else: it waits in Notification Centre if you miss it, and an accessory app
/// cannot reliably put a modal on screen from a background task anyway.
@MainActor
final class WiredArrivalNotifier: NSObject, UNUserNotificationCenterDelegate {
    private enum Identifier {
        static let category = "wired-available"
        static let switchNow = "switch-now"
        static let dismiss = "not-now"
        static let serviceKey = "serviceID"
        static let forceKey = "force"
    }

    /// Called with the service to switch to, and whether to move open connections as well.
    var onSwitch: ((String, Bool) -> Void)?

    /// The last offer made, so a link that flaps does not produce a pile of notifications.
    private var lastOffer: (serviceID: String, at: ContinuousClock.Instant)?
    /// Its notification id, so the previous one can be withdrawn before a new one is posted.
    private var lastNotificationID: String?

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let switchAction = UNNotificationAction(
            identifier: Identifier.switchNow,
            title: "Switch",
            options: []
        )
        let dismissAction = UNNotificationAction(identifier: Identifier.dismiss, title: "Not Now", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Identifier.category,
                actions: [switchAction, dismissAction],
                intentIdentifiers: [],
                options: []
            )
        ])

        Task {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            let settings = await center.notificationSettings()
            Diagnostics.note("notifications: granted=\(granted) authorization=\(settings.authorizationStatus.rawValue) "
                             + "alertSetting=\(settings.alertSetting.rawValue) alertStyle=\(settings.alertStyle.rawValue) "
                             + "notificationCentre=\(settings.notificationCenterSetting.rawValue) sound=\(settings.soundSetting.rawValue)")
        }
    }

    /// Offers `status`, unless the same one was offered in the last minute.
    func offer(_ status: ServiceStatus, force: Bool) async {
        if let lastOffer, lastOffer.serviceID == status.id, ContinuousClock.now - lastOffer.at < .seconds(60) {
            return
        }
        lastOffer = (status.id, .now)

        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else {
            // Without permission the menu is the only place this can be offered, and it
            // already shows the connection with a Switch button.
            Diagnostics.note("wired arrival: no notification permission, offer left to the menu")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "\(status.name) is available"
        content.body = [status.speedLabel.map { "Wired, \($0)." }, "Switch from Wi-Fi?"]
            .compactMap { $0 }.joined(separator: " ")
        content.categoryIdentifier = Identifier.category
        content.userInfo = [Identifier.serviceKey: status.id, Identifier.forceKey: force]
        content.sound = .default

        // A fresh id each time, and the previous one withdrawn first. Re-posting under an
        // identifier that is still sitting in Notification Centre updates it in place —
        // silently, with no banner — so the offer would never be seen again.
        if let lastNotificationID {
            center.removeDeliveredNotifications(withIdentifiers: [lastNotificationID])
        }
        let identifier = "wired-\(status.id)-\(UUID().uuidString)"
        lastNotificationID = identifier

        do {
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            Diagnostics.note("wired arrival: offered \(status.name)")
        } catch {
            Diagnostics.note("wired arrival: could not post the offer — \(error.localizedDescription)")
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    // Completion-handler form on purpose. The async form did not reach this class at all:
    // clicking the banner did nothing, with no sign of it here.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let serviceID = info[Identifier.serviceKey] as? String
        let force = info[Identifier.forceKey] as? Bool ?? false
        let action = response.actionIdentifier

        Task { @MainActor [weak self] in
            Diagnostics.note("notification response: \(action) service=\(serviceID ?? "none")")
            switch action {
            // Clicking the notification itself counts as taking the offer: that is the
            // single click this is for, and the change is undoable from the menu.
            case Identifier.switchNow, UNNotificationDefaultActionIdentifier:
                if let serviceID { self?.onSwitch?(serviceID, force) }
            default:
                break
            }
            completionHandler()
        }
    }
}

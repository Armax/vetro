import AppKit
import UserNotifications

/// Posts macOS notifications when an agent finishes or needs input in a chat
/// the user isn't looking at. Gating mirrors Ghostty's app: suppressed for
/// the focused (selected) chat while the app is active.
@MainActor
final class AgentNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AgentNotifier()

    var settings: AppSettings?
    var selectSession: ((UUID) -> Void)?
    var isSessionSelected: ((UUID) -> Bool)?

    private var lastNotified: [UUID: Date] = [:]
    private var authRequested = false

    override private init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorizationIfNeeded() {
        guard !authRequested else { return }
        authRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(sessionID: UUID, title: String, body: String) {
        guard let settings, settings.agentNotifications else { return }
        let appActive = NSApp.isActive
        if appActive {
            if settings.notifyOnlyInBackground { return }
            if isSessionSelected?(sessionID) ?? false { return }
        }
        // One notification per session per 5s: merges the finish transition,
        // OSC 9, and bell arriving together.
        if let last = lastNotified[sessionID], Date.now.timeIntervalSince(last) < 5 { return }
        lastNotified[sessionID] = .now

        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = title
        if !body.isEmpty { content.body = body }
        content.sound = .default
        content.userInfo = ["sessionID": sessionID.uuidString]
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Port-mirror prompts are actionable from the sidebar, so they present
    /// regardless of focus or the background-only preference.
    func notifyPortMirror(vmName: String, port: UInt16) {
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = "Mac port \(port)"
        content.body = "Forward into \(vmName) from the sidebar"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "port-mirror-\(port)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let idString = response.notification.request.content.userInfo["sessionID"] as? String
        let id = idString.flatMap(UUID.init(uuidString:))
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if let id {
                AgentNotifier.shared.selectSession?(id)
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

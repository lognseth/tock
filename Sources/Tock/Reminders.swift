import AppKit
import UserNotifications

/// Daily summary of what's due. Tasks only carry dates, so this is one notification a day
/// at a chosen time (while Tock is running) rather than one per task.
enum Reminders {
    struct Summary: Equatable {
        let title: String
        let body: String
    }

    static func summary(overdue: [TaskItem], today: [TaskItem]) -> Summary? {
        let all = overdue + today
        guard !all.isEmpty else { return nil }

        var parts: [String] = []
        if !overdue.isEmpty { parts.append("\(overdue.count) overdue") }
        if !today.isEmpty { parts.append("\(today.count) due today") }
        let title = parts.joined(separator: ", ")

        var lines = all.prefix(3).map { "• " + ($0.title.isEmpty ? $0.text : $0.title) }
        if all.count > 3 { lines.append("…and \(all.count - 3) more") }
        return Summary(title: title, body: lines.joined(separator: "\n"))
    }

    /// True once per day, from `minutes` after midnight onwards. A late launch still sends it.
    static func shouldSend(now: Date, lastSent: Date?, minutes: Int) -> Bool {
        let start = Dates.startOfDay(now)
        guard now >= start.addingTimeInterval(TimeInterval(minutes * 60)) else { return false }
        guard let lastSent else { return true }
        return Dates.startOfDay(lastSent) < start
    }
}

@MainActor
final class ReminderCenter: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: (() -> Void)?

    // Unbundled builds (swift run, --selftest) have no notification center.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func start() { center?.delegate = self }

    func ensureAuthorized(_ completion: @escaping (Bool) -> Void) {
        guard let center else { completion(false); return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    func post(_ summary: Reminders.Summary) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = summary.title
        content.body = summary.body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onOpen?() } }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

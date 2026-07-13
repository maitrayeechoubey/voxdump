import UserNotifications
import Foundation
import OSLog

final class NotificationManager {
    static let shared = NotificationManager()
    private init() {}

    @discardableResult
    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        BDLog.reminder.info("Notification auth result: \(granted, privacy: .public)")
        return granted
    }

    func schedule(title: String, body: String, at date: Date) {
        #if DEBUG
        BDLog.reminder.info("Scheduling notification '\(body, privacy: .public)' at \(date, privacy: .public)")
        #else
        BDLog.reminder.info("Scheduling notification '\(body, privacy: .private)' at \(date, privacy: .public)")
        #endif
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(req)
    }

    func scheduleRelative(title: String, body: String, after seconds: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - Natural language time parser

    func parseTime(from text: String) -> Date? {
        let lower = text.lowercased()
        let now = Date()
        let cal = Calendar.current

        // Relative: "in X minutes" / "in X hours"
        if let regex = try? NSRegularExpression(pattern: #"\bin (\d+) minute"#),
           let m = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let r = Range(m.range(at: 1), in: lower), let n = Double(lower[r]) {
            return now.addingTimeInterval(n * 60)
        }
        if let regex = try? NSRegularExpression(pattern: #"\bin (\d+) hour"#),
           let m = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let r = Range(m.range(at: 1), in: lower), let n = Double(lower[r]) {
            return now.addingTimeInterval(n * 3600)
        }
        if lower.contains("in an hour") || lower.contains("in one hour") {
            return now.addingTimeInterval(3600)
        }
        if lower.contains("in half an hour") || lower.contains("in 30 minutes") {
            return now.addingTimeInterval(1800)
        }
        if lower.contains("in a minute") || lower.contains("in one minute") {
            return now.addingTimeInterval(60)
        }

        // Named times
        if lower.contains("noon") {
            return nextOccurrence(hour: 12, minute: 0, tomorrow: lower.contains("tomorrow"), cal: cal, now: now)
        }
        if lower.contains("midnight") {
            return cal.date(bySettingHour: 0, minute: 0, second: 0,
                            of: cal.date(byAdding: .day, value: 1, to: now) ?? now)
        }
        if lower.contains("tonight") || lower.contains("this evening") {
            return cal.date(bySettingHour: 20, minute: 0, second: 0, of: now)
        }
        if lower.contains("tomorrow morning") {
            let tom = cal.date(byAdding: .day, value: 1, to: now) ?? now
            return cal.date(bySettingHour: 9, minute: 0, second: 0, of: tom)
        }

        // Absolute: "at 3pm", "at 3:30", "at 9 am"
        let absPattern = #"\bat (\d{1,2})(?::(\d{2}))?\s*(am|pm)?"#
        if let regex = try? NSRegularExpression(pattern: absPattern),
           let m = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) {
            let ns = lower as NSString
            var hour = Int(ns.substring(with: m.range(at: 1))) ?? 0
            let minute = m.range(at: 2).location != NSNotFound
                ? Int(ns.substring(with: m.range(at: 2))) ?? 0 : 0
            let meridiem = m.range(at: 3).location != NSNotFound
                ? ns.substring(with: m.range(at: 3)) : nil
            if meridiem == "pm" && hour < 12 { hour += 12 }
            if meridiem == "am" && hour == 12 { hour = 0 }
            if meridiem == nil && hour < 7 { hour += 12 }  // "at 3" → 3pm
            return nextOccurrence(hour: hour, minute: minute,
                                  tomorrow: lower.contains("tomorrow"), cal: cal, now: now)
        }

        #if DEBUG
        BDLog.reminder.warning("parseTime failed for: \"\(text, privacy: .public)\"")
        #else
        BDLog.reminder.warning("parseTime failed for: \"\(text, privacy: .private)\"")
        #endif
        return nil
    }

    private func nextOccurrence(hour: Int, minute: Int, tomorrow: Bool,
                                cal: Calendar, now: Date) -> Date? {
        let base = tomorrow
            ? (cal.date(byAdding: .day, value: 1, to: now) ?? now)
            : now
        var t = cal.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? base
        if t <= now { t = cal.date(byAdding: .day, value: 1, to: t) ?? t }
        return t
    }
}

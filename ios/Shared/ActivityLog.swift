import Foundation

/// Pure helpers for the activity-log ring buffer. Mirrors Android `OpenRungStatusStore.appendLog`
/// (timestamped `[HH:mm:ss] message` lines, capped at 80).
public enum ActivityLog {
    public static let maxLines = 80

    // Constructing a DateFormatter costs orders of magnitude more than formatting with one
    // (ICU locale/pattern setup); formatting is thread-safe on modern Foundation.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    public static func line(_ message: String, at date: Date = Date()) -> String {
        "[\(timestampFormatter.string(from: date))] \(message)"
    }

    public static func appended(_ lines: [String], _ line: String, max: Int = maxLines) -> [String] {
        Array((lines + [line]).suffix(max))
    }
}

import Foundation

/// Stable measurement units for exported reports; labels are localized by the UI.
enum ServerSystemFormatting {
    static func value(_ text: String, field: String) -> String {
        let numbers = text.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        if field == "users" {
            let counts = text.split(whereSeparator: \.isWhitespace)
            return counts.count == 2 ? "\(counts[0]) / \(counts[1])" : "\(text) / —"
        }
        if field == "memory" || field == "disk", numbers.count == 2,
           numbers.allSatisfy({ $0.isFinite && $0 >= 0 }), numbers[1] > 0 {
            let total = numbers[1]
            let available = min(numbers[0], total)
            let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
            var index = 0
            var divisor = 1.0
            while total / divisor >= 1024 && index < units.count - 1 { divisor *= 1024; index += 1 }
            let format = index == 0 ? "%.0f / %.0f %@" : "%.1f / %.1f %@"
            return String(format: format, locale: Locale(identifier: "en_US_POSIX"),
                          available / divisor, total / divisor, units[index])
        }
        if field == "uptime", numbers.count == 1, let value = numbers.first,
           value.isFinite, value >= 0, value < Double(Int.max) {
            let seconds = Int(value)
            if seconds < 60 { return "\(seconds)s" }
            let minutes = seconds / 60 % 60
            let hours = seconds / 3600 % 24
            let days = seconds / 86400
            return days > 0 ? "\(days)d \(hours)h \(minutes)m" : "\(hours)h \(minutes)m"
        }
        return text
    }
}

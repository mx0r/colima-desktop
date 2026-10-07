import ColimaDomain
import Foundation

/// Display formatting shared by menus and windows.
public enum Format {
    /// Binary units (GiB shown as "GB"), matching how colima sizes memory and disk.
    public static func memory(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }

    /// Decimal units, matching the docker CLI.
    public static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// "1.2 GB of 7.7 GB (16%)".
    public static func usage(used: Int64, total: Int64, style: ByteCountFormatter.CountStyle = .memory) -> String {
        let percent = total > 0 ? Int((Double(used) / Double(total) * 100).rounded()) : 0
        let usedText = ByteCountFormatter.string(fromByteCount: used, countStyle: style)
        let totalText = ByteCountFormatter.string(fromByteCount: total, countStyle: style)
        return "\(usedText) of \(totalText) (\(percent)%)"
    }

    /// "0.12  0.08  0.01".
    public static func load(_ load: LoadAverage) -> String {
        [load.one, load.five, load.fifteen].map { String(format: "%.2f", $0) }.joined(separator: "  ")
    }

    /// Absolute date and time in the user's locale.
    public static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    /// A duration in its two largest units: `2d 4h`, `3h 12m`, `5m 30s` or `42s`.
    public static func duration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let days = total / 86_400
        let hours = total % 86_400 / 3600
        let minutes = total % 3600 / 60
        let seconds = total % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    /// Docker's status text with its rounded duration ("Up 2 hours", "Exited (0) 3 hours ago")
    /// replaced by an exact one from the container's start or finish time. Without that time, or
    /// for other states ("Created"), Docker's text stays.
    public static func status(of container: Container, now: Date = Date()) -> String {
        let text = container.statusText
        guard !text.isEmpty else { return container.state.displayName }
        if let started = container.startedAt, let match = text.wholeMatch(of: #/Up (.+?)( \(.+\))?/#) {
            return "Up \(duration(now.timeIntervalSince(started)))\(match.2 ?? "")"
        }
        if let finished = container.finishedAt, let match = text.wholeMatch(of: #/((?:Exited|Restarting) \(-?\d+\)) .+ ago/#) {
            return "\(match.1) \(duration(now.timeIntervalSince(finished))) ago"
        }
        return text
    }

    /// Time of day with seconds, for log markers.
    public static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    /// Log timestamp with milliseconds, e.g. `2026-10-06 08:49:28.909`.
    public static func logTimestamp(_ date: Date) -> String {
        date.formatted(
            .verbatim(
                "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits).\(secondFraction: .fractional(3))",
                timeZone: .current,
                calendar: Calendar(identifier: .gregorian)
            )
        )
    }
}

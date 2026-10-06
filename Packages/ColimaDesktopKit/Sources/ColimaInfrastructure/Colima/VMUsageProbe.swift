import ColimaDomain
import Foundation

/// Reads resource usage inside the VM over `colima ssh`.
public enum VMUsageProbe {
    /// Section separator printed between commands.
    static let separator = "@@"

    /// Shell script run inside the VM. `/proc` and POSIX `df` give stable, parseable formats.
    public static let script = [
        "cat /proc/loadavg",
        "echo \(separator)",
        "nproc",
        "echo \(separator)",
        "cat /proc/meminfo",
        "echo \(separator)",
        "df -P -B1 / /var/lib/docker 2>/dev/null",
    ].joined(separator: "; ")

    /// Parses the script output.
    public static func parse(_ output: String) throws -> VMUsage {
        let sections = output
            .components(separatedBy: "\n")
            .split(whereSeparator: { $0.trimmingCharacters(in: .whitespaces) == separator })
            .map { Array($0) }
        guard sections.count >= 4 else {
            throw invalid("expected 4 sections, got \(sections.count)")
        }

        let loadFields = (sections[0].first ?? "").split(separator: " ")
        guard loadFields.count >= 3, let one = Double(loadFields[0]), let five = Double(loadFields[1]),
              let fifteen = Double(loadFields[2]) else {
            throw invalid("load average")
        }

        guard let cpuCount = Int((sections[1].first ?? "").trimmingCharacters(in: .whitespaces)) else {
            throw invalid("nproc")
        }

        let memInfo = parseMemInfo(sections[2])
        guard let memTotal = memInfo["MemTotal"], let memAvailable = memInfo["MemAvailable"] else {
            throw invalid("meminfo")
        }

        return VMUsage(
            loadAverage: LoadAverage(one: one, five: five, fifteen: fifteen),
            cpuCount: cpuCount,
            memoryTotalBytes: memTotal,
            memoryAvailableBytes: memAvailable,
            disks: parseDf(sections[3])
        )
    }

    /// `Key:   123 kB` lines → bytes.
    static func parseMemInfo(_ lines: [String]) -> [String: Int64] {
        var result: [String: Int64] = [:]
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let valueParts = parts[1].split(separator: " ")
            guard let value = valueParts.first.flatMap({ Int64($0) }) else { continue }
            let multiplier: Int64 = valueParts.dropFirst().first == "kB" ? 1024 : 1
            result[String(parts[0])] = value * multiplier
        }
        return result
    }

    /// POSIX `df -P -B1` rows → disk usage. The header line is skipped.
    static func parseDf(_ lines: [String]) -> [DiskUsage] {
        lines.compactMap { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 6, let total = Int64(fields[1]), let used = Int64(fields[2]),
                  let available = Int64(fields[3]) else { return nil }
            let mountPoint = fields[5...].joined(separator: " ")
            return DiskUsage(mountPoint: mountPoint, totalBytes: total, usedBytes: used, availableBytes: available)
        }
    }

    private static func invalid(_ detail: String) -> ColimaError {
        .invalidOutput(command: "colima ssh (usage probe)", detail: detail)
    }
}

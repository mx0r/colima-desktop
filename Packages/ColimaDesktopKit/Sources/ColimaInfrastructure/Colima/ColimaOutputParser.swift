import ColimaDomain
import Foundation

/// Parses colima command output.
public enum ColimaOutputParser {
    private struct ListEntry: Decodable {
        let name: String
        let status: String
        let arch: String?
        let cpus: Int?
        let memory: Int64?
        let disk: Int64?
        let runtime: String?
        let address: String?
    }

    private struct StatusEntry: Decodable {
        let displayName: String?
        let driver: String?
        let arch: String?
        let runtime: String?
        let mountType: String?
        let dockerSocket: String?
        let containerdSocket: String?
        let kubernetes: Bool?
        let cpu: Int?
        let memory: Int64?
        let disk: Int64?

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
            case driver, arch, runtime
            case mountType = "mount_type"
            case dockerSocket = "docker_socket"
            case containerdSocket = "containerd_socket"
            case kubernetes, cpu, memory, disk
        }
    }

    /// Parses `colima list --json`: one JSON object per line.
    public static func parseList(_ output: String) throws -> [ColimaInstance] {
        let decoder = JSONDecoder()
        return try output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("{") else { return nil }
            do {
                let entry = try decoder.decode(ListEntry.self, from: Data(line.utf8))
                return ColimaInstance(
                    profile: ProfileName(entry.name),
                    status: VMStatus(rawValue: entry.status),
                    arch: entry.arch ?? "",
                    cpus: entry.cpus ?? 0,
                    memoryBytes: entry.memory ?? 0,
                    diskBytes: entry.disk ?? 0,
                    runtime: entry.runtime.flatMap { $0.isEmpty ? nil : $0 },
                    address: entry.address.flatMap { $0.isEmpty ? nil : $0 }
                )
            } catch {
                throw ColimaError.invalidOutput(command: "colima list", detail: "\(error.localizedDescription) in line: \(line)")
            }
        }
    }

    /// Parses `colima status --json`.
    public static func parseStatus(_ output: String) throws -> ColimaInstanceDetails {
        let entry: StatusEntry
        do {
            entry = try JSONDecoder().decode(StatusEntry.self, from: Data(output.utf8))
        } catch {
            throw ColimaError.invalidOutput(command: "colima status", detail: error.localizedDescription)
        }
        return ColimaInstanceDetails(
            displayName: entry.displayName ?? "colima",
            driver: entry.driver ?? "",
            arch: entry.arch ?? "",
            runtime: entry.runtime ?? "",
            mountType: entry.mountType ?? "",
            dockerSocketPath: socketPath(entry.dockerSocket),
            containerdSocketPath: socketPath(entry.containerdSocket),
            kubernetes: entry.kubernetes ?? false,
            cpus: entry.cpu ?? 0,
            memoryBytes: entry.memory ?? 0,
            diskBytes: entry.disk ?? 0
        )
    }

    /// Whether `colima status` stderr says the profile is not running (a state, not an error).
    public static func isNotRunning(stderr: String) -> Bool {
        stderr.contains("is not running")
    }

    /// Parses `colima version`, e.g. `colima version 0.10.3` → `0.10.3`.
    public static func parseVersion(_ output: String) -> String? {
        guard let first = output.split(whereSeparator: \.isNewline).first else { return nil }
        let prefix = "colima version "
        return first.hasPrefix(prefix) ? String(first.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) : nil
    }

    /// Extracts the message of a logrus text line (`time=… level=info msg="starting colima"`).
    /// Returns the trimmed line when it has no `msg` field, nil for blank lines.
    public static func logMessage(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let range = trimmed.range(of: "msg=") else { return trimmed }
        let rest = trimmed[range.upperBound...]
        guard rest.first == "\"" else {
            return String(rest.prefix { $0 != " " })
        }
        var message = ""
        var escaped = false
        for character in rest.dropFirst() {
            if escaped {
                message.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                break
            } else {
                message.append(character)
            }
        }
        return message
    }

    /// Picks the most useful error message from colima stderr: the last fatal/error message, else the last line.
    public static func errorMessage(fromStderr stderr: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline).map(String.init)
        if let fatal = lines.last(where: { $0.contains("level=fatal") || $0.contains("level=error") }) {
            return logMessage(fatal) ?? fatal
        }
        return lines.last.flatMap(logMessage) ?? ""
    }

    private static func socketPath(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value.hasPrefix("unix://") ? String(value.dropFirst("unix://".count)) : value
    }
}

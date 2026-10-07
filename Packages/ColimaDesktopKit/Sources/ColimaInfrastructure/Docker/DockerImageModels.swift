import ColimaDomain
import Foundation

extension DockerAPI {
    /// One result of `GET /images/search`. Its keys are snake_case, unlike the rest of the API.
    struct SearchResult: Decodable {
        let name: String?
        let description: String?
        let starCount: Int?
        let isOfficial: Bool?

        enum CodingKeys: String, CodingKey {
            case name, description
            case starCount = "star_count"
            case isOfficial = "is_official"
        }

        var domain: ImageSearchResult? {
            guard let name, !name.isEmpty else { return nil }
            return ImageSearchResult(name: name, description: description ?? "", starCount: starCount ?? 0, isOfficial: isOfficial ?? false)
        }
    }

    /// One message of the pull stream (Docker's JSON message format).
    struct PullStreamMessage: Decodable {
        struct Detail: Decodable {
            let current: Int64?
            let total: Int64?
        }

        struct ErrorDetail: Decodable {
            let message: String?
        }

        let id: String?
        let status: String?
        let progressDetail: Detail?
        let error: String?
        let errorDetail: ErrorDetail?

        var domain: PullMessage {
            PullMessage(
                id: id,
                status: status,
                current: progressDetail?.current,
                total: progressDetail?.total,
                error: errorDetail?.message ?? error
            )
        }
    }

    /// Response of `POST /containers/create`.
    struct ContainerCreateResponse: Decodable {
        let id: String
        let warnings: [String]?
    }

    /// Body of `POST /containers/create`; property names are the API's keys.
    struct ContainerCreateBody: Encodable {
        struct Empty: Encodable {}

        struct HostPort: Encodable {
            let HostIp: String
            let HostPort: String
        }

        struct RestartPolicy: Encodable {
            let Name: String
        }

        struct HostConfiguration: Encodable {
            let PortBindings: [String: [HostPort]]
            let Binds: [String]
            let RestartPolicy: RestartPolicy
            let PublishAllPorts: Bool
        }

        let Image: String
        let Cmd: [String]?
        let Env: [String]
        let ExposedPorts: [String: Empty]
        let HostConfig: HostConfiguration

        init(_ spec: ContainerSpec) {
            Image = spec.image.description
            Cmd = spec.command
            Env = spec.environment.map { "\($0.name)=\($0.value)" }
            ExposedPorts = Dictionary(spec.ports.map { ($0.key, Empty()) }, uniquingKeysWith: { first, _ in first })
            HostConfig = HostConfiguration(
                PortBindings: Dictionary(grouping: spec.ports, by: \.key).mapValues { bindings in
                    bindings.map { HostPort(HostIp: "", HostPort: $0.hostPort.map(String.init) ?? "") }
                },
                Binds: spec.volumes.map(\.bind),
                RestartPolicy: RestartPolicy(Name: spec.restartPolicy.rawValue),
                PublishAllPorts: spec.publishAllPorts
            )
        }
    }
}

/// Splits the pull stream into messages: one JSON object per line, lines end in CRLF, and network
/// chunks split lines anywhere.
struct PullMessageDecoder {
    private var buffer: [UInt8] = []

    /// Messages completed by these bytes.
    mutating func feed(_ bytes: [UInt8]) -> [PullMessage] {
        buffer += bytes
        var messages: [PullMessage] = []
        while let newline = buffer.firstIndex(of: 10) {
            let line = Array(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if let message = Self.decode(line) { messages.append(message) }
        }
        return messages
    }

    /// A last message without a line end.
    mutating func flush() -> [PullMessage] {
        defer { buffer = [] }
        return Self.decode(buffer).map { [$0] } ?? []
    }

    private static func decode(_ line: [UInt8]) -> PullMessage? {
        let trimmed = line.last == 13 ? Array(line.dropLast()) : line
        guard !trimmed.isEmpty else { return nil }
        return (try? DockerJSON.decoder.decode(DockerAPI.PullStreamMessage.self, from: Data(trimmed)))?.domain
    }
}

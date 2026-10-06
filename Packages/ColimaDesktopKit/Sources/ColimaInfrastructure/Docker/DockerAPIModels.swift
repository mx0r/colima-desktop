import ColimaDomain
import Foundation

/// Engine API payloads and their mapping to domain models.
///
/// Decoded with `DockerJSON.decoder`, which lower-cases the first letter of each key
/// (`Names` → `names`, `NCPU` → `nCPU`). Every field is optional so engine drift does not break decoding.
enum DockerAPI {
    struct Version: Decodable {
        let version: String?
        let apiVersion: String?
        let minAPIVersion: String?
    }

    struct Info: Decodable {
        let serverVersion: String?
        let operatingSystem: String?
        let kernelVersion: String?
        let architecture: String?
        let nCPU: Int?
        let memTotal: Int64?
        let containers: Int?
        let containersRunning: Int?
        let containersPaused: Int?
        let containersStopped: Int?
        let images: Int?
        let driver: String?
    }

    struct ContainerSummary: Decodable {
        struct Port: Decodable {
            let privatePort: Int?
            let publicPort: Int?
            let type: String?
        }

        let id: String
        let names: [String]?
        let image: String?
        let created: Int64?
        let ports: [Port]?
        let labels: [String: String]?
        let state: String?
        let status: String?
    }

    struct ContainerInspect: Decodable {
        struct Config: Decodable {
            let tty: Bool?
            let image: String?
            let cmd: [String]?
            let entrypoint: [String]?
        }

        struct State: Decodable {
            struct Health: Decodable { let status: String? }
            let status: String?
            let startedAt: String?
            let finishedAt: String?
            let exitCode: Int?
            let health: Health?
        }

        struct NetworkSettings: Decodable {
            struct Network: Decodable { let iPAddress: String? }
            let networks: [String: Network]?
        }

        struct Mount: Decodable {
            let type: String?
            let source: String?
            let destination: String?
            let name: String?
        }

        let id: String
        let name: String?
        let config: Config?
        let state: State?
        let restartCount: Int?
        let platform: String?
        let networkSettings: NetworkSettings?
        let mounts: [Mount]?
    }

    /// Legacy `/system/df` shape (API < 1.52 and still returned by newer engines).
    struct SystemDF: Decodable {
        struct Image: Decodable {
            let size: Int64?
            let sharedSize: Int64?
            let containers: Int?
        }

        struct Container: Decodable {
            let sizeRw: Int64?
            let state: String?
        }

        struct Volume: Decodable {
            struct UsageData: Decodable {
                let size: Int64?
                let refCount: Int?
            }
            let usageData: UsageData?
        }

        struct BuildCache: Decodable {
            let size: Int64?
            let inUse: Bool?
            let shared: Bool?
        }

        let layersSize: Int64?
        let images: [Image]?
        let containers: [Container]?
        let volumes: [Volume]?
        let buildCache: [BuildCache]?
    }

    struct ExecCreated: Decodable {
        let id: String
    }

    struct ExecInspect: Decodable {
        let running: Bool?
        let exitCode: Int?
    }

    struct Event: Decodable {
        struct Actor: Decodable { let iD: String? }
        let type: String?
        let action: String?
        let actor: Actor?
    }
}

enum DockerJSON {
    /// Decoder for Engine API payloads (PascalCase keys).
    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { keys in
            let key = keys.last!.stringValue
            return AnyKey(key.prefix(1).lowercased() + key.dropFirst())
        }
        return decoder
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    static func decode<T: Decodable>(_ type: T.Type, from bytes: [UInt8], endpoint: String) throws -> T {
        do {
            return try decoder.decode(type, from: Data(bytes))
        } catch {
            throw DockerError.invalidResponse("\(endpoint): \(error)")
        }
    }
}

extension DockerAPI.ContainerSummary {
    var domain: Container {
        Container(
            id: id,
            name: (names?.first ?? id).trimmingPrefix("/").description,
            image: image ?? "",
            state: ContainerState(rawValue: state ?? ""),
            statusText: status ?? "",
            created: Date(timeIntervalSince1970: TimeInterval(created ?? 0)),
            ports: PublishedPort.deduplicated((ports ?? []).compactMap { port in
                port.privatePort.map { PublishedPort(privatePort: $0, publicPort: port.publicPort, proto: port.type ?? "tcp") }
            }),
            labels: labels ?? [:]
        )
    }
}

extension DockerAPI.ContainerInspect {
    var domain: ContainerDetails {
        ContainerDetails(
            id: id,
            name: (name ?? id).trimmingPrefix("/").description,
            image: config?.image ?? "",
            tty: config?.tty ?? false,
            command: (config?.entrypoint ?? []) + (config?.cmd ?? []),
            state: ContainerState(rawValue: state?.status ?? ""),
            startedAt: Self.date(state?.startedAt),
            finishedAt: Self.date(state?.finishedAt),
            exitCode: state?.exitCode,
            health: state?.health?.status,
            restartCount: restartCount ?? 0,
            platform: platform,
            networks: (networkSettings?.networks ?? [:]).compactMapValues { $0.iPAddress.flatMap { $0.isEmpty ? nil : $0 } },
            mounts: (mounts ?? []).map { "\($0.name ?? $0.source ?? "?") → \($0.destination ?? "?")" }
        )
    }

    /// Docker uses `0001-01-01T00:00:00Z` for "never".
    private static func date(_ text: String?) -> Date? {
        guard let text, !text.hasPrefix("0001-") else { return nil }
        return RFC3339.parse(Array(text.utf8))
    }
}

extension DockerAPI.SystemDF {
    var domain: DiskUsageSummary {
        let images = images ?? []
        let activeImages = images.filter { ($0.containers ?? 0) > 0 }
        let imageReclaimable = images
            .filter { ($0.containers ?? 0) == 0 }
            .reduce(Int64(0)) { $0 + max(0, ($1.size ?? 0) - ($1.sharedSize ?? 0)) }

        let containers = containers ?? []
        let containerSize = containers.reduce(Int64(0)) { $0 + ($1.sizeRw ?? 0) }
        let stopped = containers.filter { ContainerState(rawValue: $0.state ?? "") != .running }
        let containerReclaimable = stopped.reduce(Int64(0)) { $0 + ($1.sizeRw ?? 0) }

        let volumes = volumes ?? []
        let volumeSize = volumes.reduce(Int64(0)) { $0 + max(0, $1.usageData?.size ?? 0) }
        let unusedVolumes = volumes.filter { ($0.usageData?.refCount ?? 0) == 0 }
        let volumeReclaimable = unusedVolumes.reduce(Int64(0)) { $0 + max(0, $1.usageData?.size ?? 0) }

        let cache = buildCache ?? []
        let cacheSize = cache.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        let cacheReclaimable = cache.filter { !($0.inUse ?? false) && !($0.shared ?? false) }.reduce(Int64(0)) { $0 + ($1.size ?? 0) }

        return DiskUsageSummary(
            images: .init(count: images.count, active: activeImages.count, sizeBytes: layersSize ?? 0, reclaimableBytes: imageReclaimable),
            containers: .init(count: containers.count, active: containers.count - stopped.count, sizeBytes: containerSize, reclaimableBytes: containerReclaimable),
            volumes: .init(count: volumes.count, active: volumes.count - unusedVolumes.count, sizeBytes: volumeSize, reclaimableBytes: volumeReclaimable),
            buildCache: .init(count: cache.count, active: cache.filter { $0.inUse ?? false }.count, sizeBytes: cacheSize, reclaimableBytes: cacheReclaimable)
        )
    }
}

import ColimaDomain
import Foundation

/// Fetches an HTTPS resource. The app uses `URLSessionFetcher`; tests script the answers.
public protocol HTTPSFetching: Sendable {
    /// The body and response of a GET request. HTTP error statuses are returned, not thrown.
    func data(from url: URL) async throws -> (Data, HTTPURLResponse)
}

/// `URLSession`-backed fetcher.
public struct URLSessionFetcher: HTTPSFetching {
    /// Creates a fetcher.
    public init() {}

    public func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ImageCatalogError.unavailable("Unexpected response from \(url.host() ?? "the server").")
        }
        return (data, http)
    }
}

/// Docker Hub: searches through the engine (`/images/search`) and reads tags from Docker Hub's
/// web API, which the Engine API does not offer.
public final class DockerHubCatalog: ImageCatalog {
    public let name = ImageSourceKind.dockerHub.displayName
    /// Tags loaded per repository, newest first.
    static let pageSize = 50

    private let engine: any ImageSearching
    private let fetcher: any HTTPSFetching

    /// Creates a catalog that searches through `engine`.
    public init(engine: any ImageSearching, fetcher: any HTTPSFetching = URLSessionFetcher()) {
        self.engine = engine
        self.fetcher = fetcher
    }

    public func search(_ term: String, limit: Int) async throws -> [ImageSearchResult] {
        ImageSearchResult.ranked(try await engine.searchImages(term: term, limit: limit), for: term)
    }

    public func tags(of reference: ImageReference) async throws -> [ImageTag]? {
        guard let repository = reference.dockerHubRepository else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "hub.docker.com"
        components.path = "/v2/namespaces/\(repository.namespace)/repositories/\(repository.name)/tags"
        components.queryItems = [URLQueryItem(name: "page_size", value: String(Self.pageSize)), URLQueryItem(name: "ordering", value: "last_updated")]
        guard let url = components.url else { return [] }

        let (data, response) = try await fetcher.data(from: url)
        switch response.statusCode {
        case 200:
            do {
                return try JSONDecoder().decode(HubTagPage.self, from: data).results.map(\.domain)
            } catch {
                throw ImageCatalogError.unavailable("Docker Hub sent tags this app cannot read.")
            }
        case 404:
            return []
        case 429:
            throw ImageCatalogError.rateLimited
        default:
            throw ImageCatalogError.unavailable("Docker Hub answered with HTTP \(response.statusCode).")
        }
    }
}

/// A page of `GET /v2/namespaces/{namespace}/repositories/{repository}/tags`.
struct HubTagPage: Decodable {
    struct Tag: Decodable {
        struct Image: Decodable {
            let os: String?
            let architecture: String?
            let variant: String?
        }

        let name: String
        let lastUpdated: String?
        let images: [Image]?

        enum CodingKeys: String, CodingKey {
            case name, images
            case lastUpdated = "last_updated"
        }

        var domain: ImageTag {
            // Entries with os "unknown" are build attestations, not runnable images.
            var platforms: [ImagePlatform] = []
            for image in images ?? [] {
                guard let os = image.os, let architecture = image.architecture, os != "unknown" else { continue }
                let platform = ImagePlatform(os: os, architecture: architecture, variant: image.variant)
                if !platforms.contains(platform) { platforms.append(platform) }
            }
            return ImageTag(name: name, lastUpdated: lastUpdated.flatMap(Self.date), platforms: platforms)
        }

        private static func date(_ text: String) -> Date? {
            (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
                ?? (try? Date.ISO8601FormatStyle().parse(text))
        }
    }

    let results: [Tag]
}

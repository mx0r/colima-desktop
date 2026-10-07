import ColimaDomain
import Foundation
import Synchronization
import Testing
@testable import ColimaInfrastructure

@Suite("Docker image API")
struct DockerImageAPITests {
    private func json(_ status: String, _ body: String) -> String {
        "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
    }

    private let chunkedHead = Array("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)

    @Test("Search asks the engine and decodes a real response")
    func search() async throws {
        let transport = InMemoryTransport()
        transport.enqueue(json("200 OK", try Fixture.text("images-search.json")))
        let results = try await DockerEngineClient(transport: transport).searchImages(term: "redis db", limit: 25)
        #expect(transport.requestLines == ["GET /v1.44/images/search?term=redis%20db&limit=25 HTTP/1.1"])
        let redis = try #require(results.first { $0.name == "redis" })
        #expect(redis.isOfficial)
        #expect(redis.starCount > 0)
        #expect(!redis.description.isEmpty)
        #expect(results.count == 5)
    }

    @Test("A pull always names the tag and decodes a real up-to-date stream, split anywhere")
    func pullUpToDate() async throws {
        let body = Splits.chunked(try Array(Fixture.data("pull-up-to-date.bin")), chunkSize: 40)
        for (index, parts) in Splits.variants(of: body, seeds: [5]).enumerated() {
            let transport = InMemoryTransport()
            transport.enqueue([chunkedHead] + parts)
            let reference = try #require(ImageReference("hello-world"))
            var messages: [PullMessage] = []
            for try await message in DockerEngineClient(transport: transport).pullImage(reference) { messages.append(message) }
            #expect(transport.requestLines == ["POST /v1.44/images/create?fromImage=hello-world&tag=latest HTTP/1.1"], "variant \(index)")
            #expect(messages.map(\.status) == [
                "Pulling from library/hello-world",
                "Digest: sha256:5e23090353324d887c48ad5e5c56d294eab81588df9605b07d1afe895f9cc8f8",
                "Status: Image is up to date for hello-world:latest",
            ], "variant \(index)")
            #expect(messages.first?.id == "latest")
        }
    }

    @Test("Layer progress decodes with sizes")
    func pullLayers() async throws {
        let transport = InMemoryTransport()
        transport.enqueue([chunkedHead] + [Splits.chunked(try Array(Fixture.data("pull-layers.synthetic.ndjson")), chunkSize: 64)])
        var progress = PullProgress()
        for try await message in DockerEngineClient(transport: transport).pullImage(try #require(ImageReference("redis:8"))) {
            progress.apply(message)
        }
        #expect(transport.requestLines == ["POST /v1.44/images/create?fromImage=redis&tag=8 HTTP/1.1"])
        #expect(progress.layerCount == 2)
        #expect(progress.completedLayers == 2)
        #expect(progress.fractionCompleted == 1)
        #expect(progress.status == "Status: Downloaded newer image for redis:8")
    }

    @Test("An error inside the stream fails the pull with the engine's message")
    func pullErrorInStream() async throws {
        let lines = #"{"status":"Pulling from library/x","id":"latest"}"# + "\r\n"
            + #"{"errorDetail":{"message":"no matching manifest for linux/arm64/v8 in the manifest list entries"},"error":"no matching manifest for linux/arm64/v8 in the manifest list entries"}"# + "\r\n"
        let transport = InMemoryTransport()
        transport.enqueue([chunkedHead] + [Splits.chunked(Array(lines.utf8), chunkSize: 30)])
        var statuses: [String?] = []
        await #expect(throws: DockerError.pullFailed("no matching manifest for linux/arm64/v8 in the manifest list entries")) {
            for try await message in DockerEngineClient(transport: transport).pullImage(try #require(ImageReference("x"))) {
                statuses.append(message.status)
            }
        }
        #expect(statuses == ["Pulling from library/x"])
    }

    @Test("A refused pull reports the engine's message")
    func pullRefused() async throws {
        let message = "pull access denied for colima-desktop-test/does-not-exist, repository does not exist or may require 'docker login'"
        let transport = InMemoryTransport()
        transport.enqueue(json("404 Not Found", #"{"message":"\#(message)"}"#))
        await #expect(throws: DockerError.api(status: 404, message: message)) {
            for try await _ in DockerEngineClient(transport: transport).pullImage(try #require(ImageReference("colima-desktop-test/does-not-exist"))) {}
        }
    }

    @Test("Create sends the spec as Docker's create body and returns the ID")
    func create() async throws {
        let transport = InMemoryTransport()
        transport.enqueue(json("201 Created", #"{"Id":"c0ffee","Warnings":["memory limit ignored"]}"#))
        let spec = ContainerSpec(
            image: try #require(ImageReference("nginx:1.27")),
            name: "web-1",
            command: ["nginx", "-g", "daemon off;"],
            environment: [EnvironmentVariable(name: "MODE", value: "a=b")],
            ports: [PortBinding(hostPort: 8080, containerPort: 80, proto: .tcp), PortBinding(hostPort: nil, containerPort: 53, proto: .udp)],
            volumes: [VolumeBinding(source: "/Users/me/site", target: "/usr/share/nginx/html", readOnly: true)],
            restartPolicy: .unlessStopped,
            publishAllPorts: true
        )
        let created = try await DockerEngineClient(transport: transport).createContainer(spec)
        #expect(created == CreatedContainer(id: "c0ffee", warnings: ["memory limit ignored"]))
        #expect(transport.requestLines == ["POST /v1.44/containers/create?name=web-1 HTTP/1.1"])

        let sent = String(decoding: transport.connections[0].sentBytes, as: UTF8.self)
        let body = try #require(sent.range(of: "\r\n\r\n").map { String(sent[$0.upperBound...]) })
        let object = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        #expect(object["Image"] as? String == "nginx:1.27")
        #expect(object["Cmd"] as? [String] == ["nginx", "-g", "daemon off;"])
        #expect(object["Env"] as? [String] == ["MODE=a=b"])
        #expect((object["ExposedPorts"] as? [String: Any]).map { Set($0.keys) } == ["80/tcp", "53/udp"])
        let host = try #require(object["HostConfig"] as? [String: Any])
        let bindings = try #require(host["PortBindings"] as? [String: [[String: String]]])
        #expect(bindings["80/tcp"] == [["HostIp": "", "HostPort": "8080"]])
        #expect(bindings["53/udp"] == [["HostIp": "", "HostPort": ""]])
        #expect(host["Binds"] as? [String] == ["/Users/me/site:/usr/share/nginx/html:ro"])
        #expect((host["RestartPolicy"] as? [String: Any])?["Name"] as? String == "unless-stopped")
        #expect(host["PublishAllPorts"] as? Bool == true)
    }

    @Test("Without a name or command, neither is sent")
    func createMinimal() async throws {
        let transport = InMemoryTransport()
        transport.enqueue(json("201 Created", #"{"Id":"abc","Warnings":null}"#))
        let created = try await DockerEngineClient(transport: transport).createContainer(ContainerSpec(image: try #require(ImageReference("redis"))))
        #expect(created.warnings.isEmpty)
        #expect(transport.requestLines == ["POST /v1.44/containers/create HTTP/1.1"])
        let sent = String(decoding: transport.connections[0].sentBytes, as: UTF8.self)
        #expect(sent.contains(#""Image":"redis:latest""#))
        #expect(!sent.contains(#""Cmd""#))
    }

    @Test("A missing image is a 404 the caller can answer with a pull")
    func createMissingImage() async throws {
        let transport = InMemoryTransport()
        transport.enqueue(json("404 Not Found", #"{"message":"No such image: redis:8"}"#))
        await #expect(throws: DockerError.api(status: 404, message: "No such image: redis:8")) {
            _ = try await DockerEngineClient(transport: transport).createContainer(ContainerSpec(image: try #require(ImageReference("redis:8"))))
        }
    }
}

@Suite("Docker Hub catalog")
struct DockerHubCatalogTests {
    /// Answers every request with one scripted response and records the URLs.
    final class ScriptedFetcher: HTTPSFetching {
        let status: Int
        let body: Data
        let urls = Mutex<[URL]>([])

        init(status: Int, body: Data) {
            self.status = status
            self.body = body
        }

        func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
            urls.withLock { $0.append(url) }
            return (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    /// Engine that only answers searches.
    final class SearchOnlyEngine: ImageSearching {
        func searchImages(term: String, limit: Int) async throws -> [ImageSearchResult] {
            [
                ImageSearchResult(name: "mcp/redis", description: "", starCount: 14, isOfficial: false),
                ImageSearchResult(name: "redis", description: "", starCount: 13000, isOfficial: true),
            ]
        }
    }

    @Test("Tags come from Docker Hub's API, with platforms; attestation entries are left out")
    func tags() async throws {
        let fetcher = ScriptedFetcher(status: 200, body: try Fixture.data("hub-tags-redis.json"))
        let catalog = DockerHubCatalog(engine: SearchOnlyEngine(), fetcher: fetcher)
        let reference = try #require(ImageReference("redis:8"))
        let tags = try #require(try await catalog.tags(of: reference))
        #expect(fetcher.urls.withLock { $0.map(\.absoluteString) } == [
            "https://hub.docker.com/v2/namespaces/library/repositories/redis/tags?page_size=50&ordering=last_updated",
        ])
        #expect(tags.count == 3)
        let latest = try #require(tags.first)
        #expect(latest.name == "latest")
        #expect(latest.lastUpdated != nil)
        #expect(latest.supports(vmArchitecture: "aarch64") == true)
        #expect(!latest.platforms.contains { $0.os == "unknown" })
    }

    @Test("Images from other registries have no Docker Hub tags")
    func otherRegistry() async throws {
        let fetcher = ScriptedFetcher(status: 200, body: Data())
        let catalog = DockerHubCatalog(engine: SearchOnlyEngine(), fetcher: fetcher)
        #expect(try await catalog.tags(of: try #require(ImageReference("ghcr.io/owner/app"))) == nil)
        #expect(fetcher.urls.withLock { $0.isEmpty })
    }

    @Test("A repository Docker Hub does not know has no tags")
    func unknownRepository() async throws {
        let catalog = DockerHubCatalog(engine: SearchOnlyEngine(), fetcher: ScriptedFetcher(status: 404, body: Data(#"{"message":"object not found"}"#.utf8)))
        #expect(try await catalog.tags(of: try #require(ImageReference("someone/nothing"))) == [])
    }

    @Test("Rate limiting is reported as such")
    func rateLimited() async throws {
        let catalog = DockerHubCatalog(engine: SearchOnlyEngine(), fetcher: ScriptedFetcher(status: 429, body: Data()))
        await #expect(throws: ImageCatalogError.rateLimited) {
            _ = try await catalog.tags(of: try #require(ImageReference("redis")))
        }
    }

    @Test("Search goes through the engine and is ranked")
    func search() async throws {
        let catalog = DockerHubCatalog(engine: SearchOnlyEngine(), fetcher: ScriptedFetcher(status: 200, body: Data()))
        #expect(try await catalog.search("redis", limit: 25).map(\.name) == ["redis", "mcp/redis"])
        #expect(catalog.name == "Docker Hub")
    }
}

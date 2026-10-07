import Foundation
import Testing
@testable import ColimaDomain

@Suite("Image references")
struct ImageReferenceTests {
    @Test("Parses repositories, tags, digests and registries", arguments: [
        ("nginx", "nginx", nil, nil),
        ("nginx:1.27-alpine", "nginx", "1.27-alpine", nil),
        ("library/redis:8", "library/redis", "8", nil),
        ("ghcr.io/owner/app:v2", "ghcr.io/owner/app", "v2", nil),
        ("localhost:5000/app", "localhost:5000/app", nil, nil),
        ("localhost:5000/app:dev", "localhost:5000/app", "dev", nil),
        ("alpine@sha256:" + String(repeating: "a", count: 64), "alpine", nil, "sha256:" + String(repeating: "a", count: 64)),
        ("  redis  ", "redis", nil, nil),
    ] as [(String, String, String?, String?)])
    func parse(text: String, repository: String, tag: String?, digest: String?) throws {
        let reference = try #require(ImageReference(text))
        #expect(reference.repository == repository)
        #expect(reference.tag == tag)
        #expect(reference.digest == digest)
    }

    @Test("Rejects what Docker rejects", arguments: ["", "Nginx", "nginx:", "my image", "a/b:tag:more", "nginx:-bad", "@sha256:abc"])
    func reject(text: String) {
        #expect(ImageReference(text) == nil)
    }

    @Test("A pull always names a tag: without one Docker pulls every tag")
    func pullParameters() throws {
        #expect(try #require(ImageReference("nginx")).pullParameters == ImageReference.PullParameters(fromImage: "nginx", tag: "latest"))
        #expect(try #require(ImageReference("nginx:1.27")).pullParameters == ImageReference.PullParameters(fromImage: "nginx", tag: "1.27"))
        let digest = "sha256:" + String(repeating: "b", count: 64)
        #expect(try #require(ImageReference("nginx@\(digest)")).pullParameters == ImageReference.PullParameters(fromImage: "nginx", tag: digest))
    }

    @Test("The full form names the default tag")
    func description() throws {
        #expect(try #require(ImageReference("nginx")).description == "nginx:latest")
        #expect(try #require(ImageReference("ghcr.io/o/a:1")).description == "ghcr.io/o/a:1")
    }

    @Test("Docker Hub repositories resolve to namespace and name; other registries do not", arguments: [
        ("nginx", "library", "nginx"),
        ("bitnami/redis:7", "bitnami", "redis"),
        ("docker.io/library/alpine", "library", "alpine"),
        ("docker.io/alpine", "library", "alpine"),
    ])
    func dockerHub(text: String, namespace: String, name: String) throws {
        let reference = try #require(ImageReference(text))
        let repository = try #require(reference.dockerHubRepository)
        #expect(repository.namespace == namespace)
        #expect(repository.name == name)
    }

    @Test("Images from other registries have no Docker Hub repository", arguments: ["ghcr.io/owner/app", "localhost:5000/app", "quay.io/a/b"])
    func notDockerHub(text: String) throws {
        #expect(try #require(ImageReference(text)).dockerHubRepository == nil)
    }

    @Test("A tag can replace the one in the reference")
    func withTag() throws {
        let reference = try #require(ImageReference("redis:7"))
        #expect(reference.with(tag: "8").description == "redis:8")
    }
}

@Suite("Image search and tags")
struct ImageSearchTests {
    @Test("Exact matches come first, then official images, then by stars")
    func ranking() {
        let results = [
            ImageSearchResult(name: "mcp/redis", description: "", starCount: 14, isOfficial: false),
            ImageSearchResult(name: "bitnami/redis", description: "", starCount: 900, isOfficial: false),
            ImageSearchResult(name: "redis", description: "", starCount: 13000, isOfficial: true),
            ImageSearchResult(name: "redislabs/redis", description: "", starCount: 40, isOfficial: false),
        ]
        #expect(ImageSearchResult.ranked(results, for: "redis").map(\.name) == ["redis", "bitnami/redis", "redislabs/redis", "mcp/redis"])
        #expect(ImageSearchResult.ranked(results, for: "bitnami/redis").first?.name == "bitnami/redis")
    }

    @Test("VM architectures map to Docker platform names")
    func architectures() {
        #expect(ImagePlatform.dockerArchitecture(forVM: "aarch64") == "arm64")
        #expect(ImagePlatform.dockerArchitecture(forVM: "x86_64") == "amd64")
        #expect(ImagePlatform.dockerArchitecture(forVM: "riscv64") == "riscv64")
    }

    @Test("A tag supports a VM when it has a Linux image for its architecture; unknown without platforms")
    func tagSupport() {
        let tag = ImageTag(name: "8", lastUpdated: nil, platforms: [
            ImagePlatform(os: "linux", architecture: "amd64", variant: nil),
            ImagePlatform(os: "linux", architecture: "arm64", variant: "v8"),
        ])
        #expect(tag.supports(vmArchitecture: "aarch64") == true)
        #expect(tag.supports(vmArchitecture: "x86_64") == true)
        #expect(ImageTag(name: "x", lastUpdated: nil, platforms: [ImagePlatform(os: "linux", architecture: "amd64", variant: nil)]).supports(vmArchitecture: "aarch64") == false)
        #expect(ImageTag(name: "y", lastUpdated: nil, platforms: []).supports(vmArchitecture: "aarch64") == nil)
    }
}

@Suite("Pull progress")
struct PullProgressTests {
    private func message(_ status: String, id: String? = nil, current: Int64? = nil, total: Int64? = nil) -> PullMessage {
        PullMessage(id: id, status: status, current: current, total: total, error: nil)
    }

    @Test("Layer messages add up to a byte fraction; overall lines become the status")
    func layers() {
        var progress = PullProgress()
        progress.apply(message("Pulling from library/redis", id: "8"))
        #expect(progress.layerCount == 0)
        #expect(progress.status == "Pulling from library/redis")

        progress.apply(message("Pulling fs layer", id: "a"))
        progress.apply(message("Pulling fs layer", id: "b"))
        progress.apply(message("Already exists", id: "c"))
        progress.apply(message("Downloading", id: "a", current: 50, total: 100))
        progress.apply(message("Downloading", id: "b", current: 100, total: 300))
        #expect(progress.layerCount == 3)
        #expect(progress.completedLayers == 1)
        #expect(progress.fractionCompleted == 150.0 / 400.0)

        progress.apply(message("Download complete", id: "a"))
        progress.apply(message("Extracting", id: "a", current: 10, total: 100))
        #expect(progress.fractionCompleted == 200.0 / 400.0)
        progress.apply(message("Pull complete", id: "a"))
        progress.apply(message("Download complete", id: "b"))
        progress.apply(message("Pull complete", id: "b"))
        #expect(progress.completedLayers == 3)
        #expect(progress.fractionCompleted == 1)

        progress.apply(message("Status: Downloaded newer image for redis:8"))
        #expect(progress.status == "Status: Downloaded newer image for redis:8")
        #expect(progress.error == nil)
    }

    @Test("No byte fraction before any size is known")
    func unknownSizes() {
        var progress = PullProgress()
        progress.apply(message("Pulling fs layer", id: "a"))
        #expect(progress.fractionCompleted == nil)
    }

    @Test("An error message is kept")
    func error() {
        var progress = PullProgress()
        progress.apply(PullMessage(id: nil, status: nil, current: nil, total: nil, error: "no matching manifest for linux/arm64/v8"))
        #expect(progress.error == "no matching manifest for linux/arm64/v8")
    }
}

@Suite("Shell words")
struct ShellWordsTests {
    @Test("Splits like a POSIX shell, without expansion", arguments: [
        ("npm start", ["npm", "start"]),
        ("  sh   -c  'echo hi there'  ", ["sh", "-c", "echo hi there"]),
        (#"echo "a \"quoted\" word" \$HOME"#, ["echo", #"a "quoted" word"#, "$HOME"]),
        (#"say it\ loud"#, ["say", "it loud"]),
        ("a''b \"\"", ["ab", ""]),
        ("", []),
    ])
    func split(text: String, words: [String]) throws {
        #expect(try ShellWords.split(text) == words)
    }

    @Test("An unclosed quote is an error", arguments: ["echo 'oops", #"echo "oops"#, #"trailing\"#])
    func unclosed(text: String) {
        #expect(throws: ShellWords.SplitError.self) { try ShellWords.split(text) }
    }
}

@Suite("Container spec")
struct ContainerSpecTests {
    @Test("Container names follow Docker's rule")
    func names() {
        #expect(ContainerSpec.isValidName("web-1"))
        #expect(ContainerSpec.isValidName("my_app.v2"))
        #expect(!ContainerSpec.isValidName("x"))
        #expect(!ContainerSpec.isValidName("-web"))
        #expect(!ContainerSpec.isValidName("web app"))
    }

    @Test("Volume bindings render as Docker bind strings")
    func binds() {
        #expect(VolumeBinding(source: "/Users/me/site", target: "/usr/share/nginx/html", readOnly: true).bind == "/Users/me/site:/usr/share/nginx/html:ro")
        #expect(VolumeBinding(source: "pgdata", target: "/var/lib/postgresql/data", readOnly: false).bind == "pgdata:/var/lib/postgresql/data")
    }

    @Test("Port keys name the protocol")
    func portKeys() {
        #expect(PortBinding(hostPort: 8080, containerPort: 80, proto: .tcp).key == "80/tcp")
        #expect(PortBinding(hostPort: nil, containerPort: 53, proto: .udp).key == "53/udp")
    }
}

@Suite("Image source settings")
struct ImageSourceSettingsTests {
    @Test("Docker Hub is on by default")
    func defaults() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(settings.imageSources == [ImageSourceSetting(kind: .dockerHub, isEnabled: true)])
        #expect(settings.enabledImageSources == [.dockerHub])
    }

    @Test("Unknown sources are dropped, known ones keep their switch, missing ones are added")
    func tolerant() throws {
        let json = #"{"imageSources": [{"kind": "someRegistryFromTheFuture", "isEnabled": true}, {"kind": "dockerHub", "isEnabled": false}]}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(settings.imageSources == [ImageSourceSetting(kind: .dockerHub, isEnabled: false)])
        #expect(settings.enabledImageSources.isEmpty)

        let empty = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"imageSources": []}"#.utf8))
        #expect(empty.imageSources == [ImageSourceSetting(kind: .dockerHub, isEnabled: true)])
    }
}

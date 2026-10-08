import ColimaDomain
import ColimaTestSupport
import Foundation
import Testing
@testable import ColimaFeatures

@Suite("ContainerForm")
struct ContainerFormTests {
    private let home = "/Users/me"

    private func form(_ change: (inout ContainerForm) -> Void) -> ContainerForm {
        var form = ContainerForm()
        form.image = "nginx"
        change(&form)
        return form
    }

    private func messages(_ form: ContainerForm, _ field: ContainerForm.Field) -> [String] {
        form.validate(homeDirectory: home).issues.filter { $0.field == field }.map(\.message)
    }

    @Test("A complete form becomes a spec; blank rows are ignored")
    func complete() throws {
        let port = ContainerForm.PortRow(hostPort: "8080", containerPort: "80", proto: .tcp)
        let env = ContainerForm.EnvironmentRow(name: "MODE", value: "prod")
        let volume = ContainerForm.VolumeRow(source: "~/site", target: "/usr/share/nginx/html", readOnly: true)
        let named = ContainerForm.VolumeRow(source: "cache", target: "/cache", readOnly: false)
        let form = form {
            $0.tag = "1.27"
            $0.name = "web-1"
            $0.command = "nginx -g 'daemon off;'"
            $0.ports = [port, ContainerForm.PortRow()]
            $0.environment = [env, ContainerForm.EnvironmentRow()]
            $0.volumes = [volume, named, ContainerForm.VolumeRow()]
            $0.restartPolicy = .always
            $0.publishAllPorts = true
        }
        let result = form.validate(homeDirectory: home)
        #expect(result.issues.isEmpty)
        let spec = try #require(result.spec)
        #expect(spec.image.description == "nginx:1.27")
        #expect(spec.name == "web-1")
        #expect(spec.command == ["nginx", "-g", "daemon off;"])
        #expect(spec.ports == [PortBinding(hostPort: 8080, containerPort: 80, proto: .tcp)])
        #expect(spec.environment == [EnvironmentVariable(name: "MODE", value: "prod")])
        #expect(spec.volumes == [
            VolumeBinding(source: "/Users/me/site", target: "/usr/share/nginx/html", readOnly: true),
            VolumeBinding(source: "cache", target: "/cache", readOnly: false),
        ])
        #expect(spec.restartPolicy == .always)
        #expect(spec.publishAllPorts)
    }

    @Test("Empty optional fields leave Docker's defaults")
    func minimal() throws {
        let spec = try #require(form { _ in }.validate(homeDirectory: home).spec)
        #expect(spec.name == nil)
        #expect(spec.command == nil)
        #expect(spec.image.description == "nginx:latest")
    }

    @Test("The image is required and must be valid")
    func image() {
        #expect(messages(form { $0.image = "" }, .image) == ["Enter an image, for example nginx or ghcr.io/owner/app."])
        #expect(messages(form { $0.image = "Not Valid" }, .image) == ["This is not a valid image name."])
    }

    @Test("A tag in both places is ambiguous; a bad tag is rejected")
    func tag() {
        #expect(messages(form { $0.image = "nginx:1"; $0.tag = "2" }, .tag) == ["The image already names a tag. Remove one of them."])
        #expect(messages(form { $0.tag = "-x" }, .tag) == ["This is not a valid tag."])
        #expect(form { $0.image = "nginx:1" }.validate(homeDirectory: home).spec?.image.description == "nginx:1")
    }

    @Test("Container names follow Docker's rule")
    func name() {
        #expect(messages(form { $0.name = "x" }, .name).count == 1)
        #expect(messages(form { $0.name = "web 1" }, .name).count == 1)
        #expect(messages(form { $0.name = "web_1" }, .name).isEmpty)
    }

    @Test("A command with an open quote is rejected")
    func command() {
        #expect(messages(form { $0.command = "sh -c 'echo" }, .command) == ["A ' quote is not closed."])
    }

    @Test("Ports need a container port; the host port is optional; ports are numbers in range")
    func ports() {
        let missing = ContainerForm.PortRow(hostPort: "8080", containerPort: "", proto: .tcp)
        let range = ContainerForm.PortRow(hostPort: "70000", containerPort: "80", proto: .tcp)
        let random = ContainerForm.PortRow(hostPort: "", containerPort: "53", proto: .udp)
        #expect(messages(form { $0.ports = [missing] }, .port(missing.id)) == ["Enter the container port, a number from 1 to 65535."])
        #expect(messages(form { $0.ports = [range] }, .port(range.id)) == ["The host port must be a number from 1 to 65535."])
        #expect(form { $0.ports = [random] }.validate(homeDirectory: home).spec?.ports == [PortBinding(hostPort: nil, containerPort: 53, proto: .udp)])
    }

    @Test("A host port can be used once per protocol")
    func duplicatePorts() {
        let first = ContainerForm.PortRow(hostPort: "8080", containerPort: "80", proto: .tcp)
        let second = ContainerForm.PortRow(hostPort: "8080", containerPort: "81", proto: .tcp)
        let udp = ContainerForm.PortRow(hostPort: "8080", containerPort: "82", proto: .udp)
        #expect(messages(form { $0.ports = [first, second, udp] }, .port(second.id)) == ["Host port 8080/tcp is used twice."])
        #expect(messages(form { $0.ports = [first, second, udp] }, .port(udp.id)).isEmpty)
    }

    @Test("Environment names are required, without '=' or spaces, and unique")
    func environment() {
        let unnamed = ContainerForm.EnvironmentRow(name: "", value: "x")
        let bad = ContainerForm.EnvironmentRow(name: "A B", value: "x")
        let first = ContainerForm.EnvironmentRow(name: "MODE", value: "a")
        let again = ContainerForm.EnvironmentRow(name: "MODE", value: "b")
        #expect(messages(form { $0.environment = [unnamed] }, .environment(unnamed.id)) == ["Enter a name."])
        #expect(messages(form { $0.environment = [bad] }, .environment(bad.id)) == ["A name cannot contain '=' or spaces."])
        #expect(messages(form { $0.environment = [first, again] }, .environment(again.id)) == ["MODE is set twice."])
    }

    @Test("Volumes need an absolute host path or a volume name, and an absolute container path")
    func volumes() {
        let relative = ContainerForm.VolumeRow(source: "site/html", target: "/html", readOnly: false)
        let target = ContainerForm.VolumeRow(source: "/Users/me/site", target: "html", readOnly: false)
        let first = ContainerForm.VolumeRow(source: "/a", target: "/data", readOnly: false)
        let again = ContainerForm.VolumeRow(source: "/b", target: "/data", readOnly: false)
        #expect(messages(form { $0.volumes = [relative] }, .volume(relative.id)) == ["Use an absolute host path (/…, ~/…) or a volume name."])
        #expect(messages(form { $0.volumes = [target] }, .volume(target.id)) == ["The container path must start with /."])
        #expect(messages(form { $0.volumes = [first, again] }, .volume(again.id)) == ["Two volumes use /data."])
    }
}

@MainActor
@Suite("NewContainerViewModel")
struct NewContainerViewModelTests {
    private let clock = ManualClock()

    private func makeModel(
        engine: FakeDockerEngine = FakeDockerEngine(),
        catalog: FakeImageCatalog = FakeImageCatalog(),
        actions: Locked<[MenuAction]> = Locked([])
    ) -> NewContainerViewModel {
        NewContainerViewModel(
            engine: engine,
            catalogs: [catalog],
            vmArchitecture: "aarch64",
            homeDirectory: "/Users/me",
            clock: clock,
            onAction: { action in actions.withLock { $0.append(action) } }
        )
    }

    private let redis = ImageSearchResult(name: "redis", description: "Redis", starCount: 13000, isOfficial: true)

    @Test("Typing searches once, after a pause, for the last text")
    func debouncedSearch() async {
        let catalog = FakeImageCatalog()
        catalog.update { $0.results = [redis] }
        let sut = makeModel(catalog: catalog)
        sut.query = "re"
        sut.query = "red"
        sut.query = "redis"
        await clock.waitForSleepers()
        #expect(catalog.current.searches.isEmpty)
        await clock.advance(by: NewContainerViewModel.searchDelay)
        #expect(await eventually { sut.search == .results([NewContainerViewModel.SearchSection(source: "Docker Hub", results: [redis])]) })
        #expect(catalog.current.searches == ["redis"])
    }

    @Test("Short text does not search")
    func shortQuery() async {
        let catalog = FakeImageCatalog()
        let sut = makeModel(catalog: catalog)
        sut.query = "r"
        await clock.advance(by: NewContainerViewModel.searchDelay)
        #expect(sut.search == .idle)
        #expect(catalog.current.searches.isEmpty)
    }

    @Test("A failed search shows why")
    func searchFailure() async {
        let catalog = FakeImageCatalog()
        catalog.update { $0.searchError = .rateLimited }
        let sut = makeModel(catalog: catalog)
        sut.query = "redis"
        await clock.waitForSleepers()
        await clock.advance(by: NewContainerViewModel.searchDelay)
        #expect(await eventually { sut.search == .failed(ImageCatalogError.rateLimited.localizedDescription) })
    }

    @Test("Choosing a result fills the image and loads its tags")
    func select() async {
        let tag = ImageTag(name: "8", lastUpdated: nil, platforms: [ImagePlatform(os: "linux", architecture: "arm64", variant: nil)])
        let catalog = FakeImageCatalog()
        catalog.update { $0.tags["redis"] = [tag] }
        let sut = makeModel(catalog: catalog)
        sut.form.tag = "old"
        sut.select(redis)
        #expect(sut.form.image == "redis")
        #expect(sut.form.tag == "")
        #expect(await eventually { sut.tags == .loaded([tag]) })
        sut.form.tag = "8"
        #expect(sut.tagSupportsVM == true)
    }

    @Test("Images from other registries have no tag list")
    func otherRegistry() async {
        let sut = makeModel()
        sut.form.image = "ghcr.io/owner/app"
        sut.loadTags()
        #expect(await eventually { sut.tags == .notListed })
    }

    @Test("A missing image is pulled, then the container is created and started")
    func createPullsMissingImage() async throws {
        let engine = FakeDockerEngine()
        engine.update {
            $0.createResults = [.failure(.api(status: 404, message: "No such image: redis:8")), .success(CreatedContainer(id: "c1", warnings: []))]
            $0.pullMessages = [PullMessage(id: "a", status: "Downloading", current: 5, total: 10, error: nil)]
        }
        let sut = makeModel(engine: engine)
        sut.form.image = "redis"
        sut.form.tag = "8"
        sut.form.name = "cache"
        sut.create()
        #expect(await eventually { if case .finished = sut.phase { true } else { false } })
        #expect(sut.phase == .finished(NewContainerViewModel.Outcome(containerID: "c1", name: "cache", started: true, startError: nil, warnings: [])))
        #expect(engine.current.pulls.map(\.description) == ["redis:8"])
        #expect(engine.current.createdSpecs.count == 2)
        #expect(engine.current.actions.map { $0.0 } == [.start])
        #expect(engine.current.actions.map { $0.1 } == ["c1"])
    }

    @Test("Always pull pulls first; without start the container stays created")
    func alwaysPullNoStart() async {
        let engine = FakeDockerEngine()
        let sut = makeModel(engine: engine)
        sut.form.image = "redis"
        sut.form.alwaysPull = true
        sut.form.startAfterCreating = false
        sut.create()
        #expect(await eventually { if case .finished = sut.phase { true } else { false } })
        #expect(engine.current.pulls.count == 1)
        #expect(engine.current.createdSpecs.count == 1)
        #expect(engine.current.actions.isEmpty)
        if case .finished(let outcome) = sut.phase {
            #expect(!outcome.started)
            #expect(outcome.name == "new1")
        }
    }

    @Test("A failed pull is shown and nothing is created")
    func pullFailure() async {
        let engine = FakeDockerEngine()
        engine.update {
            $0.createResults = [.failure(.api(status: 404, message: "No such image: x:latest"))]
            $0.pullError = .pullFailed("no matching manifest for linux/arm64/v8")
        }
        let sut = makeModel(engine: engine)
        sut.form.image = "x"
        sut.create()
        #expect(await eventually { sut.phase == .failed(DockerError.pullFailed("no matching manifest for linux/arm64/v8").localizedDescription) })
        #expect(engine.current.createdSpecs.count == 1)
    }

    @Test("A container that does not start is still reported as created")
    func startFailure() async {
        let engine = FakeDockerEngine()
        engine.update { $0.actionError = .api(status: 500, message: "port is already allocated") }
        let sut = makeModel(engine: engine)
        sut.form.image = "nginx"
        sut.create()
        #expect(await eventually { if case .finished = sut.phase { true } else { false } })
        if case .finished(let outcome) = sut.phase {
            #expect(!outcome.started)
            #expect(outcome.startError == "port is already allocated")
        }
    }

    @Test("An invalid form shows its issues and calls nothing")
    func invalid() async {
        let engine = FakeDockerEngine()
        let sut = makeModel(engine: engine)
        #expect(sut.issues(for: .image).isEmpty)
        sut.create()
        #expect(sut.phase == .editing)
        #expect(!sut.issues(for: .image).isEmpty)
        #expect(engine.current.createdSpecs.isEmpty)
    }

    @Test("Cancel stops a pull and returns to the form")
    func cancel() async {
        let engine = FakeDockerEngine()
        engine.update {
            $0.createResults = [.failure(.api(status: 404, message: "No such image: big:latest"))]
            $0.pullHangs = true
        }
        let sut = makeModel(engine: engine)
        sut.form.image = "big"
        sut.create()
        #expect(await eventually { if case .pulling = sut.phase { true } else { false } })
        sut.cancel()
        #expect(await eventually { sut.phase == .editing })
        #expect(engine.current.createdSpecs.count == 1)
    }

    @Test("After creating, logs and terminal open for the new container")
    func openAfterwards() async {
        let actions = Locked<[MenuAction]>([])
        let sut = makeModel(actions: actions)
        sut.form.image = "nginx"
        sut.form.name = "web"
        sut.create()
        #expect(await eventually { if case .finished = sut.phase { true } else { false } })
        sut.showLogs()
        sut.openTerminal()
        #expect(actions.withLock { $0 } == [.showLogs(containerID: "new1", name: "web"), .openTerminal(containerID: "new1", name: "web")])
    }
}

import ColimaDomain
import ColimaFeatures
import ColimaInfrastructure
import Foundation

/// Builds the production dependencies.
enum LiveEnvironment {
    static func dependencies() -> AppDependencies {
        let processEnvironment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let locator = ExecutableLocator(pathVariable: processEnvironment["PATH"] ?? "")
        let runner = FoundationProcessRunner()

        let detect: @Sendable (AppSettings) -> DetectedEnvironment = { settings in
            let paths = ColimaPaths.resolve(settings: settings, environment: processEnvironment, homeDirectory: home) { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) && isDirectory.boolValue
            }
            return DetectedEnvironment(
                colimaExecutable: locator.locateColima(override: settings.colimaExecutablePath)?.path(percentEncoded: false),
                autoColimaExecutable: locator.locateColima(override: nil)?.path(percentEncoded: false),
                paths: paths
            )
        }

        return AppDependencies(
            settingsStore: UserDefaultsSettingsStore(),
            detectEnvironment: detect,
            makeColima: { settings in
                let executable = locator.locateColima(override: settings.colimaExecutablePath)
                let paths = detect(settings).paths
                // Pass homes only when overridden, so colima resolves them exactly as in a shell otherwise.
                let environment = ChildEnvironment.make(
                    base: processEnvironment,
                    executable: executable,
                    colimaHome: settings.colimaHomePath == nil ? nil : paths.colimaHome.path(percentEncoded: false),
                    limaHome: settings.limaHomePath == nil ? nil : paths.limaHome.path(percentEncoded: false)
                )
                return ColimaCLIClient(executable: executable, environment: environment, runner: runner)
            },
            makeDocker: { socketPath in DockerEngineClient(socketPath: socketPath) },
            fileWatcher: DispatchFileWatcher(),
            notifier: UNUserNotifier(),
            clock: ContinuousClock()
        )
    }
}

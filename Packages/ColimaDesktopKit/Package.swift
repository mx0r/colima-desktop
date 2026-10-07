// swift-tools-version: 6.2
import PackageDescription

/// Targets whose code runs on the main actor by default (AppKit / SwiftUI layers).
let mainActorByDefault: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
]

let package = Package(
    name: "ColimaDesktopKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ColimaAppShell", targets: ["ColimaAppShell"]),
    ],
    dependencies: [
        // Pinned exactly: 2.0 changes the public API.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0"),
        // Pinned exactly: the release workflow signs updates with this version's sign_update.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        // Pure models, reducers and ports. Foundation only.
        .target(name: "ColimaDomain"),

        // Adapters: processes, colima CLI, Docker Engine API over a unix socket, file watching, system services.
        .target(name: "ColimaInfrastructure", dependencies: ["ColimaDomain"]),

        // Presentation logic: observable stores, view models, menu model. Never imports Infrastructure.
        .target(name: "ColimaFeatures", dependencies: ["ColimaDomain"]),

        // AppKit menu rendering, windows and SwiftUI views.
        .target(
            name: "ColimaUI",
            dependencies: ["ColimaFeatures", "ColimaDomain"],
            swiftSettings: mainActorByDefault
        ),

        // Embedded terminal; isolates the SwiftTerm dependency.
        .target(
            name: "ColimaTerminal",
            dependencies: [
                "ColimaFeatures",
                "ColimaDomain",
                "ColimaUI",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            swiftSettings: mainActorByDefault
        ),

        // Self-update through Sparkle; isolates the dependency.
        .target(
            name: "ColimaUpdates",
            dependencies: ["ColimaDomain", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: mainActorByDefault
        ),

        // Composition root: wires concrete adapters into the features and UI.
        .target(
            name: "ColimaAppShell",
            dependencies: ["ColimaDomain", "ColimaInfrastructure", "ColimaFeatures", "ColimaUI", "ColimaTerminal", "ColimaUpdates"],
            swiftSettings: mainActorByDefault
        ),

        // Fakes and helpers shared by the test targets.
        .target(name: "ColimaTestSupport", dependencies: ["ColimaDomain", "ColimaFeatures"]),

        .testTarget(name: "ColimaDomainTests", dependencies: ["ColimaDomain"]),
        .testTarget(
            name: "ColimaInfrastructureTests",
            dependencies: ["ColimaInfrastructure", "ColimaDomain", "ColimaTestSupport"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "ColimaFeaturesTests", dependencies: ["ColimaFeatures", "ColimaDomain", "ColimaTestSupport"]),
        .testTarget(name: "ColimaUITests", dependencies: ["ColimaUI", "ColimaFeatures", "ColimaDomain"]),
        .testTarget(name: "ColimaUpdatesTests", dependencies: ["ColimaUpdates"]),
        // Runs against the local colima and Docker; enabled with COLIMA_DESKTOP_IT=1.
        .testTarget(
            name: "ColimaIntegrationTests",
            dependencies: ["ColimaInfrastructure", "ColimaFeatures", "ColimaDomain"]
        ),
    ]
)

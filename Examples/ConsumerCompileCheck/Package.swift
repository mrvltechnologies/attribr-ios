// swift-tools-version:6.0
//
// Not a shippable product — a compile-only fixture. Verifies, on every
// `swift build` in this directory, that a real consumer app can still:
//   1. Depend on Attribr via a local path (mirrors the GitHub SPM dependency
//      shape without needing network access or a pushed tag).
//   2. Wrap the SDK's @MainActor-isolated API in its own @MainActor type and
//      have it compile cleanly under Swift 6 strict concurrency.
//
// Added in v1.4.1 after an external developer's non-@MainActor wrapper hit a
// Swift 6 actor-isolation compile error — see CHANGELOG.md.
import PackageDescription

let package = Package(
    name: "ConsumerCompileCheck",
    platforms: [.iOS(.v15), .macOS(.v12)],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .target(
            name: "ConsumerCompileCheck",
            dependencies: [
                .product(name: "Attribr", package: "swift")
            ]
        )
    ]
)

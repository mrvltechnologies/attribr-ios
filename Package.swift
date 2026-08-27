// swift-tools-version:6.0
// Attribr by MRVL — Swift Package
//
// Requires Swift 6.0 tooling (Xcode 16+) — the source uses Swift 6 language
// mode features (`nonisolated(unsafe)`, strict concurrency checking).
//
// Constraints:
//   - ZERO third-party dependencies
//   - iOS 15+ minimum deployment target (some APIs, e.g. RevenueDiscoveryReporter,
//     are gated to iOS 16+/macOS 13+ via @available and degrade gracefully below that)
//   - Single product: "Attribr" library
//   - System frameworks only: Foundation, CryptoKit, StoreKit, Security, UIKit, os.log

import PackageDescription

let package = Package(
    name: "Attribr",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "Attribr",
            targets: ["Attribr"]
        )
    ],
    dependencies: [
        // NONE — Attribr's selling point is zero dependencies.
        // Do NOT add any packages here without explicit user approval.
    ],
    targets: [
        .target(
            name: "Attribr",
            path: "Sources/Attribr"
        ),
        .testTarget(
            name: "AttribrTests",
            dependencies: ["Attribr"],
            path: "Tests/AttribrTests"
        )
    ]
)

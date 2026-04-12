// swift-tools-version:6.0
// Attribr by MRVL — Swift Package
//
// 🚨 STUB FILE — full Package.swift will be written in Phase 4 of BUILD_PROMPT.md
//
// Constraints (from ARCHITECTURE.md):
//   - ZERO third-party dependencies
//   - iOS 18+ minimum deployment target
//   - Single product: "Attribr" library
//   - Only imports: Foundation, CryptoKit, AppTrackingTransparency, os.log
//
// See:
//   - ../ARCHITECTURE.md
//   - ../CONTRACTS.md (SDK public API section)
//   - ../BUILD_PROMPT.md (Task 4)

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

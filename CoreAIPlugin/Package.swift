// swift-tools-version: 6.0
//
// CoreAIPlugin — a sibling package to OpenCaptions.xcodeproj, NOT part of its
// package graph. It exists solely because Apple's Core AI / `coreai-models`
// hard-pins `platforms: [.macOS("27.0")]` (13 majors above OpenCaptions'
// 14.4+ deployment target) with no per-symbol `@available` annotations —
// SwiftPM enforces a dependency's platform floor on the whole consuming
// target, so OpenCaptions can never depend on this package directly. Instead
// it's built standalone into a `.dylib` (a Run Script build phase on the
// OpenCaptions target invokes `swift build` here and embeds the result into
// Contents/Frameworks/), and loaded at runtime via `dlopen`, gated behind
// `#available(macOS 27.0, *)` — see
// OpenCaptions/Services/Retranscription/CoreAI/CoreAIPluginLoader.swift.
//
// The ONLY thing shared with the app target is the plain `@objc` protocol in
// CoreAIPluginProtocol.swift, duplicated byte-for-byte on both sides — the
// two are independently compiled binaries linked at runtime through the
// Objective-C runtime's selector dispatch, not shared Swift module metadata.

import PackageDescription

let package = Package(
    name: "CoreAIPlugin",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "CoreAIPlugin", type: .dynamic, targets: ["CoreAIPlugin"])
    ],
    dependencies: [
        // No release tag covers the Parakeet TDT support (added in #136, after the
        // 0.2.0 tag) — pinned to a revision instead of a version range.
        .package(url: "https://github.com/apple/coreai-models", revision: "25a093b9fb05c99d90bd2d4ddbca44d95cbc6af8")
    ],
    targets: [
        .target(
            name: "CoreAIPlugin",
            dependencies: [
                .product(name: "CoreAISpeech", package: "coreai-models")
            ],
            path: "Sources/CoreAIPlugin"
        )
    ]
)

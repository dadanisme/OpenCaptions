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
        // Community wrapper around Core AI (john-rocky/coreai-kit) — its `KitTranscriber`
        // owns model download/caching itself (Application Support/CoreAIKit/Models), so this
        // replaces the apple/coreai-models CoreAISpeech dependency this package started with:
        // no export/hosting pipeline of our own needed, at the cost of depending on a solo
        // maintainer's fork of coreai-models internally (see catalog entry for Parakeet).
        .package(url: "https://github.com/john-rocky/coreai-kit", exact: "0.3.0")
    ],
    targets: [
        .target(
            name: "CoreAIPlugin",
            dependencies: [
                .product(name: "CoreAIKit", package: "coreai-kit")
            ],
            path: "Sources/CoreAIPlugin",
            // Swift 6's region-based isolation checker chokes on a `Task { }` inside an
            // @objc protocol conformance's completion-handler method ("pattern that the
            // region-based isolation checker does not understand how to check" — a beta
            // toolchain bug, not a real data race here; the boundary crossing is a single
            // completion call handed to withCheckedThrowingContinuation on the app side).
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

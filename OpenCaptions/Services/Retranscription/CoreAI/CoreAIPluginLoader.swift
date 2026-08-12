//
//  CoreAIPluginLoader.swift
//  OpenCaptions
//
//  dlopen/dlsym boundary into libCoreAIPlugin.dylib, embedded in
//  Contents/Frameworks/ by a Run Script build phase on the OpenCaptions
//  target (the plugin itself is built by the sibling CoreAIPlugin SPM
//  package at its own macOS 27.0 floor — see CoreAIPluginProtocol.swift's
//  header for why this can't just be `import`ed). Gated end to end behind
//  `#available(macOS 27.0, *)`: below that, the dylib is never even looked
//  up, so there's no trace of Core AI on an older OS.
//
//  Two factories share one dlopen'd handle (see `loadHandle()`): the
//  original Parakeet plugin (batch-only) and the Nemotron streaming plugin
//  added in issue #55, which backs BOTH live capture and batch
//  re-transcription — see CoreAIPluginProtocol+Nemotron.swift.
//

import Foundation

enum CoreAIPluginLoader {

    /// Whether the plugin can be loaded on this machine right now: macOS 27+
    /// AND the dylib is actually present in the app bundle. The dylib being
    /// absent (embed step not wired up yet, or a build that skipped it) is
    /// treated as "unavailable", not an error — this is what
    /// `RetranscriptionEngineKind.availableCases` checks to decide whether to
    /// show the Core AI option at all.
    static var isAvailable: Bool {
        guard #available(macOS 27.0, *) else { return false }
        return FileManager.default.fileExists(atPath: pluginURL.path)
    }

    private static let pluginURL = Bundle.main.bundleURL
        .appending(path: "Contents/Frameworks/libCoreAIPlugin.dylib")

    /// Cached across calls — dlopen-ing the same path twice just bumps a
    /// refcount, but there's no reason to pay dlsym's lookup cost more than once.
    private static var cachedHandle: UnsafeMutableRawPointer?

    enum LoadError: LocalizedError {
        case unavailable
        case dlopenFailed(String)
        case symbolNotFound

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "The Core AI plugin requires macOS 27 or later."
            case .dlopenFailed(let message):
                return "Couldn't load the Core AI plugin: \(message)"
            case .symbolNotFound:
                return "The Core AI plugin is missing its entry point."
            }
        }
    }

    /// Loads (or reuses) the plugin and returns a fresh transcription
    /// instance. Every call gets its own instance — the plugin is stateless
    /// per-transcription, so there's no reason to share one across concurrent
    /// re-transcriptions.
    static func makePlugin() throws -> any CoreAITranscriptionPlugin {
        let handle = try loadHandle()
        guard let symbol = dlsym(handle, "makeCoreAITranscriptionPlugin") else {
            throw LoadError.symbolNotFound
        }
        typealias FactoryFunction = @convention(c) () -> UnsafeMutableRawPointer
        let factory = unsafeBitCast(symbol, to: FactoryFunction.self)
        let raw = factory()
        let instance = Unmanaged<AnyObject>.fromOpaque(raw).takeRetainedValue()
        guard let plugin = instance as? CoreAITranscriptionPlugin else {
            throw LoadError.symbolNotFound
        }
        return plugin
    }

    /// Loads (or reuses) the Nemotron streaming plugin. Unlike `makePlugin()`, callers keep the
    /// returned instance around for a session's lifetime — the plugin itself caches the
    /// compiled model behind it (see `CoreAINemotronPlugin.ModelCache`), so a fresh instance
    /// here is cheap either way.
    static func makeNemotronPlugin() throws -> any CoreAINemotronTranscriptionPlugin {
        let handle = try loadHandle()
        guard let symbol = dlsym(handle, "makeCoreAINemotronTranscriptionPlugin") else {
            throw LoadError.symbolNotFound
        }
        typealias FactoryFunction = @convention(c) () -> UnsafeMutableRawPointer
        let factory = unsafeBitCast(symbol, to: FactoryFunction.self)
        let raw = factory()
        let instance = Unmanaged<AnyObject>.fromOpaque(raw).takeRetainedValue()
        guard let plugin = instance as? CoreAINemotronTranscriptionPlugin else {
            throw LoadError.symbolNotFound
        }
        return plugin
    }

    /// Cheap, nonisolated disk check — no network, no model load beyond what dlopen itself
    /// costs (cached after the first call). Lets `RetranscriptionEngineKind.isModelDownloaded`
    /// answer synchronously without going through the @MainActor `CoreAINemotronModelManager`.
    static func isNemotronModelDownloaded() -> Bool {
        (try? makeNemotronPlugin())?.isModelDownloaded() ?? false
    }

    /// Shared dlopen — both factories above link against the same dylib, so one handle (cached
    /// after the first call, per the type's own doc comment) serves either symbol lookup.
    private static func loadHandle() throws -> UnsafeMutableRawPointer {
        guard #available(macOS 27.0, *) else { throw LoadError.unavailable }
        if let cached = cachedHandle { return cached }
        guard let opened = dlopen(pluginURL.path, RTLD_NOW | RTLD_LOCAL) else {
            let message = dlerror().map { String(cString: $0) } ?? "unknown dlopen error"
            throw LoadError.dlopenFailed(message)
        }
        cachedHandle = opened
        return opened
    }
}

//
//  CoreAIPluginProtocol+Nemotron.swift
//  CoreAIPlugin
//
//  Keep this declaration BYTE-FOR-BYTE in sync with the app-side copy at
//  OpenCaptions/Services/Retranscription/CoreAI/CoreAIPluginProtocol+Nemotron.swift
//  — see CoreAIPluginProtocol.swift's header for why there are two copies and
//  why the explicit @objc(...) names on both the protocols and their methods
//  matter. Two protocols instead of one because Nemotron is real STREAMING
//  (issue #55): a session object crosses the boundary as its own @objc value,
//  fed one chunk at a time, rather than one file-in/text-out call like
//  CoreAITranscriptionPlugin's Parakeet.
//

import Foundation

@objc(CoreAINemotronTranscriptionPlugin) public protocol CoreAINemotronTranscriptionPlugin: NSObjectProtocol {
    /// Whether the Nemotron bundle is already on disk — a plain synchronous cache check,
    /// no network and no model load.
    @objc(isModelDownloaded)
    func isModelDownloaded() -> Bool

    /// Downloads (if needed) and loads the Nemotron bundle, reporting fractional progress in
    /// `[0, 1]`. Calls `completion` exactly once. The loaded model is cached for the lifetime of
    /// the plugin, so this only pays the ~50s first-load GPU-specialization cost once — later
    /// calls to `makeSession` reuse it.
    @objc(downloadModelWithProgress:completion:)
    func downloadModel(
        progress: @escaping @Sendable (Double) -> Void,
        completion: @escaping @Sendable (Bool, Error?) -> Void
    )

    /// Starts a new streaming session for a BCP-47 language tag (e.g. `"en-US"`). Calls
    /// `completion` exactly once, with either the session or an error — never both nil.
    @objc(makeSessionWithLanguage:completion:)
    func makeSession(
        language: String,
        completion: @escaping @Sendable (CoreAINemotronSession?, Error?) -> Void
    )
}

/// One live streaming session. NOT concurrency-safe: feed it from one caller at a time, and
/// never start a new `feed` before the previous call's completion has fired.
@objc(CoreAINemotronSession) public protocol CoreAINemotronSession: NSObjectProtocol {
    /// Feeds one chunk of 16 kHz mono Float32 PCM (raw little-endian bytes, any length) and
    /// calls `completion` with the running transcript-so-far — no 30s bucket, unlike Parakeet.
    @objc(feedSamples:completion:)
    func feed(samples: Data, completion: @escaping @Sendable (String?, Error?) -> Void)

    /// Flushes the tail (silence-padded) and returns the final transcript. Call at most once,
    /// after the last `feed`, and never `feed` again afterwards.
    @objc(finishWithCompletion:)
    func finish(completion: @escaping @Sendable (String?, Error?) -> Void)
}

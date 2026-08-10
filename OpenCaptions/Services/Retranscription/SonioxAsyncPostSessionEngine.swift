//
//  SonioxAsyncPostSessionEngine.swift
//  OpenCaptions
//
//  Cloud post-session re-transcription via Soniox's async/batch REST API
//  (`stt-async-v5`). The async model sees the full recording at once, so it's more
//  accurate — and its diarization is better — than the realtime WebSocket path used
//  live. Reuses the same `SONIOX_API_KEY` (bearer auth). Billable: the caller meters
//  it like a live cloud session. See the Soniox docs
//  (https://soniox.com/docs/stt/async/async-transcription).
//
//  The REST flow (upload → create → poll → fetch → delete) lives in
//  `SonioxAsyncPostSessionEngine+Requests`; this file holds the orchestration and
//  token mapping.
//

import Foundation

final class SonioxAsyncPostSessionEngine: PostSessionTranscriptionEngine {

    let capabilities = PostSessionEngineCapabilities(
        engineId: "soniox_async",
        displayName: "Cloud (Soniox)",
        supportsDiarization: true,
        isOnDevice: false
    )

    /// Base REST endpoint and async model id.
    let baseURL = URL(string: "https://api.soniox.com/v1")!
    let model = "stt-async-v5"

    /// Biasing context sent with the create request: the user's custom vocabulary,
    /// the app's built-in terms, and the display name (which the name-mention
    /// highlight keys off, so a correct spelling matters). Resolved by
    /// `VocabularyStore` on the main actor and injected here — the same context the
    /// live config uses, so re-transcribing can't bias differently than the session
    /// did. Already clamped to Soniox's context character cap.
    let sonioxContext: SonioxConfig.Context

    init(context: SonioxConfig.Context) {
        self.sonioxContext = context
    }

    func transcribe(
        audioURL: URL,
        progress: @escaping @MainActor (PostSessionProgress) -> Void
    ) async throws -> [PostSessionToken] {
        guard let key = SonioxSecrets.sonioxAPIKey else {
            throw PostSessionEngineError.missingAPIKey
        }
        let base = baseURL  // capture a Sendable local (avoids capturing `self` in the defer Task)

        await progress(PostSessionProgress(stage: .uploading))
        let fileId = try await uploadFile(audioURL, key: key)

        // Best-effort server-side cleanup of the uploaded file + job on ANY exit
        // (success, failure, cancellation) so we don't leave artifacts in the account.
        var transcriptionId: String?
        defer {
            let tid = transcriptionId
            Task { await SonioxAsyncPostSessionEngine.cleanup(baseURL: base, fileId: fileId, transcriptionId: tid, key: key) }
        }

        try Task.checkCancellation()
        await progress(PostSessionProgress(stage: .transcribing))
        let tid = try await createTranscription(fileId: fileId, key: key)
        transcriptionId = tid

        try await pollUntilComplete(transcriptionId: tid, key: key)

        await progress(PostSessionProgress(stage: .downloading))
        let tokens = try await fetchTranscript(transcriptionId: tid, key: key)
        guard !tokens.isEmpty else { throw PostSessionEngineError.emptyResult }
        return tokens
    }

    // MARK: - Token mapping

    /// Maps one Soniox async transcript token dict to a `PostSessionToken`,
    /// dropping Soniox control tokens. Soniox already prepends a leading space to
    /// word tokens, so `text` is used verbatim (the segment builder trims per line).
    static func token(from dict: [String: Any]) -> PostSessionToken? {
        guard let text = dict["text"] as? String, text != "<end>", text != "<fin>" else {
            return nil
        }
        return PostSessionToken(
            text: text,
            speaker: speaker(from: dict["speaker"]),
            startMs: intValue(dict["start_ms"]),
            endMs: intValue(dict["end_ms"])
        )
    }

    /// Soniox may encode `speaker` as Int, NSNumber, or String; `-1` when absent.
    static func speaker(from value: Any?) -> Int {
        if let n = value as? Int { return n }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String, let n = Int(s) { return n }
        return -1
    }

    /// Reads a JSON number as Int (handles Int and NSNumber), defaulting to 0.
    static func intValue(_ value: Any?) -> Int {
        if let n = value as? Int { return n }
        if let n = value as? NSNumber { return n.intValue }
        return 0
    }
}

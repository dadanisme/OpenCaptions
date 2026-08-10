//
//  MacTranscriptionViewModel+Lines.swift
//  OpenCaptions
//
//  Token → line building for every live engine. There is no buffer: each finalized
//  token is committed into `TranscriberModel` the moment it arrives, so finalized
//  text lives in exactly ONE place and appears on screen without waiting for a
//  sentence boundary. `LiveLineCursor` only decides how the committed text is
//  grouped (merge / new paragraph / new bubble).
//
//  `partialLine` is now strictly the engine's in-flight hypothesis — never
//  finalized text — which is what makes the two pipes one.
//  See docs/2026-07-29-macos-live-line-building.md.
//

import Foundation

extension MacTranscriptionViewModel {

    // MARK: - Finalized tokens

    /// Commits each finalized token straight into the transcript. Endpoint tokens
    /// (`<end>`) carry no text — they only mark that the next token lands on a
    /// natural break.
    @MainActor
    func commitFinalTokens(_ tokens: [TranscriptionToken]) {
        for token in tokens {
            if token.isEndpoint {
                lineCursor.noteEndpoint()
                continue
            }
            let times = resolvedTimes(startMs: token.start_ms, endMs: token.end_ms)
            commit(text: token.text, speaker: token.speaker, startMs: times.start, endMs: times.end)
        }
    }

    // MARK: - Live partial

    /// Publishes the engine's in-flight tokens as the live partial line.
    /// Unthrottled: finalized text no longer waits behind this pipe, and the
    /// partial is now short (a few words at most), so the old ~5 fps gate only
    /// added latency.
    @MainActor
    func updatePartialLine(_ tokens: [TranscriptionToken]) {
        // Soniox prepends a leading space to word tokens; drop it so the live line
        // doesn't render with a stray indent.
        partialLine = String(tokens.map(\.text).joined().drop(while: { $0 == " " }))
        // Carry the last diarized speaker so a Stop & Save mid-sentence, and the
        // web preview, both attribute the tail correctly.
        partialSpeaker = tokens.last { $0.speaker != TranscriptionToken.unknownSpeaker }?.speaker
        let times = resolvedTimes(
            startMs: tokens.first?.start_ms ?? 0, endMs: tokens.last?.end_ms ?? 0)
        partialStartMs = times.start
        partialEndMs = times.end
    }

    /// Separator to place between the open bubble's text and the in-flight partial.
    /// The partial has had its own leading space stripped for display, so one is
    /// needed when the bubble ends on a word character — but NOT when the engine
    /// already trailed its last final with whitespace (the on-device bridge does),
    /// which would double it.
    ///
    /// The live views join the partial to the bubble's tail with this, and
    /// `commitPartialTail` commits it with this, so what the user reads in flight is
    /// exactly what gets saved.
    var partialJoin: String {
        (finalLines.textLines.last?.last?.isWhitespace ?? true) ? "" : " "
    }

    /// The in-flight partial when it continues the open bubble, for the views to
    /// render at that bubble's tail. Nil when it must stand on its own: nothing
    /// committed yet, or the engine attributes it to a different speaker (whose text
    /// would be wrong to show inside the previous speaker's bubble).
    var trailingPartial: String? {
        guard !partialLine.isEmpty, let lastSpeaker = finalLines.speakers.last else { return nil }
        if let partialSpeaker, partialSpeaker != lastSpeaker { return nil }
        return partialJoin + partialLine
    }

    /// The in-flight partial when it needs its own bubble (see `trailingPartial`).
    var standalonePartial: String? {
        guard !partialLine.isEmpty, trailingPartial == nil else { return nil }
        return partialLine
    }

    /// Commits whatever the engine still had in flight when the session stopped, so
    /// Stop & Save mid-sentence keeps the last words. Goes through the same
    /// placement path as a finalized token.
    @MainActor
    func commitPartialTail() {
        let tail = partialLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else { return }
        let speaker = partialSpeaker
            ?? lineCursor.speaker
            ?? finalLines.speakers.last
            ?? TranscriptionToken.unknownSpeaker
        // Same join the live views used to render this tail, so the saved text
        // matches what was on screen.
        commit(
            text: partialJoin + tail,
            speaker: speaker, startMs: partialStartMs, endMs: partialEndMs
        )
        partialLine = ""
    }

    // MARK: - Session state

    /// Clears all line-building state. Called at `start()` and `discard()`.
    @MainActor
    func resetLineState() {
        lineCursor = LiveLineCursor()
        partialLine = ""
        partialSpeaker = nil
        partialStartMs = 0
        partialEndMs = 0
    }

    // MARK: - Commit

    /// Places one chunk of finalized text into the transcript and persists it.
    @MainActor
    private func commit(text: String, speaker: Int, startMs: Int, endMs: Int) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Inherit the open bubble's app on a plain merge; the cursor decides when a
        // fresh (O(samples)) read is actually needed.
        let sourceApp = lineCursor.needsSourceAppRefresh(for: text, speaker: speaker)
            ? appMonitor?.dominantApp(fromMs: startMs, toMs: endMs)
            : lineCursor.sourceApp

        let placement = lineCursor.place(text: text, speaker: speaker, sourceApp: sourceApp)
        // Drop only the LEADING whitespace when opening a bubble or paragraph, never
        // the trailing: engines disagree about which side of a word carries the
        // separator (Soniox leads with a space, the on-device bridge trails with one),
        // and `appendOrAdd` concatenates raw — trimming both ends would glue the next
        // on-device token onto this one's last word.
        let opener = String(text.drop(while: { $0.isWhitespace }))
        let body: String
        switch placement {
        case .newBubble:
            body = opener
        case .newParagraph:
            body = "\n\n" + opener
        case .merge:
            body = text
        }

        saveTranscriptionLine(
            text: body,
            // The cursor's speaker, not the token's: punctuation attributed to
            // another speaker must still merge into the bubble it punctuates.
            speaker: lineCursor.speaker ?? speaker,
            forceNewLine: placement == .newBubble,
            start: startMs, end: endMs, sourceApp: sourceApp
        )

        // Alert the user if their name was just spoken — an in-app HUD badge when
        // Open Captions is frontmost, else an OS notification. The notifier keeps a
        // rolling window, so a name split across tokens still matches; it debounces
        // internally and `serviceGeneration` scopes it per session. Gated on
        // `isRunning` so the tail commit at stop() (which runs after stop has
        // already flipped isRunning off) doesn't alert as the session ends.
        if isRunning {
            MacNameMentionNotifier.shared.handle(
                finalizedFragment: text, sessionGeneration: serviceGeneration)
        }
    }

    // MARK: - Timestamps

    /// Session-relative times for a token.
    ///
    /// Soniox's audio-relative `start_ms`/`end_ms` are the position in the audio
    /// stream we sent, so they map straight to a file offset in the saved recording
    /// and are used as-is — stamping arrival time instead would desync the playback
    /// playhead by Soniox's finalization lag (seconds). See
    /// docs/2026-07-08-macos-session-audio-playback.md.
    ///
    /// On-device engines (Nemotron/Parakeet) report 0/0
    /// (`providesReliableTimestamps == false`), so we stamp from our own session
    /// clock instead — within the engine's confirmation lag of the spoken audio.
    /// See docs/2026-07-10-macos-on-device-engines.md.
    @MainActor
    func resolvedTimes(startMs: Int, endMs: Int) -> (start: Int, end: Int) {
        guard transcriptionService?.capabilities.providesReliableTimestamps ?? true else {
            let clockMs = Int(totalActiveTime * 1000)
            return (clockMs, clockMs)
        }
        return (max(0, startMs), max(0, endMs))
    }
}

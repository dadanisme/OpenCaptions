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
        // RAW engine text, spacing intact — including the leading space Soniox puts
        // on a word token and omits on a sub-word continuation. The views join it to
        // the open bubble by plain concatenation (`trailingPartial`), exactly as the
        // finalized path does, so the two can't disagree about a word boundary.
        // Only `standalonePartial` trims, because it opens a line.
        partialLine = tokens.map(\.text).joined()
        // Carry the last diarized speaker so a Stop & Save mid-sentence, and the
        // web preview, both attribute the tail correctly.
        partialSpeaker = tokens.last { $0.speaker != TranscriptionToken.unknownSpeaker }?.speaker
        let times = resolvedTimes(
            startMs: tokens.first?.start_ms ?? 0, endMs: tokens.last?.end_ms ?? 0)
        partialStartMs = times.start
        partialEndMs = times.end
    }

    /// Whether the engine has in-flight text worth rendering. A partial that is
    /// nothing but a separator is not text.
    var hasPartial: Bool { partialLine.contains { !$0.isWhitespace } }

    /// The in-flight partial when it continues the open bubble, for the views to
    /// render at that bubble's tail. Nil when it must stand on its own: nothing
    /// committed yet, or the engine attributes it to a different speaker (whose text
    /// would be wrong to show inside the previous speaker's bubble).
    ///
    /// Appended VERBATIM. The engine's own spacing is the separator — the same
    /// contract `commit()`'s `.merge` case relies on — so what the user reads in
    /// flight is what gets committed. This deliberately does NOT inject a space when
    /// the bubble ends on a word character: Soniox streams sub-word tokens, so a
    /// partial with no leading space is usually the REST OF THE OPEN WORD, and
    /// injecting there renders "wat er" a beat before it commits as "water".
    var trailingPartial: String? {
        guard hasPartial, let lastSpeaker = finalLines.speakers.last else { return nil }
        if let partialSpeaker, partialSpeaker != lastSpeaker { return nil }
        return partialLine
    }

    /// The in-flight partial when it needs its own bubble (see `trailingPartial`).
    /// Leading whitespace is dropped here, and only here: this opens a line, where
    /// the engine's separator would render as a stray indent.
    var standalonePartial: String? {
        guard hasPartial, trailingPartial == nil else { return nil }
        return String(partialLine.drop(while: { $0.isWhitespace }))
    }

    /// Commits whatever the engine still had in flight when the session stopped, so
    /// Stop & Save mid-sentence keeps the last words. Goes through the same
    /// placement path as a finalized token.
    @MainActor
    func commitPartialTail() {
        guard hasPartial else { return }
        let speaker = partialSpeaker
            ?? lineCursor.speaker
            ?? finalLines.speakers.last
            ?? TranscriptionToken.unknownSpeaker
        // Verbatim, exactly as the live views rendered it — `commit()` drops the
        // leading separator only if this tail ends up opening a bubble.
        commit(
            text: partialLine,
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
        guard !text.isEmpty else { return }

        // A whitespace-only token is a SEPARATOR, not content. This path used to drop
        // it outright, which silently broke the concatenation invariant every other
        // rule here depends on: the space vanished and the next token's word glued
        // onto the previous one ("below" + " " + "that" → "belowthat"). Merge it into
        // the open bubble instead — and only there, since a separator with nothing to
        // attach to is correctly discarded rather than opening a bubble on an indent.
        if !text.contains(where: { !$0.isWhitespace }) {
            // `!textLines.isEmpty` as well as an open cursor: `appendOrAdd` falls back
            // to creating a line when there's nothing to append to, and a bubble made
            // of one space is worse than a lost separator.
            guard let bubbleSpeaker = lineCursor.speaker, !finalLines.textLines.isEmpty
            else { return }
            lineCursor.noteSeparator()
            saveTranscriptionLine(
                text: text, speaker: bubbleSpeaker, forceNewLine: false,
                start: startMs, end: endMs, sourceApp: lineCursor.sourceApp
            )
            return
        }

        // Inherit the open bubble's app on a plain merge; the cursor decides when a
        // fresh (O(samples)) read is actually needed.
        let sourceApp = lineCursor.needsSourceAppRefresh(for: text, speaker: speaker)
            ? appMonitor?.dominantApp(fromMs: startMs, toMs: endMs)
            : lineCursor.sourceApp

        // Snapshot before `place()` clears the endpoint flag and advances the cursor's
        // own whitespace tracking to reflect THIS token.
        let afterEndpoint = lineCursor.didSeeEndpoint
        let bubbleEndedWithWhitespace = finalLines.textLines.last?.last?.isWhitespace ?? true

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
            body = mergedText(
                text, bubbleEndedWithWhitespace: bubbleEndedWithWhitespace,
                afterEndpoint: afterEndpoint)
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

    /// Restores the leading separator on the first finalized token AFTER an engine
    /// endpoint (Soniox `<end>`), which occasionally arrives without the leading space
    /// Soniox otherwise puts on a word token — gluing the resumed word onto the last
    /// one committed before the pause ("I mean right below" + "that" → "belowthat").
    ///
    /// **Scoped to the post-endpoint token on purpose.** Soniox tokenizes *sub-word*:
    /// "messy" streams as "m" + "ess" + "y", and the ONLY thing marking those as
    /// continuations rather than new words is the absence of a leading space — the
    /// same signal `LiveLineCursor.isBreakableSeam` already reads that way. So
    /// "no leading space" cannot be treated as a missing separator in general; doing
    /// that shreds ordinary speech into "m ess y / sor ry / wat er". An endpoint is
    /// the one boundary where a continuation is impossible, because `<end>` is only
    /// emitted at a speech pause — never mid-word. Everywhere else the token's own
    /// spacing is authoritative and is used verbatim.
    ///
    /// Still requires a genuine word/number boundary: a bare-punctuation merge (".")
    /// must attach with no space, and spaceless scripts (CJK) never take one.
    /// Deliberately checks both `.isLetter` and `.isNumber` — unlike
    /// `SentenceHeuristics.isWordCharacter`, where only letters matter — so a numeral
    /// resuming after a pause (dates, times, counts) is caught the same as a word is.
    private func mergedText(
        _ text: String, bubbleEndedWithWhitespace: Bool, afterEndpoint: Bool
    ) -> String {
        guard afterEndpoint, !bubbleEndedWithWhitespace,
            let first = text.first, !first.isWhitespace
        else { return text }
        let startsWordOrNumber =
            (first.isLetter || first.isNumber) && !SentenceHeuristics.isSpacelessScript(first)
        return startsWordOrNumber ? " " + text : text
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

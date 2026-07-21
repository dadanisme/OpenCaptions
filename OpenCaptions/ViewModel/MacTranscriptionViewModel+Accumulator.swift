//
//  MacTranscriptionViewModel+Accumulator.swift
//  OgmoMac
//
//  Token → bubble accumulation for the diarization-on (Soniox) path. Ported
//  verbatim from the iOS `OnlineViewModel+Accumulator`/`+TokenProcessing`,
//  minus the Firestore mirror and Live Activity pushes. Soniox always runs with
//  diarization on here, so the diarization-off streaming path is omitted.
//

import Foundation
import SwiftData

extension MacTranscriptionViewModel {

    // MARK: - Token processing

    /// Feeds finalized tokens into the sentence accumulator. Endpoint tokens flush
    /// the current sentence only when it already ends in sentence punctuation, so
    /// bubbles never get cut mid-sentence.
    @MainActor
    func processFinalTokens(_ tokens: [TranscriptionToken]) {
        guard !tokens.isEmpty else { return }
        for token in tokens {
            if token.isEndpoint {
                if endsWithSentence(accumulator.text) { flushSentence() }
            } else {
                accumulateText(
                    token.text,
                    speaker: token.speaker,
                    startMs: token.start_ms,
                    endMs: token.end_ms
                )
            }
        }
    }

    /// Updates the live partial display: accumulator (finalized-but-uncommitted)
    /// text plus the current Soniox partial tokens. Throttled to ~5 fps.
    @MainActor
    func updatePartialLine(_ tokens: [TranscriptionToken]) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastPartialLineUpdate >= 0.2 else { return }
        lastPartialLineUpdate = now

        let partialText = tokens.map(\.text).joined()
        let combined = accumulator.isEmpty ? partialText : accumulator.text + partialText
        // Soniox prepends a leading space to word tokens; drop it so the live
        // line doesn't render with a stray indent.
        partialLine = String(combined.drop(while: { $0 == " " }))

        // Mirror the in-flight preview to Firestore (no-op until shared).
        pushPartialToFirestore(partialText: partialText)
    }

    // MARK: - Accumulator

    /// Feeds text into the accumulator, flushing on every complete sentence.
    @MainActor
    func accumulateText(_ text: String, speaker: Int, startMs: Int, endMs: Int) {
        // Speaker changed — flush the old buffer, start fresh. On-device engines are
        // single-stream (speaker == -1 for every token), so this never fires for them and
        // the whole session accumulates as one speaker.
        if accumulator.speaker != -1 && accumulator.speaker != speaker {
            flushAccumulator()
        }
        if accumulator.speaker == -1 {
            accumulator.speaker = speaker
        }
        // Stamp times from Soniox's audio-relative token timestamps (position in
        // the audio stream) rather than wall-clock. Soniox holds a final back until
        // the accumulator/finalization window settles, so its wall-clock arrival
        // lags the spoken audio by seconds; stamping arrival time would desync the
        // saved-recording playhead. The recording is the exact stream sent to
        // Soniox, so `start_ms` maps straight to a file offset. `text.isEmpty` marks
        // the first token of this sentence (reset after each flush). See
        // docs/2026-07-08-macos-session-audio-playback.md.
        //
        // On-device engines (Parakeet/Nemotron) emit no reliable per-token timestamps
        // (start/end == 0), so we stamp from our own session clock instead — the timeline
        // and playhead still advance, staying within the engine's confirmation lag of the
        // spoken audio. Mirrors the iOS OnlineViewModel path for
        // `providesReliableTimestamps == false`. See docs/2026-07-10-macos-on-device-engines.md.
        let usesClock = !(transcriptionService?.capabilities.providesReliableTimestamps ?? true)
        let clockMs = Int(totalActiveTime * 1000)
        let stampStart = usesClock ? clockMs : startMs
        let stampEnd = usesClock ? clockMs : endMs
        if accumulator.text.isEmpty, stampStart >= 0 {
            accumulator.startMs = stampStart
        }

        accumulator.text += text
        if stampEnd >= 0 { accumulator.endMs = stampEnd }

        if endsWithSentence(accumulator.text) {
            flushSentence()
            return
        }

        // Safety net: force-flush on word boundary if the sentence runs away
        // without punctuation, to bound partial-bubble growth.
        if countWords(in: accumulator.text) > TranscriptionConstants.maxAccumulatorWords {
            flushAccumulator()
        }
    }

    /// Commits the current sentence buffer to a bubble, splitting into new
    /// paragraphs/bubbles once the word and paragraph limits are reached.
    @MainActor
    func flushSentence() {
        let sentence = accumulator.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty else {
            accumulator.resetSentence()
            return
        }

        // Alert the user if this finalized sentence mentions their name — an in-app
        // HUD badge when Ogmo is frontmost, else an OS notification (issue #255).
        // Finalized-lines only (this is the finalized-sentence commit point) and
        // debounced inside the notifier; `serviceGeneration` scopes it per session.
        // Gated on `isRunning` so the tail flush at stop() (which runs after stop
        // has already flipped isRunning off) doesn't alert as the recording ends.
        if isRunning {
            MacNameMentionNotifier.shared.handle(finalizedLine: sentence, sessionGeneration: serviceGeneration)
        }

        let sentenceWords = countWords(in: sentence)
        let speaker = accumulator.speaker
        let startMs = accumulator.startMs
        let endMs = accumulator.endMs
        // Source app for this sentence's window (nil = mic / attribution off).
        let sourceApp = appMonitor?.dominantApp(fromMs: startMs, toMs: endMs)
        // Within a same-speaker run the sentence would normally merge into the last
        // bubble; force a new one when the source app changed so each bubble's glyph
        // reflects a single app.
        let sameSpeakerRun = !finalLines.textLines.isEmpty && finalLines.speakers.last == speaker
        let appChanged = sameSpeakerRun && finalLines.sourceApps.last != sourceApp

        let wouldExceed = accumulator.bubbleWordCount + sentenceWords > TranscriptionConstants.maxWordsPerParagraph
            && accumulator.bubbleWordCount > 0

        if appChanged {
            // New bubble for the new app: reset paragraph/word tracking, no merge.
            accumulator.bubbleParagraphCount = 0
            accumulator.bubbleWordCount = sentenceWords
            saveTranscriptionLine(
                text: sentence, speaker: speaker, forceNewLine: true,
                start: startMs, end: endMs, sourceApp: sourceApp
            )
        } else if wouldExceed {
            accumulator.bubbleParagraphCount += 1
            accumulator.bubbleWordCount = sentenceWords

            if accumulator.bubbleParagraphCount >= TranscriptionConstants.maxParagraphsPerBubble {
                accumulator.bubbleParagraphCount = 0
                saveTranscriptionLine(
                    text: sentence, speaker: speaker, forceNewLine: true,
                    start: startMs, end: endMs, sourceApp: sourceApp
                )
            } else {
                saveTranscriptionLine(
                    text: "\n\n" + sentence, speaker: speaker, forceNewLine: false,
                    start: startMs, end: endMs, sourceApp: sourceApp
                )
            }
        } else {
            accumulator.bubbleWordCount += sentenceWords
            saveTranscriptionLine(
                text: sameSpeakerRun ? " " + sentence : sentence,
                speaker: speaker, forceNewLine: false,
                start: startMs, end: endMs, sourceApp: sourceApp
            )
        }

        accumulator.resetSentence()
        lastPartialLineUpdate = 0
    }

    /// Flushes whatever is buffered (complete or not) — used on speaker change and stop.
    @MainActor
    func flushAccumulator() {
        let text = accumulator.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            accumulator.reset()
            return
        }
        flushSentence()
        accumulator.reset()
    }

    /// Appends a committed line to the in-memory model (speaker-grouped) and
    /// applies any speaker rename. Debounced flush to SwiftData for long sessions.
    @MainActor
    func saveTranscriptionLine(
        text: String, speaker: Int, forceNewLine: Bool, start: Int, end: Int, sourceApp: String?
    ) {
        let sliceTime = TimeRange(start_ms: start, end_ms: end)
        let prevBubbleCount = finalLines.ids.count
        finalLines.appendOrAdd(
            text: text, speaker: speaker, forceNewLine: forceNewLine,
            time: sliceTime, sourceApp: sourceApp
        )
        let isNewBubble = finalLines.ids.count > prevBubbleCount

        if let mappedName = speakerMapping[speaker] {
            finalLines.updateName(name: mappedName, id: speaker)
        }

        // Mirror the committed bubble to Firestore (no-op until shared).
        mirrorCommittedLine(isNewBubble: isNewBubble)

        guard finalLines.textLines.count > TranscriptionConstants.flushThreshold,
              flushTask == nil,
              let container = modelContainer else { return }

        // Create the session on first flush so mid-session lines have a home.
        if finalLines.activeSessionID == nil {
            let session = TranscriptionSession(
                sessionDate: Date(),
                sessionTitle: "",
                cloudSessionId: finalLines.cloudSessionId,
                userId: finalLines.ownerUserId // scope to the signed-in user (set at start())
            )
            let mainContext = ModelContext(container)
            mainContext.insert(session)
            try? mainContext.save()
            finalLines.activeSessionID = session.persistentModelID
        }

        if let extracted = finalLines.extractOldLines(),
           let sessionID = finalLines.activeSessionID {
            let model = finalLines
            let durationMs = finalLines.currentDurationMs
            flushTask = Task.detached {
                let bgContext = ModelContext(container)
                model.persistLines(extracted, to: bgContext, sessionID: sessionID, durationMs: durationMs)
                await MainActor.run { [weak self] in
                    self?.flushTask = nil
                    self?.finalLines.persistenceVersion += 1
                }
            }
        }
    }

    // MARK: - Text helpers
    // Thin wrappers over the shared `SentenceHeuristics` so the live accumulator and
    // the batch `PostSessionSegmentBuilder` never drift on word/sentence rules.

    /// Counts whitespace-separated words.
    func countWords(in text: String) -> Int {
        SentenceHeuristics.countWords(in: text)
    }

    /// A space-delimited word character (letter, not from a space-less script).
    func isWordCharacter(_ ch: Character?) -> Bool {
        SentenceHeuristics.isWordCharacter(ch)
    }

    /// Whether text ends a complete sentence (Latin `.!?`, CJK `。！？`, and a
    /// closing quote right after a terminator), ignoring text inside open quotes.
    func endsWithSentence(_ text: String) -> Bool {
        SentenceHeuristics.endsWithSentence(text)
    }
}

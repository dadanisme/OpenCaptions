//
//  MacTranscriptionViewModel+Engine.swift
//  OpenCaptions
//
//  Engine plumbing split out of the main view model to keep it under the 250-line limit:
//  wiring the selected engine's callbacks into the token pipeline, and building the Soniox
//  config. Engine SELECTION (which kind to build) lives in `start()`; see
//  `MacTranscriptionEngineKind`/`MacTranscriptionEngineFactory`.
//

import Foundation

extension MacTranscriptionViewModel {

    // MARK: - Callbacks

    /// Installs the engine's token / error / connection callbacks, each guarded by the captured
    /// `serviceGeneration` so a stale callback after a stop/swap is dropped. `onTokens` hops to the
    /// main actor and builds lines (`+Lines`); a `.disconnected` state aborts the session (this
    /// target has no reconnection). On-device engines only ever report `.connected`, so they never
    /// trip it.
    ///
    /// Finals are committed BEFORE the partial is published, so the live view never shows the same
    /// words twice — the partial that replaces them is whatever the engine still has in flight.
    func wireCallbacks(_ service: any RealtimeTranscriptionEngine) {
        let generation = serviceGeneration
        service.onTokens = { [weak self] finals, partials in
            guard let self else { return }
            Task { @MainActor in
                guard self.serviceGeneration == generation else { return }
                self.commitFinalTokens(finals)
                self.updatePartialLine(partials)
            }
        }
        service.onError = { [weak self] error in
            print("❌ Transcription error: \(error)")
            // Soniox reports a rejected config / server fault as an `error_code` frame
            // and then closes the socket. Both paths end the session, but only this one
            // knows WHY, so surface it here — the `.disconnected` failure that follows
            // is swallowed by `failSession`'s running-or-paused guard, leaving this
            // message on screen.
            guard case .provider(_, let message) = error else { return }
            Task { @MainActor in
                guard let self, self.serviceGeneration == generation else { return }
                self.failSession(message: "Transcription service error: \(message)")
            }
        }
        service.onConnectionStateChange = { [weak self] state in
            Task { @MainActor in
                guard let self, self.serviceGeneration == generation else { return }
                if case .disconnected = state {
                    // Socket is dead and this target has no reconnection: stop
                    // cleanly instead of streaming mic audio into a void while
                    // the UI keeps claiming it's recording.
                    self.failSession(message: "Connection lost. Session stopped — tap End to keep this transcript.")
                }
            }
        }
    }

    // MARK: - Soniox config

    /// Builds the Soniox config for the standalone Mac app: fixed language hints
    /// (id/en/ar), diarization on.
    ///
    /// The biasing context — the user's custom vocabulary, the app's built-in terms,
    /// and the display name — comes from `VocabularyStore`, which is also what the
    /// async re-transcription path reads, so the two can't drift. Read ONCE here at
    /// session start: editing the vocabulary mid-session doesn't affect the running
    /// session (the config is the socket's first frame and is never resent), which is
    /// what the Vocabulary screen's "next session" note refers to.
    ///
    /// - Parameter userName: the signed-in user's display name, biased into the
    ///   context `terms` so recognition is pushed toward transcribing it correctly —
    ///   this is the string the name-mention highlight + notify key off, so getting it
    ///   right at the source matters most. Nil/blank (offline guests have no name)
    ///   simply contributes nothing.
    ///
    /// `@MainActor` because `VocabularyStore` is — the class itself isn't isolated at
    /// type level here, only its members are, so a static needs saying explicitly.
    /// Its only caller, `start()`, is already on the main actor.
    @MainActor
    static func makeSonioxConfig(userName: String?) -> SonioxConfig {
        SonioxConfig(
            languageHints: ["id", "en", "ar"],
            isLanguageHintsStrict: TranscriptionConstants.isLanguageHintsStrict,
            context: VocabularyStore.shared.sonioxContext(userName: userName),
            isSpeakerDiarizationEnabled: true
        )
    }
}

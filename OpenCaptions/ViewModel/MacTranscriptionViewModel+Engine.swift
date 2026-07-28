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
    /// main actor and feeds the accumulator; a `.disconnected` state aborts the session (this target
    /// has no reconnection). On-device engines only ever report `.connected`, so they never trip it.
    func wireCallbacks(_ service: any RealtimeTranscriptionEngine) {
        let generation = serviceGeneration
        service.onTokens = { [weak self] finals, partials in
            guard let self else { return }
            Task { @MainActor in
                guard self.serviceGeneration == generation else { return }
                self.processFinalTokens(finals)
                self.updatePartialLine(partials)
            }
        }
        service.onError = { error in
            print("❌ Transcription error: \(error)")
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
    /// - Parameter userName: the signed-in user's display name, appended to the
    ///   Soniox context `terms` so recognition is biased toward transcribing it
    ///   correctly — this is the string the name-mention highlight + notify key
    ///   off, so getting it right at the source matters most. Nil/blank (offline
    ///   guests have no name) simply appends nothing.
    static func makeSonioxConfig(userName: String?) -> SonioxConfig {
        var terms = ["Open Captions", "Soniox", "Apple Developer Academy"]
        if let name = userName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty, !terms.contains(name) {
            terms.append(name)
        }
        let context = SonioxConfig.Context(
            general: [
                .init(key: "domain", value: "education/lecture/meeting"),
                .init(key: "intent", value: "Transcription"),
                .init(key: "app_name", value: "Open Captions"),
            ],
            terms: terms,
            text: nil
        )
        return SonioxConfig(
            languageHints: ["id", "en", "ar"],
            isLanguageHintsStrict: TranscriptionConstants.isLanguageHintsStrict,
            context: context,
            isSpeakerDiarizationEnabled: true
        )
    }
}

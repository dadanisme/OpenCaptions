//
//  RetranscriptionManager.swift
//  OpenCaptions
//
//  App-lifetime owner of post-session re-transcription runs. A singleton so a
//  run SURVIVES leaving/closing the session-detail window — the work continues in the
//  background and the transcript updates in place when it finishes; the user is never
//  pinned to a window during a long upload/decode. A single per-session in-flight
//  registry (keyed by PersistentIdentifier) serves BOTH the manual and automatic
//  paths, so they can't overlap and double-run the same recording.
//
//  Progress/errors are exposed as @Observable per-session dictionaries the detail view
//  renders as a non-blocking banner + alert. The heavy work is delegated to
//  `PostSessionRetranscriber.run`.
//

import Foundation
import SwiftData

@Observable
@MainActor
final class RetranscriptionManager {

    static let shared = RetranscriptionManager()
    private init() {}

    /// Progress per running session (entry present ⇒ running). Observable, so it drives
    /// the banner and the menu's disabled state.
    private(set) var progressBySession: [PersistentIdentifier: PostSessionProgress] = [:]
    /// Last error per session, surfaced by the detail view and cleared on ack.
    var errorBySession: [PersistentIdentifier: String] = [:]

    /// Live tasks (for cancellation + the authoritative in-flight guard). Not observed.
    @ObservationIgnored private var tasks: [PersistentIdentifier: Task<Void, Never>] = [:]

    // MARK: - Queries

    func isRunning(_ id: PersistentIdentifier) -> Bool { progressBySession[id] != nil }
    func progress(_ id: PersistentIdentifier) -> PostSessionProgress? { progressBySession[id] }
    func cancel(_ id: PersistentIdentifier) { tasks[id]?.cancel() }

    // MARK: - Manual

    /// Starts an interactive re-transcription. Errors surface via `errorBySession`.
    /// No-op if this session is already being processed.
    func startManual(sessionID: PersistentIdentifier, kind: RetranscriptionEngineKind, context: ModelContext) {
        launch(sessionID: sessionID, kind: kind, context: context, interactive: true)
    }

    // MARK: - Automatic

    /// Starts automatic re-transcription for a just-saved session when enabled. The
    /// engine follows Offline Mode. Background, silent (no error surfacing).
    func startAutomatic(sessionID: PersistentIdentifier, container: ModelContainer) {
        guard FeatureFlagService.shared.isEnabled(.postSessionRetranscription),
              UserDefaults.standard.bool(forKey: LiveSessionStore.retranscriptionAutoKey) else { return }
        launch(sessionID: sessionID, kind: .forCurrentMode, context: container.mainContext, interactive: false)
    }

    // MARK: - Core

    private func launch(
        sessionID: PersistentIdentifier,
        kind: RetranscriptionEngineKind,
        context: ModelContext,
        interactive: Bool
    ) {
        // Single in-flight registry shared by both paths.
        guard tasks[sessionID] == nil else { return }

        // Never run alongside a file import filling in this same session — both drive
        // PostSessionRetranscriber.run over it (transcript corruption). The
        // detail menu already disables in this case; this guards other future callers.
        if FileImportManager.shared.isRunning(sessionID) {
            if interactive { errorBySession[sessionID] = "This session is still being imported. Try again when it finishes." }
            return
        }

        // Never run alongside a live recording (shared audio/CPU).
        if let live = LiveSessionStore.shared.viewModel, live.isRunning || live.isPaused {
            if interactive { errorBySession[sessionID] = "Finish your current recording before re-transcribing." }
            return
        }
        guard let session = context.model(for: sessionID) as? TranscriptionSession,
              let fileName = session.audioFileName else {
            if interactive { errorBySession[sessionID] = PostSessionEngineError.audioUnavailable.localizedDescription }
            return
        }
        let audioURL = SessionAudioStore.url(for: fileName)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            if interactive { errorBySession[sessionID] = PostSessionEngineError.audioUnavailable.localizedDescription }
            return
        }
        if kind == .parakeet, !FluidAudioModelLoader.isParakeetDownloaded() {
            if interactive { errorBySession[sessionID] = PostSessionEngineError.modelNotDownloaded.localizedDescription }
            return
        }

        progressBySession[sessionID] = PostSessionProgress(stage: .preparing)
        let task = Task { [weak self] in
            defer { self?.finishTracking(sessionID) }

            do {
                try await PostSessionRetranscriber.run(
                    kind: kind,
                    session: session,
                    audioURL: audioURL,
                    context: context,
                    userName: MacAuthManager.shared.userName,
                    progress: { [weak self] update in
                        guard let self, self.tasks[sessionID] != nil else { return }
                        self.progressBySession[sessionID] = update
                    }
                )
            } catch is CancellationError {
                // Clean cancel — no error surfaced.
            } catch {
                if interactive { self?.errorBySession[sessionID] = error.localizedDescription }
            }
        }
        tasks[sessionID] = task
    }

    private func finishTracking(_ id: PersistentIdentifier) {
        tasks[id] = nil
        progressBySession[id] = nil
    }
}

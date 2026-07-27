//
//  FileImportManager.swift
//  OpenCaptions
//
//  App-lifetime owner of "import a media file → saved session" runs. A
//  singleton so an import SURVIVES leaving/closing the window — the transcode +
//  transcription continue in the background and the new session fills in when done.
//
//  It adds only the ingest steps unique to import (transcode via `MediaAudioExtractor`,
//  create the session) and DELEGATES the actual transcription — line
//  building and summary regeneration — to the shared
//  `PostSessionRetranscriber.run`, so imported and re-transcribed sessions can't drift.
//  The engine follows Offline Mode (Parakeet on-device / Soniox cloud), exactly like
//  re-transcription. Progress/errors are `@Observable` so the session-list spinner and
//  the session-detail banner can render them. Mirrors `RetranscriptionManager`.
//
//  The session is created UP FRONT (before the transcode) so it appears in the list
//  with a spinner and its detail shows the progress banner for the whole run — and so
//  re-transcription can be blocked for it while the import is in flight (they'd both
//  run `PostSessionRetranscriber.run` over the same session otherwise). On failure or
//  cancel the session is KEPT (never deleted out from under a detail view the user may
//  have open); one that reached the audio stage can simply be re-transcribed to retry.
//

import AVFoundation
import Foundation
import SwiftData

/// One in-flight import, surfaced by the session-list spinner and the detail banner.
struct ImportJob: Identifiable {
    let id: UUID
    /// Display name (the source file's last path component).
    let fileName: String
    var progress: PostSessionProgress
    /// The session this import is filling in (set once it's created).
    let sessionID: PersistentIdentifier
}

@Observable
@MainActor
final class FileImportManager {

    static let shared = FileImportManager()
    private init() {}

    /// Active imports (observable ⇒ drives the list spinner + detail banner).
    private(set) var jobs: [ImportJob] = []
    /// Last error, surfaced by an alert and cleared on ack.
    var errorMessage: String?

    /// Live tasks keyed by job id — for cancellation and the in-flight guard. Not observed.
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - Queries

    /// True while an import is filling in this session (list-row spinner + re-transcribe gate).
    func isRunning(_ id: PersistentIdentifier) -> Bool {
        jobs.contains { $0.sessionID == id }
    }

    /// The in-flight import for this session, if any (drives the detail banner).
    func job(for id: PersistentIdentifier) -> ImportJob? {
        jobs.first { $0.sessionID == id }
    }

    func cancel(_ jobID: UUID) { tasks[jobID]?.cancel() }

    // MARK: - Entry

    /// Begins importing `source`. Refuses while a live recording is active (shared
    /// audio/CPU), mirroring `RetranscriptionManager`.
    func importFile(_ source: URL, container: ModelContainer) {
        if let live = LiveSessionStore.shared.viewModel, live.isRunning || live.isPaused {
            errorMessage = "Finish your current recording before importing a file."
            return
        }
        let jobID = UUID()
        let displayName = source.lastPathComponent
        tasks[jobID] = Task { [weak self] in
            await self?.run(jobID: jobID, source: source, displayName: displayName, container: container)
        }
    }

    // MARK: - Core

    private func run(jobID: UUID, source: URL, displayName: String, container: ModelContainer) async {
        defer { finish(jobID) }

        // `.fileImporter` hands back a security-scoped URL; access must be bracketed.
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let context = container.mainContext

        // Validate audio before any session exists, so a rejected file leaves nothing behind.
        let asset = AVURLAsset(url: source)
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard !audioTracks.isEmpty else {
            errorMessage = MediaImportError.noAudioTrack.localizedDescription
            return
        }

        let kind = RetranscriptionEngineKind.forCurrentMode
        if kind == .parakeet, !FluidAudioModelLoader.isParakeetDownloaded() {
            errorMessage = PostSessionEngineError.modelNotDownloaded.localizedDescription
            return
        }

        // Create the session up front (empty, audio-less) so it appears in the list with
        // a spinner and its detail shows the import banner for the whole run. Scoped to
        // the signed-in user; titled from the file name.
        let session = TranscriptionSession(
            sessionDate: Date(),
            sessionTitle: (displayName as NSString).deletingPathExtension,
            userId: MacAuthManager.shared.ownerId
        )
        context.insert(session)
        do {
            try context.save()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        jobs.append(ImportJob(id: jobID, fileName: displayName,
                              progress: PostSessionProgress(stage: .preparing),
                              sessionID: session.persistentModelID))

        // 1. Normalize the source to the canonical `.m4a` (banner: "Preparing audio…").
        let audioFileName: String
        do {
            let result = try await MediaAudioExtractor.extractToSessionAudio(source: source) { [weak self] fraction in
                self?.update(jobID, PostSessionProgress(stage: .preparing, fraction: fraction))
            }
            audioFileName = result.fileName
        } catch is CancellationError {
            return  // keep the (empty) session; the partial audio file is already removed
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        session.audioFileName = audioFileName
        try? context.save()

        // 2. Transcribe via the shared pipeline (builds lines, summarizes).
        //    `replaceTranscript` no-ops on the empty session before inserting the transcript.
        do {
            try await PostSessionRetranscriber.run(
                kind: kind,
                session: session,
                audioURL: SessionAudioStore.url(for: audioFileName),
                context: context,
                userName: MacAuthManager.shared.userName,
                progress: { [weak self] update in self?.update(jobID, update) }
            )
        } catch is CancellationError {
            return  // keep what exists — a session with audio can be re-transcribed to retry
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        // 3. Retention follows the "Save session audio" setting: if audio-saving is off,
        //    drop the normalized file (transcript + summary are already persisted).
        if !isAudioSavingEnabled {
            SessionAudioStore.delete(fileName: audioFileName)
            session.audioFileName = nil
            try? context.save()
        }
    }

    /// Whether to keep the normalized audio — same gate as live recording
    /// (`MacTranscriptionViewModel.isAudioRecordingEnabled`).
    private var isAudioSavingEnabled: Bool {
        UserDefaults.standard.bool(forKey: LiveSessionStore.sessionAudioKey)
    }

    // MARK: - Tracking helpers

    private func update(_ jobID: UUID, _ progress: PostSessionProgress) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].progress = progress
    }

    private func finish(_ jobID: UUID) {
        tasks[jobID] = nil
        jobs.removeAll { $0.id == jobID }
    }
}

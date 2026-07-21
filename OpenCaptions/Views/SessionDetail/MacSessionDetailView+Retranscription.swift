//
//  MacSessionDetailView+Retranscription.swift
//  OgmoMac
//
//  The manual "Re-transcribe" toolbar action and its overlays (confirmation, a
//  non-blocking progress banner, error alert, paywall) for the saved-session detail
//  screen. The actual work runs in the app-lifetime `RetranscriptionManager`, so it
//  keeps going if the user leaves this window. Split from MacSessionDetailView to keep
//  that file under the line limit. See issue #245.
//

import SwiftData
import SwiftUI

extension MacSessionDetailView {

    // MARK: - Menu

    /// The "Re-transcribe" action, shown when the feature flag is on and the session
    /// has a saved recording. No engine choice — it follows Offline Mode (Parakeet
    /// offline / Soniox cloud). Disabled while a run is in flight for this session, or
    /// when the offline model is missing while Offline Mode is on.
    @ViewBuilder
    var retranscribeMenu: some View {
        if FeatureFlagService.shared.isEnabled(.postSessionRetranscription),
           session.audioFileName != nil {
            let kind = RetranscriptionEngineKind.forCurrentMode
            let offlineModelMissing = kind == .parakeet && !FluidAudioModelLoader.isParakeetDownloaded()
            // Disabled while a re-transcription OR a file import is filling in this
            // session — both drive PostSessionRetranscriber.run over it, so they must
            // never overlap (which would double-meter and corrupt the transcript). #302.
            let running = RetranscriptionManager.shared.isRunning(session.persistentModelID)
                || FileImportManager.shared.isRunning(session.persistentModelID)
            Button {
                pendingRetranscribeKind = kind
            } label: {
                Label("Re-transcribe", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(running || offlineModelMissing)
            .help(offlineModelMissing
                ? "Download the offline model in Settings → General → Offline Mode"
                : (kind == .parakeet
                    ? "Re-transcribe offline on this Mac (free, English only)"
                    : "Re-transcribe in the cloud with speaker labels (uses minutes)"))
        }
    }

    // MARK: - Progress banner

    /// The in-flight batch-pass banner for this session, if any — a file import (#302)
    /// or a re-transcription (#245). Read in the detail view's `body` (via its single
    /// top overlay) so it stays reactive. Import takes priority, though the two can't
    /// co-occur (re-transcribe is disabled while an import runs).
    @ViewBuilder
    var postSessionBanner: some View {
        if let job = FileImportManager.shared.job(for: session.persistentModelID) {
            PostSessionProgressBanner(kind: .importFile(name: job.fileName), progress: job.progress) {
                FileImportManager.shared.cancel(job.id)
            }
        } else if let progress = RetranscriptionManager.shared.progress(session.persistentModelID) {
            PostSessionProgressBanner(kind: .retranscribe, progress: progress) {
                RetranscriptionManager.shared.cancel(session.persistentModelID)
            }
        }
    }
}

// MARK: - Overlays

/// Installs the re-transcription confirmation dialog, error alert, and paywall on the
/// detail view. Applied once in `MacSessionDetailView.mainContent`. The progress banner
/// itself is the shared `postSessionBanner` overlay (which also covers file imports);
/// this modifier only carries the interaction chrome.
struct RetranscriptionModifier: ViewModifier {
    @Binding var pendingKind: RetranscriptionEngineKind?
    @Binding var showPaywall: Bool
    let session: TranscriptionSession
    let context: ModelContext

    private var manager: RetranscriptionManager { .shared }
    private var sessionID: PersistentIdentifier { session.persistentModelID }

    func body(content: Content) -> some View {
        // Read observable manager state in `body` so the alert stays reactive. The
        // progress banner is rendered by MacSessionDetailView's single shared overlay
        // (`postSessionBanner`), which also covers file-import runs.
        let errorMessage = manager.errorBySession[sessionID]

        return content
            .confirmationDialog(
                "Re-transcribe this session?",
                isPresented: confirmationPresented,
                titleVisibility: .visible,
                presenting: pendingKind
            ) { _ in
                Button("Re-transcribe", role: .destructive) {
                    let kind = pendingKind
                    pendingKind = nil
                    Task { await begin(kind) }
                }
                Button("Cancel", role: .cancel) { pendingKind = nil }
            } message: { kind in
                Text(Self.confirmMessage(for: kind, session: session))
            }
            .alert(
                "Re-transcription Failed",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { manager.errorBySession[sessionID] = nil } })
            ) {
                Button("OK", role: .cancel) { manager.errorBySession[sessionID] = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(isPresented: $showPaywall) {
                MacPaywallView(onPurchased: { Task { await begin(RetranscriptionEngineKind.forCurrentMode) } })
            }
    }

    /// Cloud paywall pre-check on the full estimated cost, then hand off to the
    /// background manager. Called from the confirmation and from a post-top-up retry.
    private func begin(_ kind: RetranscriptionEngineKind?) async {
        guard let kind else { return }
        if kind.isMetered, let fileName = session.audioFileName {
            let audioURL = SessionAudioStore.url(for: fileName)
            let minutes = Int(ceil(await PostSessionRetranscriber.audioDurationSeconds(audioURL) / 60.0))
            guard await MacSubscriptionManager.shared.canAfford(minutes: minutes) else {
                showPaywall = true
                return
            }
        }
        manager.startManual(sessionID: sessionID, kind: kind, context: context)
    }

    private var confirmationPresented: Binding<Bool> {
        Binding(get: { pendingKind != nil }, set: { if !$0 { pendingKind = nil } })
    }

    /// Engine-specific confirmation copy, warning about diarization loss when
    /// re-transcribing a diarized session offline.
    static func confirmMessage(for kind: RetranscriptionEngineKind, session: TranscriptionSession) -> String {
        var parts = ["This replaces the current transcript and summary for this session. It runs in the background — you can leave this window."]
        switch kind {
        case .parakeet:
            parts.append("It runs offline on this Mac (English only) and is free.")
            if session.lines.contains(where: { $0.speakerId > 0 }) {
                parts.append("Speaker labels will be removed — offline re-transcription produces a single unlabeled transcript.")
            }
        case .soniox:
            parts.append("It runs in the cloud with speaker labels and uses minutes from your balance (about 1 minute per minute of audio).")
        }
        return parts.joined(separator: " ")
    }
}

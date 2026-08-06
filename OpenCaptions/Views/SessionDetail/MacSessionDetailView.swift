//
//  MacSessionDetailView.swift
//  OpenCaptions
//
//  Saved-session detail: AI summary + full transcript, with a toolbar action
//  to (re)generate the summary via the cloud function.
//

import AppKit
import SwiftData
import SwiftUI

struct MacSessionDetailView: View {
    // Not `private`: the share/password logic lives in a same-type extension
    // (MacSessionDetailView+Sharing) to keep this file under the line limit.
    @Environment(\.modelContext) var modelContext
    @Environment(MacAuthManager.self) private var auth
    @Environment(\.dismiss) private var dismiss
    /// App-wide UI text scale, forwarded to `SourceAppIcon` in the transcript rows
    /// so the source-app glyph scales with the timestamp / speaker beside it. Not
    /// `private`: the row that reads it lives in the `MacSessionDetailView+Playback`
    /// extension (a separate file).
    @Environment(\.appTextScale) var appTextScale
    /// Offline Mode disables cloud AI summary GENERATION (there's no on-device
    /// summarizer) and share-to-web. Existing summaries stay visible.
    @AppStorage(LiveSessionStore.offlineModeKey) private var isOffline = false
    let session: TranscriptionSession
    /// Workspaces this session's owner can file it under. Scoped by `session.userId`
    /// (not a separately-threaded owner id) since that's already this session's
    /// own account scope.
    @Query private var workspaces: [Workspace]

    @State private var summaryVM = SummaryViewModel()
    /// Audio playback + playhead for the synced transcript. Not `private`: the
    /// player UI + synced transcript live in the `MacSessionDetailView+Playback`
    /// extension (a separate file).
    @State var playback = PlaybackViewModel()
    /// Selected tab (Summary / Transcript). Not `private`: the top `tabSwitcher`
    /// pill lives in the `MacSessionDetailView+Playback` extension (a separate file).
    @State var tab: Tab = .summary
    /// Guards the on-appear auto-summary so a failed attempt doesn't loop.
    @State private var didAutoSummarize = false
    /// Non-nil presents the share dialog (link + password) for this session.
    @State private var shareTarget: ShareTarget?
    /// Presents the delete confirmation before removing this session.
    @State private var showDeleteConfirmation = false
    /// Presents the batch speaker-rename sheet (diarized sessions only).
    @State private var showSpeakerEditor = false
    /// Speaker being renamed from a transcript bubble's right-click menu; non-nil
    /// drives the single-speaker rename sheet. Not `private`: the context menu
    /// that sets it lives in the `MacSessionDetailView+Playback` extension.
    @State var renameTarget: SpeakerRenameTarget?
    /// Manual re-transcription UI state. The run itself lives in the
    /// app-lifetime `RetranscriptionManager`; this only drives the confirmation.
    /// Not `private`: the menu (sets `pendingRetranscribeKind`) + overlays
    /// live in the `MacSessionDetailView+Retranscription` extension.
    @State var pendingRetranscribeKind: RetranscriptionEngineKind?

    enum Tab: Hashable { case summary, transcript }

    /// `@Query`'s default initializer can't read a runtime value, so the
    /// workspace predicate is built here from the session's own owner id.
    init(session: TranscriptionSession) {
        self.session = session
        let ownerId = session.userId
        _workspaces = Query(
            filter: #Predicate<Workspace> { $0.userId == ownerId },
            sort: \.name
        )
    }

    /// Whether there's any summary content to export.
    private var hasSummaryContent: Bool {
        !session.summaryParagraphs.isEmpty
            || !session.summaryKeyPoints.isEmpty
            || !session.actionItems.isEmpty
    }

    var body: some View {
        // Defense-in-depth: the scoped list never hands us a foreign session, but
        // guard anyway so a future code path can't leak one across accounts.
        // Compared against the effective owner (uid, or the "local" guest sentinel)
        // so a guest's own sessions open. Legacy `nil`-owner sessions are allowed
        // through (the backfill claims them).
        if session.userId != nil && session.userId != auth.ownerId {
            ContentUnavailableView(
                "Not Available",
                systemImage: "lock",
                description: Text("This transcription belongs to another account.")
            )
        } else {
            mainContent
        }
    }

    private var mainContent: some View {
        // Content swaps instantly (no animation here) — only the toolbar `tabSwitcher`
        // (a segmented Picker) animates its own selection (see the +Playback extension).
        Group {
            switch tab {
            case .summary: summaryTab
            case .transcript: transcriptTab
            }
        }
        .navigationTitle(session.sessionTitle)
        .navigationSubtitle(session.sessionDate.formatted(date: .abbreviated, time: .shortened))
        .toolbar {
            // Summary/Transcript switcher — trailing, next to the actions menu, so
            // the navigation title keeps its full width (a centered `.principal`
            // item would squeeze it and adds a heavier platter shadow).
            ToolbarItem {
                tabSwitcher
            }
            ToolbarItem {
                Menu {
                    Button {
                        copySessionMarkdown()
                    } label: {
                        Label("Copy as Markdown", systemImage: "doc.on.clipboard")
                    }
                    // Copies the summary too, so a summary-only session (transcript
                    // cleared, or lines still syncing) is still worth copying.
                    .disabled(session.lines.isEmpty && !hasSummaryContent)

                    Button {
                        Task { await exportPDF() }
                    } label: {
                        Label("Export PDF", systemImage: "arrow.down.doc")
                    }
                    .disabled(!hasSummaryContent)

                    Button {
                        Task { await summaryVM.generateSummary(session: session, context: modelContext) }
                    } label: {
                        Label("Re-summarize", systemImage: "sparkles")
                    }
                    // Summary generation is a cloud call — unavailable while offline.
                    .disabled(isOffline || summaryVM.isLoading || session.lines.isEmpty)

                    // Re-transcribe the recording for higher accuracy (offline/cloud).
                    retranscribeMenu

                    // Batch-rename this session's speakers. Disabled for a
                    // non-diarized session (no positive speaker ids to edit).
                    Button {
                        showSpeakerEditor = true
                    } label: {
                        Label("Edit Speakers…", systemImage: "person.2")
                    }
                    .disabled(editableSpeakers.isEmpty)

                    // Assign/clear which workspace this session is filed under.
                    // `SessionExportCoordinator` is the single write path, since
                    // reassigning also moves the exported folder.
                    workspaceMenu

                    // Share-to-web action. Shares (idempotent) then opens the
                    // dialog with link + password. Hidden while offline — it's a
                    // network write.
                    if !isOffline {
                        Divider()
                        Button {
                            if let id = SessionLinkSharer.share(session: session, context: modelContext) {
                                shareTarget = ShareTarget(id: id)
                            }
                        } label: {
                            Label("Share…", systemImage: "square.and.arrow.up")
                        }
                        .disabled(session.lines.isEmpty)
                    }

                    Divider()
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .help("Actions")
            }
        }
        .sheet(item: $shareTarget) { target in
            MacShareSessionSheet(sessionId: target.id)
        }
        .sheet(isPresented: $showSpeakerEditor) {
            MacEditSpeakersSheet(speakers: editableSpeakers) { edits in
                SpeakerRenamer.apply(edits, to: session, context: modelContext)
            }
        }
        // Single-speaker rename from a transcript bubble's right-click menu;
        // routes through the same persist + Firestore-sync path as the batch editor.
        .sheet(item: $renameTarget) { target in
            MacRenameSpeakerSheet(currentName: target.currentName) { newName in
                SpeakerRenamer.apply([target.speakerID: newName], to: session, context: modelContext)
            }
        }
        .confirmationDialog(
            "Delete this transcription?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deleteSession() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
        .task { await autoSummarizeIfNeeded() }
        // Load this session's recording (nil/missing → player stays hidden).
        .task(id: session.persistentModelID) { playback.load(fileName: session.audioFileName) }
        .onDisappear { playback.stop() }
        // Floating player pill docked at the bottom (only when a recording is
        // loaded). The Summary/Transcript switcher is the top toolbar pill.
        .safeAreaInset(edge: .bottom) { bottomBar }
        // Expose "Export PDF…" to the menu bar; nil (menu item disabled) when
        // there's no summary content to export.
        .focusedSceneValue(\.exportSummary, exportAction)
        // Single shared progress banner for whichever background batch pass is running
        // over this session — a file import or a re-transcription. The two
        // are mutually exclusive (import blocks re-transcribe), so one slot renders both.
        // Floats over the top (not a safeAreaInset) so it doesn't push content down.
        .overlay(alignment: .top) { postSessionBanner }
        // Re-transcription confirmation + error alert.
        .modifier(RetranscriptionModifier(
            pendingKind: $pendingRetranscribeKind,
            session: session,
            context: modelContext))
    }

    /// The menu-bar "Export PDF…" action, or nil when there's nothing to
    /// export. Typed explicitly so the ternary doesn't stall type inference
    /// inside the `body` builder.
    private var exportAction: (() -> Void)? {
        guard hasSummaryContent else { return nil }
        return { Task { await exportPDF() } }
    }

    /// Generates the summary on first appear when the session has a transcript
    /// but no summary yet. Runs once per appearance so a failure doesn't loop.
    private func autoSummarizeIfNeeded() async {
        // Never fire the cloud summarizer automatically while offline.
        guard !isOffline,
              !didAutoSummarize,
              !summaryVM.isLoading,
              !session.lines.isEmpty,
              session.summaryParagraphs.isEmpty,
              session.summaryKeyPoints.isEmpty else { return }
        didAutoSummarize = true
        await summaryVM.generateSummary(session: session, context: modelContext)
    }

    /// Deletes this session (audio file + cascade of lines/action items) and pops
    /// back to the list. The recording filename is captured before the delete so
    /// the audio cleanup never reads the model afterward; `save()` commits the
    /// deletion immediately (matching every other write path)
    /// instead of waiting for autosave. SwiftUI coalesces the pop with the delete,
    /// so the popped view is torn down rather than re-rendered against the dead model.
    private func deleteSession() {
        let audioFileName = session.audioFileName
        // The exported markdown folder is external too, so the cascade misses it.
        // Called BEFORE the delete: it reads the folder name and the persistent id
        // off a row that still exists.
        SessionExportCoordinator.remove([session])
        dismiss()
        modelContext.delete(session)
        try? modelContext.save()
        SessionAudioStore.delete(fileName: audioFileName)
    }

    // MARK: - Workspace

    @ViewBuilder
    private var workspaceMenu: some View {
        Menu("Workspace") {
            Button {
                SessionExportCoordinator.reassignWorkspace(session, to: nil, context: modelContext)
            } label: {
                workspaceOptionLabel("None", isSelected: session.workspace == nil)
            }
            ForEach(workspaces) { workspace in
                Button {
                    SessionExportCoordinator.reassignWorkspace(session, to: workspace, context: modelContext)
                } label: {
                    workspaceOptionLabel(workspace.name, isSelected: session.workspace?.persistentModelID == workspace.persistentModelID)
                }
            }
        }
    }

    @ViewBuilder
    private func workspaceOptionLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    /// Copies the whole session — metadata, the AI summary when one exists, then
    /// the full transcript — to the clipboard as GitHub-flavored markdown. Menu
    /// item is disabled only when there's neither a transcript nor a summary.
    private func copySessionMarkdown() {
        let markdown = MarkdownFormatter.formatSession(session: session)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
    }

    private func exportPDF() async {
        await PDFExporter.exportSummary(
            title: session.sessionTitle,
            date: session.sessionDate,
            paragraphs: session.summaryParagraphs,
            keyPoints: session.summaryKeyPoints,
            actionItems: session.actionItems
                .sorted { $0.sortOrder < $1.sortOrder }
                .map(\.text)
        )
    }

    // MARK: - Summary

    @ViewBuilder
    private var summaryTab: some View {
        if summaryVM.isLoading {
            centered { ProgressView("Generating summary…") }
        } else if let error = summaryVM.errorMessage {
            centered {
                ContentUnavailableView("Couldn't Summarize", systemImage: "exclamationmark.triangle", description: Text(error))
            }
        } else if session.summaryParagraphs.isEmpty && session.summaryKeyPoints.isEmpty {
            centered {
                if isOffline {
                    // No on-device summarizer — generation needs the cloud.
                    ContentUnavailableView {
                        Label("Summary Unavailable Offline", systemImage: "wifi.slash")
                    } description: {
                        Text("Summaries need an internet connection. Turn off Offline Mode in Settings to generate one.")
                    }
                } else {
                    ContentUnavailableView {
                        Label("No Summary Yet", systemImage: "sparkles")
                    } description: {
                        Text("Generate an AI summary from this transcript.")
                    } actions: {
                        Button("Summarize") {
                            Task { await summaryVM.generateSummary(session: session, context: modelContext) }
                        }
                        .disabled(session.lines.isEmpty)
                    }
                }
            }
        } else {
            summaryContent
        }
    }

    private var summaryContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !session.summaryParagraphs.isEmpty {
                    section("Overview") {
                        ForEach(Array(session.summaryParagraphs.enumerated()), id: \.offset) { _, para in
                            Text(para).appScaledFont(.body)
                        }
                    }
                }
                if !session.summaryKeyPoints.isEmpty {
                    section("Key Points") {
                        ForEach(Array(session.summaryKeyPoints.enumerated()), id: \.offset) { _, point in
                            Label(point, systemImage: "circle.fill")
                                .labelStyle(BulletLabelStyle())
                        }
                    }
                }
                let items = session.actionItems.sorted { $0.sortOrder < $1.sortOrder }
                if !items.isEmpty {
                    section("Action Items") {
                        ForEach(items) { item in
                            Label(item.text, systemImage: item.isCompleted ? "checkmark.circle.fill" : "circle")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .padding()
        }
    }

    // MARK: - Transcript
    // `transcriptTab` + the audio `playerBar` live in MacSessionDetailView+Playback.

    // MARK: - Helpers

    private func section(_ title: String, @ViewBuilder _ body: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).appScaledFont(.headline)
            body()
        }
    }

    private func centered(@ViewBuilder _ body: () -> some View) -> some View {
        VStack { Spacer(); body(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

//
//  TranscriptionsScreen.swift
//  OpenCaptions
//
//  The "Transcriptions" section: a list of saved sessions with a top-right
//  Record button. Recording replaces the list AS THE NAVIGATION-STACK ROOT
//  (not a push) so there is no system back button to fight — macOS has no
//  `navigationBarBackButtonHidden`, so the recording view owns its own back
//  affordance instead. Session detail is still a normal push. Everything stays
//  inside the (movable) main window.
//

import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct TranscriptionsScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(LiveSessionStore.self) private var store
    @Query private var sessions: [TranscriptionSession]

    @State private var path: [ContentRoute] = []
    /// Presents the audio/video file picker (toolbar button + File-menu command).
    @State private var isImporterPresented = false
    /// Non-nil presents the delete confirmation for exactly this session — set
    /// from the row's right-click context menu so nothing deletes without a
    /// confirmation. The detail view deletes through its own separate flow.
    @State private var pendingDeletion: TranscriptionSession?
    /// Observed so a `pendingStartRequest` set while this screen is already on
    /// screen (a global-hotkey Start whose mic-permission fallback raised an
    /// already-open window) is consumed reactively, not only on first appear.
    @State private var menuBar = MenuBarState.shared

    /// Scopes the session list to the signed-in user. A `@Query`'s default
    /// initializer can't read a runtime value, so the predicate is built here
    /// from the captured uid — rebuilding this view on sign-out→sign-in
    /// re-captures the new uid.
    init(userId: String) {
        _sessions = Query(
            filter: #Predicate<TranscriptionSession> { $0.userId == userId },
            sort: \.sessionDate,
            order: .reverse
        )
    }

    var body: some View {
        NavigationStack(path: $path) {
            rootContent
                .navigationDestination(for: ContentRoute.self) { route in
                    switch route {
                    case .session(let session):
                        MacSessionDetailView(session: session)
                    }
                }
        }
        // Expose "New Recording" (Cmd+N) to the main menu. Nil while already
        // recording so the menu item disables instead of restarting a session.
        .focusedSceneValue(\.startRecording, startRecordingAction)
        // Expose "Import Audio or Video…" (Cmd+I) to the File menu. Nil while the
        // flag is off or a recording is active, so the menu item disables.
        .focusedSceneValue(\.importMedia, importMediaAction)
        // Mirror the same action to the system menu-bar item (a separate scene
        // that can't read focused values). Re-published whenever recording
        // starts/stops, and cleared when the list leaves the hierarchy.
        .onAppear { menuBar.startRecording = startRecordingAction }
        // Consume a pending "New Recording" request — from the menu-bar item while
        // the window was closed, OR a global-hotkey Start whose mic-permission
        // fallback raised an ALREADY-OPEN window. `initial: true` covers the first
        // (onAppear-equivalent) case; the change covers the second, where onAppear
        // never re-fires. Either way the recording/permission screen surfaces and
        // no stale flag lingers to auto-start on a later reopen.
        .onChange(of: menuBar.pendingStartRequest, initial: true) { _, pending in
            guard pending, !store.isActive else { return }
            menuBar.pendingStartRequest = false
            startNewRecording()
        }
        .onChange(of: store.isActive) { _, _ in
            menuBar.startRecording = startRecordingAction
        }
        .onDisappear { menuBar.startRecording = nil }
        // Paywall for a metered recording blocked on an empty balance — set from
        // either the in-window Record action or the headless menu-bar start.
        .sheet(isPresented: paywallPresented) { MacPaywallView() }
    }

    /// Binding to the store's paywall request (the store is an `@Observable`
    /// environment object, so we bridge it into an `isPresented` binding by hand).
    private var paywallPresented: Binding<Bool> {
        Binding(get: { store.pendingPaywall }, set: { store.pendingPaywall = $0 })
    }

    /// The menu-bar "New Recording" action, or nil while a session is active so
    /// the item disables. A guard + explicit closure literal (not a ternary over
    /// a bare method reference) keeps type inference unambiguous.
    private var startRecordingAction: (() -> Void)? {
        guard !store.isActive else { return nil }
        return { startNewRecording() }
    }

    /// Begins a new recording from the list (same action as the Record toolbar
    /// button); shared with the menu-bar command. Creating the session in the
    /// store makes the live screen appear (below) and, crucially, keeps it alive
    /// if the window is later closed.
    private func startNewRecording() {
        // Gate metered (cloud) recordings on the minute balance before creating a
        // session, so a blocked start shows the paywall instead of an empty live
        // screen. Offline Mode is free and always proceeds.
        Task {
            let offline = UserDefaults.standard.bool(forKey: LiveSessionStore.offlineModeKey)
            guard await MacSubscriptionManager.shared.canStartSession(metered: !offline) else {
                store.pendingPaywall = true
                return
            }
            path.removeAll()
            store.makeSession()
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        // Driven by the app-level store, not local state: a window reopened while
        // a session is running re-shows the live screen bound to the SAME running
        // view model instead of the list.
        if let vm = store.viewModel {
            MacLiveTranscriptionView(viewModel: vm, onFinish: handleRecordingFinished)
        } else {
            listContent
                .navigationTitle("Transcriptions")
                .toolbar {
                    if showImport {
                        ToolbarItem(placement: .primaryAction) {
                            Button { isImporterPresented = true } label: {
                                Label("Import", systemImage: "square.and.arrow.down")
                            }
                            .help("Import an audio or video file")
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: startNewRecording) {
                            Label("Record", systemImage: "mic")
                        }
                        .help("Start a new recording")
                    }
                }
                // Audio covers m4a/mp3/wav/aiff/caf; movie covers mp4/mov/etc. — the
                // importer normalizes any of them to the canonical .m4a.
                .fileImporter(
                    isPresented: $isImporterPresented,
                    allowedContentTypes: [.audio, .movie],
                    allowsMultipleSelection: false
                ) { handleImport($0) }
                // Import failures surface here (the list is where import is initiated);
                // in-progress imports show only a per-row spinner (below), and their
                // progress banner lives in the session's own detail view — not the list.
                .alert("Import Failed", isPresented: importErrorPresented) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(FileImportManager.shared.errorMessage ?? "")
                }
        }
    }

    /// Whether the import affordances are enabled (remote flag). Read in `body` so a
    /// remote flip reactively shows/hides the button (FeatureFlagService is @Observable).
    private var showImport: Bool { FeatureFlagService.shared.isEnabled(.fileImport) }

    /// The File-menu import action, or nil while the flag is off / a session is active
    /// (import is refused during a live recording), so the menu item disables.
    private var importMediaAction: (() -> Void)? {
        guard showImport, !store.isActive else { return nil }
        return { isImporterPresented = true }
    }

    /// Hands a picked file to the background importer. `.fileImporter` returns a
    /// security-scoped URL; the manager brackets its access.
    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            FileImportManager.shared.importFile(url, container: modelContext.container)
        case .failure(let error):
            FileImportManager.shared.errorMessage = error.localizedDescription
        }
    }

    /// Presents the import-failure alert while `errorMessage` is set; clears it on ack.
    private var importErrorPresented: Binding<Bool> {
        Binding(
            get: { FileImportManager.shared.errorMessage != nil },
            set: { if !$0 { FileImportManager.shared.errorMessage = nil } }
        )
    }

    @ViewBuilder
    private var listContent: some View {
        if sessions.isEmpty {
            ContentUnavailableView(
                "No Recordings",
                systemImage: "waveform",
                description: Text("Tap Record to start your first transcription.")
            )
        } else {
            List {
                ForEach(sessions) { session in
                    // Single-click opens the session; right-click offers Delete.
                    // With no list selection, `open` assigns the path to a single
                    // detail, so a click can never stack N detail screens.
                    sessionRow(session)
                        .contentShape(Rectangle())
                        .onTapGesture { open(session) }
                        .contextMenu {
                            Button("Delete", role: .destructive) { pendingDeletion = session }
                        }
                }
            }
            .confirmationDialog(
                "Delete this transcription?",
                isPresented: isDeletionPresented,
                titleVisibility: .visible,
                presenting: pendingDeletion
            ) { session in
                Button("Delete", role: .destructive) { performDelete(session) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This can't be undone.")
            }
        }
    }

    private func sessionRow(_ session: TranscriptionSession) -> some View {
        // Prefer the AI short description once the session is summarized; otherwise
        // fall back to the transcript preview.
        let subtitle: String = {
            if let desc = session.shortDescription, !desc.isEmpty { return desc }
            return session.resolvedPreviewText
        }()
        // Live indicator while this session is being re-transcribed OR is the
        // freshly-created target of a running file import. Observes the shared
        // managers' progress, so the row updates when a run starts/finishes.
        let isRetranscribing = RetranscriptionManager.shared.isRunning(session.persistentModelID)
            || FileImportManager.shared.isRunning(session.persistentModelID)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(session.sessionTitle)
                    .appScaledFont(.headline)
                    .lineLimit(1)
                if isRetranscribing {
                    ProgressView().controlSize(.small)
                }
            }
            if !subtitle.isEmpty {
                Text(subtitle)
                    .appScaledFont(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(session.sessionDate, format: .dateTime.month().day().hour().minute())
                .appScaledFont(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    /// Opens exactly one session's detail. Assigns the path (rather than
    /// appending) so the stack can only ever hold a single detail.
    private func open(_ session: TranscriptionSession) {
        path = [.session(session)]
    }

    /// Stop & Save: the live view has already stopped the session and cleared the
    /// store (so the list is showing again); open the saved session detail.
    private func handleRecordingFinished(_ savedID: PersistentIdentifier?) {
        path.removeAll()
        guard let savedID,
              let saved = modelContext.model(for: savedID) as? TranscriptionSession else { return }
        path.append(.session(saved))
    }

    /// Binding that presents the confirmation while `pendingDeletion` is set and
    /// clears it on dismiss (so Cancel and the backdrop both reset the target).
    private var isDeletionPresented: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    private func performDelete(_ session: TranscriptionSession) {
        // Capture the filename up front so the on-disk cleanup never reads a model
        // after it's been deleted.
        let audioFileName = session.audioFileName
        withAnimation {
            modelContext.delete(session)
            // Persist now (every other write path saves explicitly) rather than
            // relying on autosave — the audio file is about to be removed
            // irreversibly, so the row deletion must be committed alongside it.
            try? modelContext.save()
        }
        // Remove the recorded audio only after the delete is committed; the
        // cascade delete only covers the SwiftData relationships (lines/action
        // items), not this external file.
        if let audioFileName { SessionAudioStore.delete(fileName: audioFileName) }
        pendingDeletion = nil
    }
}

/// Destinations pushed onto the transcription screen's navigation stack.
enum ContentRoute: Hashable {
    case session(TranscriptionSession)
}

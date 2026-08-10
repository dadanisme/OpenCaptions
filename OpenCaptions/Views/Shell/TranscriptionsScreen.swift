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
    @Query(sort: \TranscriptionSession.sessionDate, order: .reverse) private var sessions: [TranscriptionSession]
    @Query(sort: \Workspace.name) private var workspaces: [Workspace]

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
    /// Narrows the list to one workspace, sessions with none, or everything.
    @State private var workspaceFilter: WorkspaceFilter = .all
    /// Search bar text. Title/description/summary matches apply instantly
    /// (see `matches`); transcript-line matches come from `searchController`
    /// once its debounced background scan catches up.
    @State private var searchText = ""
    @State private var searchController = TranscriptSearchController()
    /// Below this length a transcript-line scan is skipped: a 1-character
    /// match returns close to every line in the store, which is neither
    /// useful nor cheap. Shorter queries still match title/description/
    /// summary instantly via `matches`.
    private let minLineSearchQueryLength = 2
    /// What `listContent` actually renders — mirrors `filteredSessions`, but
    /// deliberately does NOT recompute on every keystroke. While a line
    /// search is debouncing/in flight, re-deriving from `filteredSessions`
    /// live would drop any line-only match for the OLD query (it can't yet
    /// be confirmed for the new one) and briefly show the empty state before
    /// the fresh results arrive — a list → empty → list flash. Instead this
    /// only updates at well-defined settle points (`refreshDisplayedSessions`),
    /// so the list stays exactly as it was until there's something better to
    /// show it.
    @State private var displayedSessions: [TranscriptionSession] = []

    var body: some View {
        NavigationStack(path: $path) {
            rootContent
                .navigationDestination(for: ContentRoute.self) { route in
                    switch route {
                    case .session(let session):
                        MacSessionDetailView(session: session)
                    case .sessionLine(let session, let lineID):
                        MacSessionDetailView(session: session, scrollToLineID: lineID)
                    }
                }
        }
        // Expose "New Session" (Cmd+N) to the main menu. Nil while already
        // recording so the menu item disables instead of restarting a session.
        .focusedSceneValue(\.startRecording, startRecordingAction)
        // Expose "Import Audio or Video…" (Cmd+I) to the File menu. Nil while a
        // recording is active, so the menu item disables.
        .focusedSceneValue(\.importMedia, importMediaAction)
        // Mirror the same action to the system menu-bar item (a separate scene
        // that can't read focused values). Re-published whenever recording
        // starts/stops, and cleared when the list leaves the hierarchy.
        .onAppear { menuBar.startRecording = startRecordingAction }
        // Consume a pending "New Session" request — from the menu-bar item while
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
        // Seeds `displayedSessions` on first appear and keeps it in step with
        // anything that isn't the (deliberately debounced) line search:
        // session data changing and the workspace filter changing are both
        // instant/synchronous, so there's no flicker risk in recomputing
        // immediately for them.
        .onChange(of: sessions, initial: true) { _, _ in refreshDisplayedSessions() }
        .onChange(of: workspaceFilter) { _, _ in refreshDisplayedSessions() }
        // Safety net for the same root cause as `workspaceMenu`'s explicit
        // refresh: `MacSessionDetailView` has its own workspace-reassignment
        // menu, and that in-place mutation is just as invisible to
        // `.onChange(of: sessions)`. Refreshing whenever the stack returns to
        // the list root covers that path (and any other detail-view mutation
        // that could affect filtering) without threading a callback through
        // the push.
        .onChange(of: path) { _, newPath in
            if newPath.isEmpty { refreshDisplayedSessions() }
        }
    }

    /// The menu-bar "New Session" action, or nil while a session is active so
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
        path.removeAll()
        store.makeSession()
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
                .searchable(text: $searchText, prompt: "Search transcripts")
                .task(id: searchText) { await runLineSearch(for: searchText) }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: startNewRecording) {
                            Label("New Session", systemImage: "mic")
                        }
                        .help("Start a new session")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { isImporterPresented = true } label: {
                            Label("Import", systemImage: "square.and.arrow.down")
                        }
                        .help("Import an audio or video file")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        workspaceFilterMenu
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

    /// The File-menu import action, or nil while a session is active (import is
    /// refused during a live recording), so the menu item disables.
    private var importMediaAction: (() -> Void)? {
        guard !store.isActive else { return nil }
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
                "No Sessions",
                systemImage: "waveform",
                description: Text("Tap New Session to start your first transcription.")
            )
        } else if displayedSessions.isEmpty {
            // Attribute the empty state to whichever filter actually caused it:
            // if the workspace filter alone already leaves nothing, blaming a
            // leftover search query (from before the filter was changed) would
            // point at the wrong cause. `displayedSessions`, not the live
            // `filteredSessions`, is what decides whether we're empty at all —
            // see its doc comment for why.
            if workspaceFilteredSessions.isEmpty {
                ContentUnavailableView(
                    "No Matching Sessions",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("No sessions match this workspace filter.")
                )
            } else {
                ContentUnavailableView.search(text: searchText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        } else {
            List {
                ForEach(displayedSessions) { session in
                    // Single-click opens the session; right-click offers Delete.
                    // With no list selection, `open` assigns the path to a single
                    // detail, so a click can never stack N detail screens.
                    sessionRow(session)
                        .contentShape(Rectangle())
                        .onTapGesture { open(session) }
                        .contextMenu {
                            workspaceMenu(for: session)
                            Divider()
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

    // MARK: - Workspaces

    /// `sessions` narrowed by `workspaceFilter` alone, before `searchText` is
    /// applied — used by `filteredSessions` and (to attribute the empty state
    /// correctly) by `listContent`.
    private var workspaceFilteredSessions: [TranscriptionSession] {
        switch workspaceFilter {
        case .all:
            return sessions
        case .unassigned:
            return sessions.filter { $0.workspace == nil }
        case .workspace(let id):
            return sessions.filter { $0.workspace?.persistentModelID == id }
        }
    }

    /// The sessions currently shown, after `workspaceFilter` and `searchText`
    /// narrow `sessions`. Not read directly by `listContent` — see
    /// `displayedSessions`/`refreshDisplayedSessions`.
    private var filteredSessions: [TranscriptionSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return workspaceFilteredSessions }
        return workspaceFilteredSessions.filter { matches($0, query: query) }
    }

    /// Snapshots `filteredSessions` into `displayedSessions`. Called only at
    /// well-defined settle points (data/filter changes, and a line search
    /// finishing or being skipped) — never on every keystroke — so the list
    /// never briefly collapses to empty mid-debounce.
    private func refreshDisplayedSessions() {
        displayedSessions = filteredSessions
    }

    // MARK: - Search

    /// Whether `session` matches `query` by title, description, or summary
    /// (checked here, in-memory — `sessions` is already fully fetched for the
    /// list either way, so this costs nothing extra), or by transcript text,
    /// once `searchController`'s background scan has caught up to this exact
    /// query. See `TranscriptSearchController`.
    private func matches(_ session: TranscriptionSession, query: String) -> Bool {
        if session.sessionTitle.localizedStandardContains(query) { return true }
        if let description = session.shortDescription, description.localizedStandardContains(query) {
            return true
        }
        if session.summaryParagraphs.contains(where: { $0.localizedStandardContains(query) }) { return true }
        if session.summaryKeyPoints.contains(where: { $0.localizedStandardContains(query) }) { return true }
        return lineMatch(for: session, query: query) != nil
    }

    /// `searchController`'s line match for `session` under `query`, if any
    /// and if the background scan has caught up to this exact query — nil
    /// otherwise (including while a scan for a newer query is still
    /// in-flight, per `TranscriptSearchController.query`'s doc comment).
    private func lineMatch(for session: TranscriptionSession, query: String) -> TranscriptSearchController.LineMatch? {
        guard searchController.query == query else { return nil }
        return searchController.matchingLinesBySessionID[session.persistentModelID]
    }

    /// The line that matched `session` for the current search text, if the
    /// match came from transcript text (rather than title/description/
    /// summary — those have no specific line to jump to). Drives the
    /// `.sessionLine` deep link in `open`.
    private func matchingLineID(for session: TranscriptionSession) -> PersistentIdentifier? {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        return lineMatch(for: session, query: query)?.firstLineID
    }

    /// What to show in a matching row's subtitle in place of the plain
    /// description/preview: an excerpt around wherever `session` actually
    /// matched, plus how many OTHER matches exist beyond the one shown.
    /// Prefers a transcript-line excerpt — most specific — falling back to
    /// summary, then description; nil when `session` matched only by title
    /// (already visible in the row, so there's nothing more useful to show)
    /// or the background scan hasn't caught up yet.
    private func searchResultExcerpt(for session: TranscriptionSession, query: String) -> SearchResultExcerpt? {
        // Summary before description, matching the documented priority
        // (line > summary > description) — `matchingFields.first` below is
        // what actually enforces the order, so this list's order matters.
        var fields: [String] = []
        fields.append(contentsOf: session.summaryParagraphs)
        fields.append(contentsOf: session.summaryKeyPoints)
        if let description = session.shortDescription, !description.isEmpty {
            fields.append(description)
        }
        let matchingFields = fields.filter { $0.localizedStandardContains(query) }
        let line = lineMatch(for: session, query: query)

        if let line, let snippet = SearchSnippet(source: line.firstLineText, query: query) {
            return SearchResultExcerpt(snippet: snippet, extraMatchCount: (line.totalCount - 1) + matchingFields.count)
        }
        if let firstField = matchingFields.first, let snippet = SearchSnippet(source: firstField, query: query) {
            return SearchResultExcerpt(snippet: snippet, extraMatchCount: (matchingFields.count - 1) + (line?.totalCount ?? 0))
        }
        return nil
    }

    /// Renders `excerpt` as one `Text`: the highlighted snippet, plus a
    /// dimmer "+N more matches" suffix when there's more than what's shown.
    /// One concatenated `Text` (not an `HStack` of two) so `.lineLimit(1)`
    /// on the caller truncates the whole thing as a unit instead of leaving
    /// the count badge to wrap onto its own line.
    private func searchExcerptText(_ excerpt: SearchResultExcerpt) -> Text {
        guard excerpt.extraMatchCount > 0 else { return excerpt.snippet.highlighted }
        let suffix = excerpt.extraMatchCount == 1 ? "1 more match" : "\(excerpt.extraMatchCount) more matches"
        return excerpt.snippet.highlighted + Text("  •  +\(suffix)").foregroundStyle(.tertiary)
    }

    /// Debounces `searchText` edits before running the expensive transcript-
    /// line scan — cancelled automatically by `.task(id:)` re-firing on every
    /// keystroke, so only the query the user settles on actually reaches
    /// `searchController`. Refreshes `displayedSessions` at both settle
    /// points (below the length floor needs no scan; at the end of one) —
    /// never mid-debounce, which is what keeps the list from flashing empty
    /// while `searchController` hasn't caught up to `query` yet.
    private func runLineSearch(for text: String) async {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= minLineSearchQueryLength else {
            searchController.reset()
            refreshDisplayedSessions()
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        await searchController.search(query, container: modelContext.container)
        guard !Task.isCancelled else { return }
        refreshDisplayedSessions()
    }

    private var workspaceFilterMenu: some View {
        Menu {
            Button {
                workspaceFilter = .all
            } label: {
                filterLabel("All Workspaces", isSelected: workspaceFilter == .all)
            }
            Button {
                workspaceFilter = .unassigned
            } label: {
                filterLabel("Unassigned", isSelected: workspaceFilter == .unassigned)
            }
            if !workspaces.isEmpty {
                Divider()
                ForEach(workspaces) { workspace in
                    Button {
                        workspaceFilter = .workspace(workspace.persistentModelID)
                    } label: {
                        filterLabel(workspace.name, isSelected: workspaceFilter == .workspace(workspace.persistentModelID))
                    }
                }
            }
        } label: {
            Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
        }
        .help("Filter by workspace")
    }

    /// The row's right-click "Workspace" submenu — assigns or clears which
    /// workspace this session is filed under. `SessionExportCoordinator` is the
    /// single write path, since reassigning also moves the exported folder.
    /// Explicitly refreshes `displayedSessions` after: this mutates
    /// `session.workspace` in place on an object `sessions` already holds,
    /// which changes neither that array's count/order nor (SwiftData's
    /// `@Model` equality being identity-based) its `==` result — so
    /// `.onChange(of: sessions)` never fires on its own, and under an active
    /// workspace filter the row would otherwise linger long after it no
    /// longer belongs.
    @ViewBuilder
    private func workspaceMenu(for session: TranscriptionSession) -> some View {
        Menu("Workspace") {
            Button {
                SessionExportCoordinator.reassignWorkspace(session, to: nil, context: modelContext)
                refreshDisplayedSessions()
            } label: {
                filterLabel("None", isSelected: session.workspace == nil)
            }
            ForEach(workspaces) { workspace in
                Button {
                    SessionExportCoordinator.reassignWorkspace(session, to: workspace, context: modelContext)
                    refreshDisplayedSessions()
                } label: {
                    filterLabel(workspace.name, isSelected: session.workspace?.persistentModelID == workspace.persistentModelID)
                }
            }
        }
    }

    @ViewBuilder
    private func filterLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func sessionRow(_ session: TranscriptionSession) -> some View {
        // Prefer the AI short description once the session is summarized; otherwise
        // fall back to the transcript preview.
        let subtitle: String = {
            if let desc = session.shortDescription, !desc.isEmpty { return desc }
            return session.resolvedPreviewText
        }()
        // While a search is active, show an excerpt of wherever this session
        // actually matched instead of the plain subtitle above — nil (and
        // the plain subtitle stays) for a title-only match, or while
        // `searchController`'s scan hasn't caught up yet.
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let excerpt = query.isEmpty ? nil : searchResultExcerpt(for: session, query: query)
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
            if let excerpt {
                searchExcerptText(excerpt)
                    .appScaledFont(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if !subtitle.isEmpty {
                Text(subtitle)
                    .appScaledFont(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 4) {
                Text(session.sessionDate, format: .dateTime.month().day().hour().minute())
                    .appScaledFont(.caption)
                SessionWorkspaceLabel(session: session)
                SessionSpeakersLine(session: session)
            }
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    /// Opens exactly one session's detail. Assigns the path (rather than
    /// appending) so the stack can only ever hold a single detail. Deep-links
    /// to the matching line when the current search hit came from transcript
    /// text; otherwise opens on the Summary tab as usual.
    private func open(_ session: TranscriptionSession) {
        if let lineID = matchingLineID(for: session) {
            path = [.sessionLine(session, lineID)]
        } else {
            path = [.session(session)]
        }
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
        // Same story for the exported markdown folder — external to SwiftData, so
        // the cascade misses it. Must run before the delete: it reads the folder
        // name and the persistent id off a row that still exists.
        SessionExportCoordinator.remove([session])
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
    /// Same destination as `.session`, but additionally seeks playback to,
    /// scrolls to, and highlights one specific line — used when a
    /// Transcriptions search hit matched transcript text rather than title,
    /// description, or summary. See `MacSessionDetailView.scrollToLineID`.
    case sessionLine(TranscriptionSession, PersistentIdentifier)
}

/// How the Transcriptions list is narrowed by workspace. Identifies a workspace
/// by `PersistentIdentifier` rather than holding the `Workspace` itself, since
/// `Workspace` has no `Equatable` conformance to compare `@State` against.
private enum WorkspaceFilter: Hashable {
    case all
    case unassigned
    case workspace(PersistentIdentifier)
}

/// A matching row's subtitle content — see
/// `TranscriptionsScreen.searchResultExcerpt(for:query:)`.
private struct SearchResultExcerpt {
    let snippet: SearchSnippet
    let extraMatchCount: Int
}

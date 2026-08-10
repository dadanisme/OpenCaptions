//
//  ActionItemsScreen.swift
//  OpenCaptions
//
//  The "Action Items" sidebar section: a READ-ONLY rollup of every action item
//  across all sessions, grouped by source session. The only mutation is
//  toggling completion; a row / header tap pushes the source session detail
//  (reusing the same `ContentRoute` + `MacSessionDetailView` as the
//  Transcriptions screen).
//

import SwiftData
import SwiftUI

struct ActionItemsScreen: View {
    @Environment(\.modelContext) private var modelContext
    /// All sessions, newest first.
    @Query(sort: \TranscriptionSession.sessionDate, order: .reverse) private var sessions: [TranscriptionSession]
    @State private var path: [ContentRoute] = []

    /// Only sessions that actually produced action items. Sessions stay in
    /// newest-first order; items within each are sorted by their summary order.
    private var sessionsWithItems: [TranscriptionSession] {
        sessions.filter { !$0.actionItems.isEmpty }
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Action Items")
                .navigationDestination(for: ContentRoute.self) { route in
                    switch route {
                    case .session(let session):
                        MacSessionDetailView(session: session)
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if sessionsWithItems.isEmpty {
            ContentUnavailableView(
                "No Action Items",
                systemImage: "checklist",
                description: Text("Action items from your session summaries will appear here.")
            )
        } else {
            List {
                // Headerless `Section` per session: it keeps the group spacing but
                // renders the title as a plain scrolling row (not a `header:`, which
                // macOS pins to the top).
                ForEach(sessionsWithItems) { session in
                    Section {
                        SessionHeaderRow(session: session, onOpen: { open(session) })
                        ForEach(sortedItems(of: session)) { item in
                            ActionItemRow(item: item, onToggle: { toggle(item) })
                        }
                    }
                }
            }
        }
    }

    private func sortedItems(of session: TranscriptionSession) -> [ActionItem] {
        session.actionItems.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Toggles completion and persists immediately — the only write this view
    /// performs. Explicit `save()` matches every other OpenCaptions write path rather
    /// than relying on autosave.
    private func toggle(_ item: ActionItem) {
        item.isCompleted.toggle()
        try? modelContext.save()
        // Completion state is part of the exported `summary.md` (GFM task-list
        // items carry `[x]`), so the file has to be rewritten to stay in step.
        if let session = item.session {
            SessionExportCoordinator.export(session, context: modelContext)
        }
    }

    /// Opens exactly one session's detail. Assigns the path (rather than
    /// appending) so the stack can only ever hold a single detail.
    private func open(_ session: TranscriptionSession) {
        path = [.session(session)]
    }
}

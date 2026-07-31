//
//  ActionItemsScreen.swift
//  OpenCaptions
//
//  The "Action Items" sidebar section: a READ-ONLY rollup of every action item
//  across the signed-in user's sessions, grouped by source session. The only
//  mutation is toggling completion; a row / header tap pushes the source session
//  detail (reusing the same `ContentRoute` + `MacSessionDetailView` as the
//  Transcriptions screen). Scoping mirrors `TranscriptionsScreen(userId:)`.
//

import SwiftData
import SwiftUI

struct ActionItemsScreen: View {
    @Environment(\.modelContext) private var modelContext
    /// User-scoped sessions, newest first. The `@Query` predicate is built from
    /// the captured uid (a default initializer can't read a runtime value), so a
    /// sign-out→sign-in rebuild re-captures the new uid — same pattern as the
    /// Transcriptions list.
    @Query private var sessions: [TranscriptionSession]
    @State private var path: [ContentRoute] = []

    init(userId: String) {
        _sessions = Query(
            filter: #Predicate<TranscriptionSession> { $0.userId == userId },
            sort: \.sessionDate,
            order: .reverse
        )
    }

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
                        sessionHeader(session)
                        ForEach(sortedItems(of: session)) { item in
                            ActionItemRow(item: item, onToggle: { toggle(item) })
                        }
                    }
                }
            }
        }
    }

    /// Session grouping row — the first row of each section, tappable to open the
    /// source session (mirroring a row tap). Rendered as a plain row rather than a
    /// pinned `Section` header, styled to read like the Transcriptions list.
    private func sessionHeader(_ session: TranscriptionSession) -> some View {
        Button {
            open(session)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.sessionTitle)
                        .appScaledFont(.headline)
                        .lineLimit(1)
                    Text(session.sessionDate, format: .dateTime.month().day().hour().minute())
                        .appScaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .appScaledFont(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
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

//
//  KeyPointsScreen.swift
//  OpenCaptions
//
//  The "Key Points" sidebar section: a READ-ONLY rollup of every key point across
//  all sessions, grouped by source session. Key points are plain `[String]`
//  with no completion state, so — unlike Action Items — there is no mutation
//  here; a row / header tap pushes the source session detail (reusing the
//  same `ContentRoute` + `MacSessionDetailView`).
//

import SwiftData
import SwiftUI

struct KeyPointsScreen: View {
    /// All sessions, newest first.
    @Query(sort: \TranscriptionSession.sessionDate, order: .reverse) private var sessions: [TranscriptionSession]
    @Query(sort: \Workspace.name) private var workspaces: [Workspace]
    @State private var path: [ContentRoute] = []
    /// Narrows the rollup to one workspace, sessions with none, or everything.
    @State private var workspaceFilter: WorkspaceFilter = .all

    /// Only sessions that actually produced key points. Sessions stay in
    /// newest-first order; key points within each keep their summary order.
    private var sessionsWithKeyPoints: [TranscriptionSession] {
        sessions.filter { !$0.summaryKeyPoints.isEmpty }
    }

    /// `sessionsWithKeyPoints` further narrowed by `workspaceFilter` — what
    /// `content` actually renders. Kept separate from `sessionsWithKeyPoints`
    /// so the empty state can distinguish "no key points at all" from "the
    /// workspace filter excludes every session that has some".
    private var filteredSessionsWithKeyPoints: [TranscriptionSession] {
        sessionsWithKeyPoints.filter { workspaceFilter.matches($0.workspace) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Key Points")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        WorkspaceFilterMenu(filter: $workspaceFilter, workspaces: workspaces)
                    }
                }
                .navigationDestination(for: ContentRoute.self) { route in
                    switch route {
                    case .session(let session):
                        MacSessionDetailView(session: session)
                    case .sessionLine(let session, let lineID):
                        MacSessionDetailView(session: session, scrollToLineID: lineID)
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if sessionsWithKeyPoints.isEmpty {
            ContentUnavailableView(
                "No Key Points",
                systemImage: "lightbulb",
                description: Text("Key points from your session summaries will appear here.")
            )
        } else if filteredSessionsWithKeyPoints.isEmpty {
            ContentUnavailableView(
                "No Matching Sessions",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("No sessions match this workspace filter.")
            )
        } else {
            List {
                // Headerless `Section` per session: it keeps the group spacing but
                // renders the title as a plain scrolling row (not a `header:`, which
                // macOS pins to the top).
                ForEach(filteredSessionsWithKeyPoints) { session in
                    Section {
                        SessionHeaderRow(session: session, onOpen: { open(session) })
                        // Key points are plain strings with no stable identity, so
                        // key on the array offset (matches the detail-view summary).
                        ForEach(Array(session.summaryKeyPoints.enumerated()), id: \.offset) { _, point in
                            KeyPointRow(text: point)
                        }
                    }
                }
            }
        }
    }

    /// Opens exactly one session's detail. Assigns the path (rather than
    /// appending) so the stack can only ever hold a single detail.
    private func open(_ session: TranscriptionSession) {
        path = [.session(session)]
    }
}

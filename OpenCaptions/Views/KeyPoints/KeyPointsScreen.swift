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
    @State private var path: [ContentRoute] = []

    /// Only sessions that actually produced key points. Sessions stay in
    /// newest-first order; key points within each keep their summary order.
    private var sessionsWithKeyPoints: [TranscriptionSession] {
        sessions.filter { !$0.summaryKeyPoints.isEmpty }
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Key Points")
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
        } else {
            List {
                // Headerless `Section` per session: it keeps the group spacing but
                // renders the title as a plain scrolling row (not a `header:`, which
                // macOS pins to the top).
                ForEach(sessionsWithKeyPoints) { session in
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

//
//  TranscriptSearchController.swift
//  OpenCaptions
//
//  Backs the Transcriptions search field. Title/description/summary matches
//  are checked in-memory by the caller against the already-fetched session
//  list, since that costs nothing beyond what the list view loads anyway.
//  Transcript-line text is the expensive part: searching it means scanning
//  every `TranscriptionLine` across every session, so that half lives here,
//  as a `#Predicate`-pushed query the store executes itself (a SQL scan, not
//  a Swift-side fault of every session's `lines`), off the main actor.
//  See docs/2026-08-10-macos-transcriptions-search.md.
//

import Foundation
import Observation
import SwiftData

@Observable
@MainActor
final class TranscriptSearchController {
    /// A session's transcript-line matches for one query: the earliest (by
    /// `startMs`) matching line's id and text — for deep-linking and the
    /// list row's excerpt — plus how many lines matched in total, for a
    /// "+N more matches" affordance.
    struct LineMatch {
        let firstLineID: PersistentIdentifier
        let firstLineText: String
        let totalCount: Int
    }

    /// The query these results answer, or nil before the first completed
    /// search. Callers must compare this against their current (trimmed)
    /// search text before trusting `matchingLinesBySessionID` — otherwise a
    /// slow in-flight search for a stale query could resolve after the text
    /// has already moved on.
    private(set) var query: String?
    /// Each matching session's id mapped to its `LineMatch`. Used both to
    /// know a session matched by transcript text at all (rather than only
    /// title/description/summary) and to deep-link/excerpt a search hit —
    /// see `TranscriptionsScreen.matches`/`matchingLineID(for:)`/
    /// `searchResultExcerpt(for:query:)`.
    private(set) var matchingLinesBySessionID: [PersistentIdentifier: LineMatch] = [:]

    /// Drops any results, e.g. once the query is too short to be worth
    /// scanning transcript text for (see the caller's length gate).
    func reset() {
        query = nil
        matchingLinesBySessionID = [:]
    }

    /// Runs a transcript-line search for `query` and publishes the result.
    /// Cancel-safe: if the calling task is cancelled (the user kept typing)
    /// before the fetch returns, the stale result is dropped instead of
    /// overwriting one for a newer query.
    func search(_ query: String, container: ModelContainer) async {
        let matches = await Self.fetchLineMatches(query: query, container: container)
        guard !Task.isCancelled else { return }
        self.query = query
        matchingLinesBySessionID = matches
    }

    /// Off-actor: `FetchDescriptor` execution is synchronous I/O, so this runs
    /// on a detached task against its own `ModelContext` — never the main
    /// context — mirroring `DerivedFieldsBackfill`'s background-scan pattern.
    /// The predicate is pushed to the store as a SQL scan; only matching
    /// lines are faulted in, so this never loads every session's `lines`.
    private static func fetchLineMatches(
        query: String, container: ModelContainer
    ) async -> [PersistentIdentifier: LineMatch] {
        await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            var descriptor = FetchDescriptor<TranscriptionLine>(
                predicate: #Predicate { $0.text.localizedStandardContains(query) }
            )
            // Ascending by start time, so the first line kept per session
            // below is the session's EARLIEST match, not an arbitrary one.
            descriptor.sortBy = [SortDescriptor(\.startMs)]
            guard let lines = try? context.fetch(descriptor) else { return [:] }
            var result: [PersistentIdentifier: LineMatch] = [:]
            for line in lines {
                guard let sessionID = line.session?.persistentModelID else { continue }
                if let existing = result[sessionID] {
                    result[sessionID] = LineMatch(
                        firstLineID: existing.firstLineID,
                        firstLineText: existing.firstLineText,
                        totalCount: existing.totalCount + 1
                    )
                } else {
                    result[sessionID] = LineMatch(
                        firstLineID: line.persistentModelID, firstLineText: line.text, totalCount: 1
                    )
                }
            }
            return result
        }.value
    }
}

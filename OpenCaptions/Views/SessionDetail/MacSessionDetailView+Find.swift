//
//  MacSessionDetailView+Find.swift
//  OpenCaptions
//
//  "Find in transcript": an in-session find with next/prev match navigation.
//  The text field itself is the SAME native `.searchable` toolbar field
//  `TranscriptionsScreen` uses for its cross-session search (wired in
//  `+Playback.swift`, scoped to the Transcript tab) — not a custom bar — so
//  it costs no extra vertical space and looks like every other search field
//  in the app. This file owns match computation and the small "X of Y" +
//  prev/next control that rides alongside it in the toolbar. Matching is a
//  synchronous, in-memory filter over the already-loaded `session.lines` —
//  unlike `TranscriptSearchController` (which scans every session off the
//  main actor), there's nothing here expensive enough to need async/debounce.
//

import SwiftData
import SwiftUI

extension MacSessionDetailView {
    // MARK: - Matching

    /// Trimmed, case/diacritic-insensitive matches within `sortedLines`, in
    /// transcript order. Recomputed on every access — no caching, matching
    /// `sortedLines`' existing convention; cheap for one session's
    /// already-in-memory lines. Uses the same `localizedStandardContains`
    /// semantics as `TranscriptSearchController`'s cross-session `#Predicate`,
    /// so a hit here agrees with what already qualified as a match there.
    var matchingLineIDs: [PersistentIdentifier] {
        let query = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return sortedLines
            .filter { $0.text.localizedStandardContains(query) }
            .map(\.persistentModelID)
    }

    /// The line the find bar is centered on, clamped defensively against
    /// `matchingLineIDs` — re-transcription can mutate `session.lines` while
    /// the bar is open, making a stale `currentMatchIndex` a real case, not
    /// just theoretical.
    var currentMatchLineID: PersistentIdentifier? {
        guard matchingLineIDs.indices.contains(currentMatchIndex) else { return nil }
        return matchingLineIDs[currentMatchIndex]
    }

    /// Steps to the next (`delta = 1`) / previous (`delta = -1`) match,
    /// wrapping around. No-ops when there are no matches — guards the `% 0`
    /// crash a naive version would hit, and uses the double-`%` form because
    /// Swift's `%` is remainder, not modulo (a plain `% count` on a negative
    /// step returns a negative index, not a wrapped one).
    func stepMatch(by delta: Int) {
        let count = matchingLineIDs.count
        guard count > 0 else { return }
        currentMatchIndex = ((currentMatchIndex + delta) % count + count) % count
    }

    /// Menu-bar wiring: nil (item disabled) unless the Transcript tab is frontmost.
    /// Setting `isFindBarVisible` is all this needs to do — it's the same
    /// binding `.searchable(isPresented:)` reads in `+Playback.swift`, which
    /// handles revealing + focusing the native field itself.
    var findInTranscriptAction: (() -> Void)? {
        guard tab == .transcript else { return nil }
        return { isFindBarVisible = true }
    }

    // MARK: - Match count + prev/next

    /// The "X of Y" count plus prev/next chevrons — rides in the toolbar
    /// alongside the native search field (which supplies the text field
    /// itself), shown only while a find is actually in progress.
    @ViewBuilder
    var findNavControls: some View {
        if isFindBarVisible && tab == .transcript {
            HStack(spacing: 4) {
                findCountLabel
                Button { stepMatch(by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(matchingLineIDs.isEmpty)
                    .help("Previous match")
                Button { stepMatch(by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(matchingLineIDs.isEmpty)
                    .help("Next match")
            }
            // Toolbar items don't get automatic spacing from their neighbors
            // the way the system-provided ones do — without this the count
            // sits flush against the actions-menu button to its left. Only
            // once matches actually exist ("X of Y" showing): with an empty
            // query or "No matches", the padding would just leave a gap in
            // front of two idle, disabled chevrons.
            .padding(.leading, matchingLineIDs.isEmpty ? 0 : 8)
        }
    }

    @ViewBuilder
    private var findCountLabel: some View {
        let query = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            Text(matchingLineIDs.isEmpty ? "No matches" : "\(currentMatchIndex + 1) of \(matchingLineIDs.count)")
                .appScaledFont(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

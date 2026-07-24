//
//  HighlightedMessageText+Caching.swift
//  OpenCaptions
//
//  Sentence-boundary scanner, name matcher, and segment cache backing
//  `HighlightedMessageText`: question
//  highlighting (background tint) plus name-mention highlighting (bold `@Name`).
//  Split out to keep each file under the 250-line limit.
//

import SwiftUI

// MARK: - Parsing & Caching

extension HighlightedMessageText {
    /// Builds the attributed string. Question runs get a background tint; a name
    /// mention becomes a bold `@Name`. Font and foreground are otherwise left unset
    /// so the surrounding view's modifiers apply — keeping highlighted and plain
    /// runs identical apart from the tint / bold.
    func buildAttributedString(from segments: [TextSegment]) -> AttributedString {
        var result = AttributedString()
        for segment in segments {
            switch segment.type {
            case .nameHighlight:
                // A name mention → bold "@Name" so it reads like an @-mention. Using
                // `inlinePresentationIntent` bolds RELATIVE to the inherited font, so
                // the transcript's size multiplier (applied by the caller's `.font`)
                // is preserved — an explicit bold `.font` here would override it.
                var piece = AttributedString("@" + segment.text)
                piece.inlinePresentationIntent = .stronglyEmphasized
                result.append(piece)

            case .questionHighlight:
                var piece = AttributedString(segment.text)
                piece.backgroundColor = Color.DS.questionHighlight
                result.append(piece)

            case .normal:
                result.append(AttributedString(segment.text))
            }
        }
        return result
    }

    func parseMessage() -> [TextSegment] {
        // Key on the name too: name detection depends on the current user, so two
        // users on a shared Mac must not read each other's cached segments.
        let cacheKey = "\(message)|\(userName ?? "")"

        if shouldCache, let cached = Self.segmentCache[cacheKey] {
            return cached
        }

        let questionRanges = findQuestionRanges(in: message)
        // Name matching runs only on committed (cached) lines. The streaming partial
        // (`cached: false`) is revised token-by-token and can momentarily end
        // mid-word, so a name that is a prefix of the word being spoken ("Mark" in
        // "Marketing") would flash a false bold "@Name" until the word completes.
        // Committed lines are stable, and the partial re-highlights correctly the
        // instant it commits.
        let nameRanges = shouldCache ? findNameRanges(in: message, userName: userName ?? "") : []
        let segments = buildSegments(
            text: message, questionRanges: questionRanges, nameRanges: nameRanges
        )

        // The streaming partial line parses fresh but never enters the cache (see
        // `shouldCache`), so its per-token permutations can't evict committed lines.
        guard shouldCache else { return segments }

        // Evict oldest entries if cache is full.
        if Self.segmentCache.count >= Self.maxCacheSize {
            let keysToRemove = Array(Self.segmentCache.keys.prefix(Self.maxCacheSize / 2))
            for key in keysToRemove {
                Self.segmentCache.removeValue(forKey: key)
            }
        }

        Self.segmentCache[cacheKey] = segments
        return segments
    }

    /// Scans for sentence boundaries (`.`, `!`, `?`), skips decimals like `7.6`,
    /// tracks quotation boundaries, and returns the range of every sentence ending
    /// in `?` (extending to a wrapping closing quote).
    private func findQuestionRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var sentenceStart = text.startIndex
        var quoteStart: String.Index?
        var i = text.startIndex

        while i < text.endIndex {
            let ch = text[i]

            // Track quote boundaries.
            if Self.quoteChars.contains(ch) {
                if quoteStart == nil {
                    quoteStart = i
                } else {
                    quoteStart = nil
                }
            }

            // Don't treat . as sentence end if between digits (e.g. 7.6).
            if ch == "." && i > text.startIndex {
                let prev = text.index(before: i)
                let next = text.index(after: i)
                if next < text.endIndex
                    && text[prev].isNumber && text[next].isNumber {
                    i = text.index(after: i)
                    continue
                }
            }

            let isTerminator = ch == "." || ch == "!" || ch == "?"

            if isTerminator {
                let sentenceEnd = text.index(after: i)
                if ch == "?" {
                    // Inside quotes → highlight from the quote start; otherwise from
                    // the sentence start.
                    let highlightStart = quoteStart ?? sentenceStart

                    // Trim leading whitespace.
                    var trimmedStart = highlightStart
                    while trimmedStart < i && text[trimmedStart].isWhitespace {
                        trimmedStart = text.index(after: trimmedStart)
                    }

                    // Include the closing quote if the next char is one.
                    var highlightEnd = sentenceEnd
                    if highlightEnd < text.endIndex && Self.quoteChars.contains(text[highlightEnd]) {
                        highlightEnd = text.index(after: highlightEnd)
                    }

                    ranges.append(trimmedStart..<highlightEnd)
                }

                // Reset sentence start (but not while inside quotes).
                if quoteStart == nil {
                    sentenceStart = sentenceEnd
                    if sentenceStart < text.endIndex && text[sentenceStart] == " " {
                        sentenceStart = text.index(after: sentenceStart)
                    }
                }
            }

            i = text.index(after: i)
        }

        return ranges
    }

    /// Whole-word, case-insensitive ranges of the user's name. Empty name → no
    /// ranges (a blank name must never match everything). Compiles the `\bname\b`
    /// regex once via `NameMentionMatcher` and caches it per name.
    private func findNameRanges(in text: String, userName: String) -> [Range<String.Index>] {
        let key = userName.lowercased().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return [] }

        let regex: NSRegularExpression
        if let cached = Self.regexCache[key] {
            regex = cached
        } else if let compiled = NameMentionMatcher.regex(for: userName) {
            Self.regexCache[key] = compiled
            regex = compiled
        } else {
            return []
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: nsRange)
            .compactMap { Range($0.range, in: text) }
    }

    /// Interleaves normal, question, and name spans. Ranges are walked as sorted
    /// start/end points with per-type depth counters; where the two overlap, the
    /// name wins (a bold `@Name` reads clearer than a tint). Uses depth counters
    /// rather than booleans so nested same-type ranges
    /// keep their highlight (see the counter comment below).
    private func buildSegments(
        text: String,
        questionRanges: [Range<String.Index>],
        nameRanges: [Range<String.Index>]
    ) -> [TextSegment] {
        guard !questionRanges.isEmpty || !nameRanges.isEmpty else {
            return [TextSegment(text: text, type: .normal)]
        }

        struct HighlightPoint: Comparable {
            let index: String.Index
            let type: SegmentType
            let isStart: Bool
            static func < (lhs: HighlightPoint, rhs: HighlightPoint) -> Bool {
                lhs.index < rhs.index
            }
        }

        var points: [HighlightPoint] = []
        for r in questionRanges {
            points.append(HighlightPoint(index: r.lowerBound, type: .questionHighlight, isStart: true))
            points.append(HighlightPoint(index: r.upperBound, type: .questionHighlight, isStart: false))
        }
        for r in nameRanges {
            points.append(HighlightPoint(index: r.lowerBound, type: .nameHighlight, isStart: true))
            points.append(HighlightPoint(index: r.upperBound, type: .nameHighlight, isStart: false))
        }
        points.sort()

        var segments: [TextSegment] = []
        var currentIndex = text.startIndex
        // Depth counters, not booleans: question ranges can NEST (two `?` inside one
        // quoted span share a start), and a plain bool would flip off at the first
        // range's end while the outer range is still open, dropping the tint on the
        // tail. Counters stay > 0 until every open range of that type closes. Also
        // robust to same-index start/end ordering: no chunk is emitted at a shared
        // index, so only the net depth after both points matters. (macOS's earlier
        // code pre-merged same-type ranges to avoid this; counters subsume that and
        // also carry the name layer.)
        var questionDepth = 0
        var nameDepth = 0

        for point in points {
            if currentIndex < point.index {
                let chunk = String(text[currentIndex..<point.index])
                // Name wins over question wherever the two overlap.
                let type: SegmentType = nameDepth > 0
                    ? .nameHighlight
                    : (questionDepth > 0 ? .questionHighlight : .normal)
                segments.append(TextSegment(text: chunk, type: type))
            }
            currentIndex = point.index

            let delta = point.isStart ? 1 : -1
            if point.type == .questionHighlight { questionDepth += delta }
            if point.type == .nameHighlight { nameDepth += delta }
        }

        if currentIndex < text.endIndex {
            segments.append(TextSegment(text: String(text[currentIndex...]), type: .normal))
        }

        return segments.isEmpty ? [TextSegment(text: text, type: .normal)] : segments
    }

    enum SegmentType {
        case normal
        case nameHighlight
        case questionHighlight
    }

    struct TextSegment {
        let text: String
        let type: SegmentType
    }
}

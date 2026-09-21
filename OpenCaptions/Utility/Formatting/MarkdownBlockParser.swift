//
//  MarkdownBlockParser.swift
//  OpenCaptions
//
//  Block-level Markdown parsing for the Chat tab's assistant replies.
//  `LocalizedStringKey`'s built-in Markdown support only covers INLINE styling
//  (bold, italic, inline code, links) — headings, fenced code blocks, and list
//  markers render as raw syntax. This parser splits a message into a flat
//  sequence of block-level elements; `MarkdownMessageView` renders each block,
//  still delegating inline styling to `LocalizedStringKey` within a block.
//
//  Deliberately minimal: no nested lists, no blockquotes, no tables — just
//  enough structure to cover what a chat model actually emits in an answer
//  (headings, bullet/numbered lists, fenced code, paragraphs).
//

import Foundation

// MARK: - Block model

enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case codeBlock(language: String?, code: String)
    case listItem(text: String, indentLevel: Int, ordered: Bool, number: Int?)
}

// MARK: - Parser

enum MarkdownBlockParser {
    /// Parses a full message string into an ordered list of block-level
    /// elements. Lines are classified in priority order (fence > heading >
    /// list item > blank > paragraph text); consecutive paragraph lines are
    /// joined into a single `.paragraph` block.
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraphBuffer: [String] = []

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            blocks.append(.paragraph(paragraphBuffer.joined(separator: "\n")))
            paragraphBuffer = []
        }

        var index = 0
        // Tracks the leading-space count of each active ancestor list level,
        // so a sub-item's nesting depth is resolved from the indentation
        // structure actually seen so far rather than a fixed spaces-per-level
        // assumption (see `resolveIndentLevel`).
        var listIndentStack: [Int] = []
        while index < lines.count {
            let line = lines[index]

            if isFenceLine(line) {
                flushParagraph()
                listIndentStack.removeAll()
                let language = fenceLanguage(line)
                index += 1
                var codeLines: [String] = []
                while index < lines.count, !isFenceLine(lines[index]) {
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 } // skip closing fence, if present
                blocks.append(.codeBlock(language: language, code: codeLines.joined(separator: "\n")))
                continue
            }

            if let heading = matchHeading(line) {
                flushParagraph()
                listIndentStack.removeAll()
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if let item = matchListItem(line) {
                flushParagraph()
                let indentLevel = resolveIndentLevel(leadingSpaces: item.leadingSpaces, stack: &listIndentStack)
                blocks.append(
                    .listItem(text: item.text, indentLevel: indentLevel, ordered: item.ordered, number: item.number)
                )
                index += 1
                continue
            }

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                listIndentStack.removeAll()
                index += 1
                continue
            }

            paragraphBuffer.append(line)
            index += 1
        }

        flushParagraph()
        return blocks
    }

    // MARK: - Line classifiers

    private static func isFenceLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
    }

    /// The language named on an opening fence line, trimmed — `nil` when the
    /// fence carries no language text.
    private static func fenceLanguage(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let afterFence = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
        return afterFence.isEmpty ? nil : afterFence
    }

    /// Matches 1-6 leading "#" characters followed by a space and non-empty text.
    private static func matchHeading(_ line: String) -> (level: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var hashCount = 0
        for character in trimmed {
            if character == "#" { hashCount += 1 } else { break }
        }
        guard hashCount >= 1, hashCount <= 6 else { return nil }

        let afterHashes = trimmed.dropFirst(hashCount)
        guard afterHashes.first == " " else { return nil }

        let text = afterHashes.dropFirst().trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        return (level: hashCount, text: text)
    }

    /// Matches an unordered ("- "/"* "/"+ ") or ordered ("1. ") list marker on
    /// the RAW line, returning its raw leading-space count for `resolveIndentLevel`
    /// to turn into an actual nesting depth.
    private static func matchListItem(_ line: String) -> (text: String, leadingSpaces: Int, ordered: Bool, number: Int?)? {
        var leadingSpaces = 0
        for character in line {
            if character == " " { leadingSpaces += 1 } else { break }
        }
        let remainder = String(line.dropFirst(leadingSpaces))

        for marker in ["- ", "* ", "+ "] {
            if remainder.hasPrefix(marker) {
                let text = remainder.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return nil }
                return (text: text, leadingSpaces: leadingSpaces, ordered: false, number: nil)
            }
        }

        var digitCount = 0
        for character in remainder {
            if character.isASCII, character.isNumber { digitCount += 1 } else { break }
        }
        guard digitCount > 0 else { return nil }

        let afterDigits = remainder.dropFirst(digitCount)
        guard afterDigits.hasPrefix(". ") else { return nil }

        let text = afterDigits.dropFirst(2).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        let number = Int(remainder.prefix(digitCount))
        return (text: text, leadingSpaces: leadingSpaces, ordered: true, number: number)
    }

    /// Resolves a list item's nesting depth from its raw leading-space count
    /// against the indentation of currently-active ancestor levels, rather
    /// than assuming a fixed number of spaces per level (which breaks for
    /// wide markers like multi-digit ordinals, or a 4-space nesting
    /// convention): pop any ancestor levels indented deeper than this line,
    /// reuse the level if its indentation matches exactly, otherwise this is
    /// a new, deeper level.
    private static func resolveIndentLevel(leadingSpaces: Int, stack: inout [Int]) -> Int {
        while let deepest = stack.last, leadingSpaces < deepest {
            stack.removeLast()
        }
        if let matching = stack.last, leadingSpaces == matching {
            return stack.count - 1
        }
        stack.append(leadingSpaces)
        return stack.count - 1
    }
}

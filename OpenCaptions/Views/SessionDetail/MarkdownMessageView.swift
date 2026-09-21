//
//  MarkdownMessageView.swift
//  OpenCaptions
//
//  Renders a Chat tab assistant reply's block-level Markdown — headings,
//  fenced code blocks, and list items — on top of `MarkdownBlockParser`.
//  Inline styling (bold, italic, inline code, links) within each block still
//  resolves through `LocalizedStringKey`; only the block layout itself is
//  hand-rolled here.
//

import SwiftUI

struct MarkdownMessageView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlockParser.parse(markdown).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    // MARK: - Block rendering

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(LocalizedStringKey(text))

        case .heading(let level, let text):
            Text(LocalizedStringKey(text))
                .fontWeight(.semibold)
                .appScaledFont(headingStyle(for: level))

        case .codeBlock(let language, let code):
            codeBlockView(language: language, code: code)

        case .listItem(let text, let indentLevel, let ordered, let number):
            listItemView(text: text, indentLevel: indentLevel, ordered: ordered, number: number)
        }
    }

    /// Steps the heading size down as the level increases, matching the
    /// heading's document-outline weight rather than its literal HTML analog.
    private func headingStyle(for level: Int) -> Font.TextStyle {
        switch level {
        case 1: return .title2
        case 2: return .title3
        default: return .headline
        }
    }

    private func codeBlockView(language: String?, code: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let language {
                Text(language)
                    .appScaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                // Not LocalizedStringKey: code must render verbatim, with no
                // Markdown reinterpretation of backticks/asterisks/underscores.
                Text(code)
                    .appScaledFont(.body, design: .monospaced)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }

    private func listItemView(text: String, indentLevel: Int, ordered: Bool, number: Int?) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(listMarker(ordered: ordered, number: number, indentLevel: indentLevel))
            Text(LocalizedStringKey(text))
        }
        .padding(.leading, CGFloat(indentLevel) * 16)
    }

    private func listMarker(ordered: Bool, number: Int?, indentLevel: Int) -> String {
        if ordered, let number {
            return "\(number)."
        }
        switch indentLevel {
        case 0: return "•"
        case 1: return "◦"
        default: return "▪"
        }
    }
}

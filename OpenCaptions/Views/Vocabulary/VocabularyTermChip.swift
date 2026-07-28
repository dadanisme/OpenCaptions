//
//  VocabularyTermChip.swift
//  OpenCaptions
//
//  One term on the Vocabulary screen, drawn as a capsule chip. Replaces the original
//  row-of-text-fields design, where every row repeated the same placeholder and a
//  handful of terms became a wall of identical grey text.
//
//  `onRemove == nil` marks an ALWAYS-INCLUDED term (a built-in, or the display name):
//  same shape, dimmed, and no remove button — visible so the user can see what is
//  already biased without being able to break it.
//

import SwiftUI

struct VocabularyTermChip: View {
    let text: String
    /// Nil for always-included terms, which can't be removed.
    let onRemove: (() -> Void)?

    private var isRemovable: Bool { onRemove != nil }

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .appScaledFont(.callout)
                .foregroundStyle(isRemovable ? .primary : .secondary)
                .lineLimit(1)

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .appScaledFont(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove \(text)")
                .accessibilityLabel("Remove \(text)")
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, isRemovable ? 5 : 9)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(isRemovable ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quinary))
        )
        // Always-included chips are informational, so collapse each one into a single
        // element rather than letting VoiceOver walk the label separately.
        .accessibilityElement(children: isRemovable ? .contain : .combine)
    }
}

/// Preview host: shows both chip kinds wrapped by `FlowLayout` at a narrow width, so
/// line breaking is visible.
private struct VocabularyTermChipPreview: View {
    var body: some View {
        Form {
            Section("Removable") {
                FlowLayout {
                    ForEach(["Apple Developer Academy", "Nemotron", "FluidAudio", "Parakeet"], id: \.self) {
                        VocabularyTermChip(text: $0, onRemove: {})
                    }
                }
            }
            Section("Always included") {
                FlowLayout {
                    ForEach(["Open Captions", "Soniox", "Ramdan"], id: \.self) {
                        VocabularyTermChip(text: $0, onRemove: nil)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 320)
    }
}

#Preview {
    VocabularyTermChipPreview()
}

//
//  VocabularyTermRow.swift
//  OpenCaptions
//
//  One editable row of the Vocabulary screen: the term field plus its remove button.
//  Split out of `VocabularyScreen` so the screen stays inside the 250-line limit.
//
//  The focus binding is threaded in as a `FocusState<UUID?>.Binding` rather than
//  applied to the row from outside: `.focused` has to sit on the `TextField` itself,
//  so the screen can't focus a newly added row without reaching in here.
//

import SwiftUI

struct VocabularyTermRow: View {
    let id: UUID
    @Binding var text: String
    /// Already covered by an earlier row, a built-in, or the display name. Harmless on
    /// the wire (the context builder folds duplicates) but worth flagging so a user
    /// doesn't think a term silently failed to save.
    let isDuplicate: Bool
    var focus: FocusState<UUID?>.Binding
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("Name, product, acronym, or jargon", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused(focus, equals: id)

            if isDuplicate {
                Image(systemName: "exclamationmark.circle")
                    .appScaledFont(.callout)
                    .foregroundStyle(.secondary)
                    .help("Already in the list — it's only sent once.")
            }

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .appScaledFont(.callout)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove this term")
            .accessibilityLabel("Remove term")
        }
    }
}

/// Preview host: `@FocusState` and the text binding have to be owned by a view, and
/// this target's previews don't use `@Previewable`.
private struct VocabularyTermRowPreview: View {
    @State private var terms = ["Nemotron", "Nemotron"]
    @FocusState private var focus: UUID?
    private let ids = [UUID(), UUID()]

    var body: some View {
        Form {
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                VocabularyTermRow(
                    id: id,
                    text: $terms[index],
                    isDuplicate: index == 1,
                    focus: $focus,
                    onRemove: {}
                )
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}

#Preview {
    VocabularyTermRowPreview()
}

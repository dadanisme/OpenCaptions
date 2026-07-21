//
//  MacRenameSpeakerSheet.swift
//  OgmoMac
//
//  Small modal for renaming a speaker during a live transcription. It owns its
//  own text state, seeded from the current name at init, so the field prefills
//  DETERMINISTICALLY on every presentation — unlike a shared @State bound into a
//  SwiftUI `.alert`, whose TextField keeps a stale internal editing buffer across
//  presentations and therefore only prefills intermittently.
//

import SwiftUI

struct MacRenameSpeakerSheet: View {
    let currentName: String
    /// Called with the trimmed new name when the user confirms.
    let onCommit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var fieldFocused: Bool

    init(currentName: String, onCommit: @escaping (String) -> Void) {
        self.currentName = currentName
        self.onCommit = onCommit
        // Seeding @State here is what makes the prefill reliable: the sheet is a
        // fresh view instance each time it's presented (via `.sheet(item:)`).
        _name = State(initialValue: currentName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Speaker")
                .appScaledFont(.headline)

            TextField("Speaker name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit(commit)

            Text("This name applies to every line this speaker has said in this session.")
                .appScaledFont(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        // Select the whole field so typing immediately replaces the old name.
        .onAppear { fieldFocused = true }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private func commit() {
        guard !trimmedName.isEmpty else { return }
        onCommit(trimmedName)
        dismiss()
    }
}

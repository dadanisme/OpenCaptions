//
//  WorkspaceRenameSheet.swift
//  OpenCaptions
//
//  Small modal for renaming a workspace. Same shape as `MacRenameSpeakerSheet`:
//  the name is seeded from `currentName` at init so the field prefills
//  deterministically on every presentation (the sheet is a fresh view instance
//  each time via `.sheet(item:)`).
//

import SwiftUI

struct WorkspaceRenameSheet: View {
    let currentName: String
    /// Called with the trimmed new name when the user confirms.
    let onCommit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var fieldFocused: Bool

    init(currentName: String, onCommit: @escaping (String) -> Void) {
        self.currentName = currentName
        self.onCommit = onCommit
        _name = State(initialValue: currentName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Workspace")
                .appScaledFont(.headline)

            TextField("Workspace name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit(commit)

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

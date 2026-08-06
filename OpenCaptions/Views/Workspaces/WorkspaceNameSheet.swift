//
//  WorkspaceNameSheet.swift
//  OpenCaptions
//
//  Small modal for naming a workspace — used both to add a new one (from the
//  Workspaces screen's toolbar) and to rename an existing one (from a
//  workspace's context menu). Same shape as `MacRenameSpeakerSheet`: the name
//  is seeded at init so the field prefills deterministically on every
//  presentation (the sheet is a fresh view instance each time via `.sheet`).
//

import SwiftUI

struct WorkspaceNameSheet: View {
    let title: String
    let confirmTitle: String
    /// Called with the trimmed name when the user confirms.
    let onCommit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var fieldFocused: Bool

    init(title: String, confirmTitle: String, initialName: String = "", onCommit: @escaping (String) -> Void) {
        self.title = title
        self.confirmTitle = confirmTitle
        self.onCommit = onCommit
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .appScaledFont(.headline)

            TextField("Workspace name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit(commit)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: commit)
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

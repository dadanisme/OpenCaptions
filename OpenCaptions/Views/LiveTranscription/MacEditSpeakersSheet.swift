//
//  MacEditSpeakersSheet.swift
//  OgmoMac
//
//  Explicit edit-mode sheet for renaming the speakers of a SAVED session
//  (the detail view). Lists every diarized speaker with its palette color
//  swatch + a name field, and commits every name in one batch on Save so
//  Cancel cleanly discards the whole edit. Unlike the live per-bubble
//  `MacRenameSpeakerSheet`, this edits all speakers at once and persists to
//  SwiftData (see `MacSessionDetailView+SpeakerEditing`).
//
//  Local text state is seeded from the passed-in names at init, so every
//  field prefills DETERMINISTICALLY on presentation (same reasoning as
//  `MacRenameSpeakerSheet`: the sheet is a fresh view instance each time).
//

import SwiftUI

struct MacEditSpeakersSheet: View {
    /// One diarized speaker to edit. `color` is derived from the speaker id, so
    /// it's stable across renames and matches the transcript's color swatch.
    struct Speaker: Identifiable {
        let id: Int
        let originalName: String
        let color: Color
    }

    let speakers: [Speaker]
    /// Called on Save with the trimmed name for every speaker, keyed by id.
    let onSave: ([Int: String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var names: [Int: String]
    @FocusState private var focusedId: Int?

    init(speakers: [Speaker], onSave: @escaping ([Int: String]) -> Void) {
        self.speakers = speakers
        self.onSave = onSave
        _names = State(initialValue: Dictionary(
            uniqueKeysWithValues: speakers.map { ($0.id, $0.originalName) }
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Speakers")
                .appScaledFont(.headline)

            Text("Rename the speakers in this transcription. Each speaker keeps its color, so duplicate names stay distinguishable.")
                .appScaledFont(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(speakers) { speaker in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(speaker.color)
                                .frame(width: 12, height: 12)
                            TextField("Speaker name", text: binding(for: speaker.id))
                                .textFieldStyle(.roundedBorder)
                                .focused($focusedId, equals: speaker.id)
                                .onSubmit(commit)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 240)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!allNamesValid || !hasChanges)
            }
        }
        .padding(20)
        .frame(width: 360)
        // Focus the first field so typing is immediate on open.
        .onAppear { focusedId = speakers.first?.id }
    }

    // MARK: - State

    private func binding(for id: Int) -> Binding<String> {
        Binding(
            get: { names[id] ?? "" },
            set: { names[id] = $0 }
        )
    }

    private func trimmed(_ id: Int) -> String {
        (names[id] ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// Save requires every speaker to keep a non-empty name (blank names are
    /// meaningless and would erase the "Speaker N" fallback on the web).
    private var allNamesValid: Bool {
        speakers.allSatisfy { !trimmed($0.id).isEmpty }
    }

    /// Nothing to persist when every field still matches its original — keeps a
    /// no-op Save from writing to SwiftData / Firestore.
    private var hasChanges: Bool {
        speakers.contains { trimmed($0.id) != $0.originalName }
    }

    private func commit() {
        guard allNamesValid, hasChanges else { return }
        let result = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, trimmed($0.id)) })
        onSave(result)
        dismiss()
    }
}

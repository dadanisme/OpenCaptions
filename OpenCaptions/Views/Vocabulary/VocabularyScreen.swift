//
//  VocabularyScreen.swift
//  OpenCaptions
//
//  The "Vocabulary" sidebar section: the editor for terms biased into recognition —
//  names, product names, acronyms, jargon — plus an optional freeform background note.
//  A full-width sidebar destination rather than a Settings pane because it's a
//  variable-length list editor, which the fixed 480×460 Settings window can't host
//  comfortably.
//
//  Edits are live-committed to `VocabularyStore` (no Save button, matching how the
//  Settings toggles behave) but only READ at session start, so the copy says "next
//  session" — the same convention as the other next-session preferences.
//
//  Rows live in `VocabularyTermRow`; the store hands over an already-clamped context.
//

import SwiftUI

struct VocabularyScreen: View {
    @Environment(MacAuthManager.self) private var auth
    @State private var store = VocabularyStore.shared
    @FocusState private var focusedTerm: UUID?

    var body: some View {
        NavigationStack {
            Form {
                termsSection
                backgroundSection
                budgetSection
            }
            .formStyle(.grouped)
            .navigationTitle("Vocabulary")
        }
    }

    // MARK: - Terms

    @ViewBuilder
    private var termsSection: some View {
        Section {
            if store.terms.isEmpty {
                Text("Nothing added yet. Terms here are sent to the transcription engine as hints, so it's more likely to get them right.")
                    .appScaledFont(.callout)
                    .foregroundStyle(.secondary)
            } else {
                let duplicates = store.duplicateTermIDs(userName: auth.userName)
                ForEach(store.terms) { term in
                    VocabularyTermRow(
                        id: term.id,
                        text: binding(for: term.id),
                        isDuplicate: duplicates.contains(term.id),
                        focus: $focusedTerm,
                        onRemove: { store.removeTerm(term.id) }
                    )
                }
            }

            Button {
                // Focus the new row so typing is immediate.
                focusedTerm = store.addTerm()
            } label: {
                Label("Add Term", systemImage: "plus")
            }
        } header: {
            Text("Your Terms")
        } footer: {
            Text(builtInsFootnote)
                .appScaledFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Names what's biased on top of the user's list, so the built-ins aren't
    /// invisible magic. The display name is included on purpose — it's what the
    /// name-mention highlight and notification match against.
    private var builtInsFootnote: String {
        let always = VocabularyStore.builtInTerms.joined(separator: ", ")
        guard let name = VocabularyStore.normalizedName(auth.userName) else {
            return "Always included: \(always)."
        }
        return "Always included: \(always), and your display name (\(name)) — that's what name mentions match."
    }

    // MARK: - Background

    private var backgroundSection: some View {
        Section {
            TextEditor(text: backgroundBinding)
                .appScaledFont(.callout)
                .frame(minHeight: 90)
                .scrollContentBackground(.hidden)
        } header: {
            Text("Background")
        } footer: {
            Text("Optional. An agenda, prior notes, or a topic description — anything that tells the engine what this material is about. Shares the budget below.")
                .appScaledFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Budget

    private var budgetSection: some View {
        Section {
            LabeledContent("Context size") {
                Text("\(characterCount.formatted()) / \(SonioxConfig.Context.characterLimit.formatted())")
                    .appScaledFont(.callout)
                    .foregroundStyle(isOverLimit ? .red : .secondary)
                    .monospacedDigit()
            }

            ProgressView(
                value: Double(min(characterCount, SonioxConfig.Context.characterLimit)),
                total: Double(SonioxConfig.Context.characterLimit)
            )

            if isOverLimit {
                Label(
                    "Over the limit. Terms past the cut-off and any background text that doesn't fit are dropped — the session still runs. Remove a few terms or shorten the background.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .appScaledFont(.caption)
                .foregroundStyle(.orange)
            }
        } header: {
            Text("Context Budget")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Applies to your next session — a session already running keeps the vocabulary it started with.")
                Text("Cloud transcription only. Offline Mode transcribes on-device and doesn't support term biasing yet.")
            }
            .appScaledFont(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var characterCount: Int {
        store.contextCharacterCount(userName: auth.userName)
    }

    private var isOverLimit: Bool {
        characterCount > SonioxConfig.Context.characterLimit
    }

    // MARK: - Bindings

    /// Hand-synthesized per-row binding into the store, the same shape
    /// `MacEditSpeakersSheet` uses — the store owns the array and persists each edit,
    /// so rows can't hold their own copy.
    private func binding(for id: UUID) -> Binding<String> {
        Binding(
            get: { store.terms.first { $0.id == id }?.text ?? "" },
            set: { store.updateTerm(id, text: $0) }
        )
    }

    private var backgroundBinding: Binding<String> {
        Binding(
            get: { store.backgroundText },
            set: { store.setBackgroundText($0) }
        )
    }
}

#Preview {
    VocabularyScreen()
        .environment(MacAuthManager.shared)
        .frame(width: 520, height: 560)
}

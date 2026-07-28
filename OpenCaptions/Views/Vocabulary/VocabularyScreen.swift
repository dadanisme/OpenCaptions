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
//  Terms are entered through ONE add field and shown as chips (`VocabularyTermChip`
//  in a `FlowLayout`). The first design gave every term its own text field, which
//  repeated the same placeholder down the screen; a single field shows it once, and
//  pasting a comma- or newline-separated list adds many at a time.
//
//  The always-included terms (the app's built-ins and the display name) are chips in
//  the SAME list as the user's, just read-only — so the section reads as everything
//  being sent, rather than splitting into an editable group and an informational one.
//
//  Adds and removes commit to `VocabularyStore` immediately (no Save button, matching
//  how the Settings toggles behave) but are only READ at session start, so the copy
//  says "next session" — the same convention as the other next-session preferences.
//  The store hands the engines an already-clamped context.
//

import SwiftUI

struct VocabularyScreen: View {
    @Environment(MacAuthManager.self) private var auth
    @State private var store = VocabularyStore.shared
    /// The add field's text. Uncommitted — nothing reaches the store until Add /
    /// Return, so a half-typed term is never persisted or sent.
    @State private var draft = ""
    @FocusState private var isDraftFocused: Bool

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
            addField

            // One list, not two: the always-included terms sit alongside the user's
            // rather than in a separate group, so the section reads as "everything
            // being sent". They lead because that's also their clamp priority, and
            // they're read-only — dimmed, no remove button.
            FlowLayout {
                ForEach(store.alwaysIncludedTerms(userName: auth.userName), id: \.self) { term in
                    VocabularyTermChip(text: term, onRemove: nil)
                }
                ForEach(store.terms) { term in
                    VocabularyTermChip(
                        text: term.normalized,
                        onRemove: { store.removeTerm(term.id) }
                    )
                }
            }
        } header: {
            Text("Terms")
        } footer: {
            footnotes
        }
    }

    /// The single entry point for new terms. One field, so the placeholder appears
    /// once no matter how many terms exist.
    @ViewBuilder
    private var addField: some View {
        HStack(spacing: 8) {
            TextField("Name, product, acronym, or jargon", text: $draft)
                .textFieldStyle(.roundedBorder)
                .appScaledFont(.body)
                .focused($isDraftFocused)
                .onSubmit(commitDraft)

            Button("Add", action: commitDraft)
                .disabled(pendingTerms.isEmpty)
        }

        if pendingTerms.isEmpty && !VocabularyStore.splitCandidates(draft).isEmpty {
            // Everything typed is already covered — say so rather than letting the
            // disabled button look broken.
            Text("Already in your list.")
                .appScaledFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Explains the dimmed chips (so the built-ins aren't invisible magic — the
    /// display name is among them on purpose, since it's what the name-mention
    /// highlight and notification match against) and how to add several at once.
    @ViewBuilder
    private var footnotes: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Dimmed terms are always included: the app's own names, plus your display name — that's what name mentions match.")
            Text("Separate several terms with commas, or paste a list, to add them at once.")
        }
        .appScaledFont(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Adding

    /// What the current draft would actually add — drives both the Add button's
    /// enabled state and the "already in your list" notice.
    private var pendingTerms: [String] {
        store.newTerms(in: draft, userName: auth.userName)
    }

    private func commitDraft() {
        guard store.addTerms(from: draft, userName: auth.userName) > 0 else { return }
        draft = ""
        // Keep focus so several terms can be typed in a row.
        isDraftFocused = true
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

    /// Hand-synthesized binding into the store, the same shape `MacEditSpeakersSheet`
    /// uses — the store owns the value and persists each edit, so the field can't hold
    /// its own copy.
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

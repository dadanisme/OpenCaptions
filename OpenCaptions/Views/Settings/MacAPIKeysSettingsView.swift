//
//  MacAPIKeysSettingsView.swift
//  OpenCaptions
//
//  The Settings → API Keys pane: lets someone running a prebuilt copy of the
//  app (not one they compiled themselves) supply their own Soniox/OpenRouter
//  keys without editing Config.xcconfig and rebuilding. Stored in the
//  Keychain (`APIKeyStore`), never UserDefaults, since these are real
//  secrets. A runtime key here always takes priority over the
//  Config.xcconfig-supplied build-time value — see `SonioxSecrets.sonioxAPIKey`
//  and `SummaryService+OpenRouter.apiKey()`.
//
//  Each field keeps a local draft `@State`, seeded once from the Keychain on
//  appear — the displayed text is never re-read from the Keychain mid-edit,
//  so a transient read/write hiccup can't make just-typed characters vanish.
//

import AppKit
import SwiftUI

struct MacAPIKeysSettingsView: View {
    var body: some View {
        Form {
            Section("Soniox API Key") {
                LabeledContent {
                    APIKeyField(key: .soniox, placeholder: "Soniox API key")
                } label: {
                    SettingsInfoTip.label("Soniox", tip: "Powers cloud transcription, diarization, and custom vocabulary. Get one at soniox.com. Leave blank to use the key built into this copy of the app, if any.")
                }
            }
            Section("OpenRouter API Key") {
                LabeledContent {
                    APIKeyField(key: .openRouter, placeholder: "OpenRouter API key")
                } label: {
                    SettingsInfoTip.label("OpenRouter", tip: "Powers AI summaries and automatic speaker naming. Get one at openrouter.ai/keys. Leave blank to use the key built into this copy of the app, if any.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// One masked key field with a reveal toggle and a copy button.
private struct APIKeyField: View {
    let key: APIKeyStore.Key
    let placeholder: String

    @State private var text = ""
    @State private var isRevealed = false
    @State private var saveFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Group {
                    if isRevealed {
                        TextField(placeholder, text: $text)
                    } else {
                        SecureField(placeholder, text: $text)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .labelsHidden()
                .onChange(of: text) { _, newValue in
                    saveFailed = !APIKeyStore.write(key, value: newValue)
                }

                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.plain)
                .help(isRevealed ? "Hide key" : "Show key")

                Button {
                    copyToClipboard()
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.plain)
                .disabled(text.isEmpty)
                .help("Copy key")
            }
            if saveFailed {
                Label("Couldn't save to the Keychain — try again.", systemImage: "exclamationmark.triangle.fill")
                    .appScaledFont(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onAppear { text = APIKeyStore.read(key) ?? "" }
    }

    private func copyToClipboard() {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

#Preview {
    MacAPIKeysSettingsView()
        .frame(width: 480, height: 460)
}

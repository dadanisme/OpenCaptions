//
//  MacSettingsView.swift
//  OpenCaptions
//
//  The macOS Settings window (Cmd+,). The General tab gathers all preferences
//  (your name, appearance, recording, captions); Shortcuts holds hot keys and
//  Support holds diagnostics/contact. It is a TabView so further panes slot in
//  without restructuring. See docs/2026-08-10-remove-accounts-and-firestore.md.
//

import AppKit
import SwiftUI

struct MacSettingsView: View {
    /// The user's own name — device-local, used for mention-highlighting and
    /// transcription personalization. See `LiveSessionStore.yourNameKey`.
    @AppStorage(LiveSessionStore.yourNameKey) private var yourName = ""
    /// "Show captions overlay when a session starts" — read by `LiveSessionStore`
    /// at session start via the same UserDefaults key.
    @AppStorage(LiveSessionStore.captionsAutoShowKey) private var captionsAutoShow = true
    /// Overlay background opacity for the material fallback (macOS < 26).
    @AppStorage(LiveSessionStore.captionsOpacityKey) private var captionsOpacity = 0.9
    /// Shared transcript font-size multiplier — scales the live transcript AND the
    /// overlay captions. Same key the pill and menu-bar controls write.
    @AppStorage(LiveSessionStore.transcriptTextSizeKey) private var textSizeMultiplier = 1.0
    /// App-WIDE UI font-size multiplier — scales the general chrome (sidebar, lists,
    /// detail, summaries, settings). Independent of `textSizeMultiplier` above.
    @AppStorage(LiveSessionStore.appTextSizeKey) private var appTextSizeMultiplier = TranscriptTextSize.defaultMultiplier
    /// "Save session audio for playback" — read by `MacTranscriptionViewModel`
    /// at record time via the same UserDefaults key.
    @AppStorage(LiveSessionStore.sessionAudioKey) private var saveSessionAudio = true
    /// Automatic re-transcription after recording. When on, a saved session is
    /// re-processed automatically; the engine follows Offline Mode (Parakeet offline /
    /// Soniox cloud). Read by `RetranscriptionManager`.
    @AppStorage(LiveSessionStore.retranscriptionAutoKey) private var autoRetranscribe = false
    /// Offline Mode. Off → cloud Soniox (diarized); on → on-device Nemotron with no
    /// network. Read at session start by `MacTranscriptionViewModel.start` and used to
    /// gate cloud summary generation. Can only be turned on once both on-device models
    /// are downloaded.
    @AppStorage(LiveSessionStore.offlineModeKey) private var offlineModeEnabled = false
    /// Automatic speaker naming from the summary pass. When on, a generated summary
    /// also names the diarized speakers it recognises. Read by `SummaryViewModel`.
    @AppStorage(LiveSessionStore.speakerNamingAutoKey) private var autoNameSpeakers = true

    var body: some View {
        TabView {
            generalPane
                .tabItem { Label("General", systemImage: "gearshape") }
            MacHotKeysSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            MacSupportSettingsView()
                .tabItem { Label("Support", systemImage: "questionmark.circle") }
        }
        .frame(width: 480, height: 460)
    }

    /// Whether the app size is at its 100% default (tolerant of float step drift).
    private var isAppTextSizeDefault: Bool {
        abs(appTextSizeMultiplier - TranscriptTextSize.defaultMultiplier) < 0.001
    }

    /// Bridges the discrete `AppTextSize.steps` to a uniform-index slider so the
    /// non-uniform 150→200→300 jumps read as evenly-spaced notches.
    private var appTextSizeIndex: Binding<Double> {
        Binding(
            get: { Double(AppTextSize.index(for: appTextSizeMultiplier)) },
            set: { appTextSizeMultiplier = AppTextSize.steps[Int($0.rounded())] }
        )
    }

    private var generalPane: some View {
        Form {
            Section("Your Name") {
                LabeledContent("Name") {
                    TextField("e.g. Alex", text: $yourName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .labelsHidden()
                }
                Text("Use the name people actually call you. Open Captions highlights and alerts you when it's spoken during a session, and includes it in Vocabulary to help transcription recognize it correctly.")
                    .appScaledFont(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Appearance") {
                LabeledContent("App text size") {
                    HStack(spacing: 12) {
                        // Tick-marked slider over the discrete stops (80%–300%).
                        Slider(value: appTextSizeIndex,
                               in: 0...Double(AppTextSize.steps.count - 1),
                               step: 1)
                            .frame(width: 150)
                        // Live percentage read-out pinpoints the current value, and
                        // flags when it's the 100% default.
                        Text(isAppTextSizeDefault
                             ? "100% · Default"
                             : TranscriptTextSize.percentLabel(appTextSizeMultiplier))
                            .appScaledFont(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 96, alignment: .leading)
                        // One-tap return to the default (disabled when already there).
                        Button("Reset") {
                            appTextSizeMultiplier = TranscriptTextSize.defaultMultiplier
                        }
                        .disabled(isAppTextSizeDefault)
                    }
                }
                Text("Scales the app's general interface — sidebar, session list, summaries, and settings. Independent of the transcript & captions size below.")
                    .appScaledFont(.caption)
                    .foregroundStyle(.secondary)
            }

            captionsSections
            recordingSections
        }
        .formStyle(.grouped)
    }

    /// Offline transcription needs its on-device files present before it can be
    /// turned on. Observing the managers' `status` keeps the gate live as the
    /// download completes.
    private var offlineFilesReady: Bool {
        FluidAudioModelManager.nemotron.status == .ready
            && FluidAudioModelManager.parakeet.status == .ready
    }

    @ViewBuilder
    private var recordingSections: some View {
        Section("Offline Mode") {
            if offlineFilesReady {
                // Files are on disk — plain on/off toggle.
                Toggle("Enable Offline Mode", isOn: $offlineModeEnabled)
            } else {
                // Not downloaded yet — the row's action is Download (or progress),
                // not a toggle. It flips to the toggle above once the files land.
                LabeledContent("Enable Offline Mode") { MacOfflineDownloadControl() }
            }
            Text(offlineModeFootnote)
                .appScaledFont(.caption)
                .foregroundStyle(.secondary)
        }
        Section("Session Audio") {
            Toggle("Save session audio for playback", isOn: $saveSessionAudio)
            Text("Keeps a copy of each session's audio so you can play it back and tap a line to jump to that moment. Audio is stored on this Mac and removed when you delete the session.")
                .appScaledFont(.caption)
                .foregroundStyle(.secondary)
        }
        Section("Re-transcription") {
            // Disabled without saved session audio: with no `.m4a` there's nothing to
            // re-process, and the automatic pass is silent (no error surfaces), so an
            // enabled-but-inert toggle would look like a broken feature.
            Toggle("Automatically re-transcribe after each session", isOn: $autoRetranscribe)
                .disabled(!saveSessionAudio)
            Text("After each session is saved, re-process it for higher accuracy. It follows Offline Mode: on-device Parakeet when Offline Mode is on (English only, no speaker labels), or cloud Soniox when it's off (speaker labels). You can also re-transcribe any saved session manually from its ⋯ menu. Requires saved session audio.")
                .appScaledFont(.caption)
                .foregroundStyle(.secondary)
        }
        Section("Speaker Names") {
            // Disabled in Offline Mode: on-device transcription produces no speaker
            // labels and skips summary generation, so there is nothing to name — an
            // enabled-but-inert toggle would read as a broken feature (same reasoning
            // as the re-transcription toggle above).
            Toggle("Name speakers automatically from the summary", isOn: $autoNameSpeakers)
                .disabled(offlineModeEnabled)
            Text(speakerNamingFootnote)
                .appScaledFont(.caption)
                .foregroundStyle(.secondary)
        }
        MacMarkdownExportSection()
    }

    /// Explanatory note under the automatic speaker-naming toggle.
    private var speakerNamingFootnote: String {
        if offlineModeEnabled {
            return "Unavailable in Offline Mode — on-device transcription doesn't separate speakers, and AI summaries don't run offline."
        }
        return autoNameSpeakers
            ? "When a summary is generated, speakers who introduce themselves or are addressed by name are renamed for you — \"Speaker 1\" becomes \"Ramdan\". Uncertain speakers keep their generic label, and you can always correct a name from Edit Speakers."
            : "Speakers keep their generic \"Speaker 1\" labels. You can name them yourself any time from a session's Edit Speakers."
    }

    /// Explanatory note under the Offline Mode toggle.
    private var offlineModeFootnote: String {
        if !offlineFilesReady {
            return "Download the offline files to enable Offline Mode. It's a one-time download kept on this Mac."
        }
        return offlineModeEnabled
            ? "Transcribe entirely on this Mac (English only) — no internet needed and your audio never leaves your device. AI summaries aren't available offline. Applies to your next session."
            : "Transcribe in the cloud with speaker labels. Requires an internet connection. Applies to your next session."
    }

    @ViewBuilder
    private var captionsSections: some View {
        Section("Captions") {
            Toggle("Show captions overlay when a session starts", isOn: $captionsAutoShow)
            LabeledContent("Transcript text size") {
                Slider(value: $textSizeMultiplier,
                       in: TranscriptTextSize.range,
                       step: TranscriptTextSize.step)
                    .frame(width: 180)
            }
            Text("Scales both the live transcript and the floating captions. Also adjustable during a session from the transport bar or the menu-bar item.")
                .appScaledFont(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("Background opacity") {
                Slider(value: $captionsOpacity, in: 0.2...1.0)
                    .frame(width: 180)
            }
            Text("Controls the overlay's translucency on macOS 15 and earlier. On macOS 26+ the overlay uses Liquid Glass and manages its own translucency.")
                .appScaledFont(.caption)
                .foregroundStyle(.secondary)
        }
        Section {
            Text("The overlay floats above other apps so you can read live captions while watching a meeting, video, or slides. Drag it to move, drag an edge to resize, and toggle it any time from the Session menu (⇧⌘C) or the menu-bar item.")
                .appScaledFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

}

#Preview {
    MacSettingsView()
}

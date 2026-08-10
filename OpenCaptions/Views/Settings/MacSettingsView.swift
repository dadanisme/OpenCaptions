//
//  MacSettingsView.swift
//  OpenCaptions
//
//  The `.settings` `NavSection` destination — rendered in the main window's
//  detail column rather than a separate window/scene. The General tab gathers
//  all preferences (your name, appearance, recording, captions); Shortcuts
//  holds hot keys and Support holds diagnostics/contact. Each row's
//  explanation lives behind a `SettingsInfoTip` "i" icon instead of an
//  always-visible paragraph underneath — see
//  docs/2026-08-10-macos-settings-navsection.md.
//
//  The tab switcher is a native segmented `Picker` in the toolbar, matching
//  `MacSessionDetailView`'s Summary/Transcript switcher (see its own doc
//  comment for why: native so its Liquid Glass matches neighboring toolbar
//  chrome exactly) rather than a plain `TabView`, whose own tab bar reads as
//  an OS-chrome band inside what's otherwise a plain sidebar destination.
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

    @State private var tab: Tab = .general

    private enum Tab: Hashable {
        case general, shortcuts, support
    }

    var body: some View {
        NavigationStack {
            tabContent
                .navigationTitle("Settings")
                .toolbar {
                    ToolbarItem {
                        tabSwitcher
                    }
                }
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .general: generalPane
        case .shortcuts: MacHotKeysSettingsView()
        case .support: MacSupportSettingsView()
        }
    }

    private var tabSwitcher: some View {
        Picker("View", selection: $tab) {
            Text("General").tag(Tab.general)
            Text("Shortcuts").tag(Tab.shortcuts)
            Text("Support").tag(Tab.support)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
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
                LabeledContent {
                    TextField("e.g. Alex", text: $yourName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .labelsHidden()
                } label: {
                    SettingsInfoTip.label("Name", tip: "Use the name people actually call you. Open Captions highlights and alerts you when it's spoken during a session, and includes it in Vocabulary to help transcription recognize it correctly.")
                }
            }

            Section("Appearance") {
                LabeledContent {
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
                } label: {
                    SettingsInfoTip.label("App text size", tip: "Scales the app's general interface — sidebar, session list, summaries, and settings. Independent of the transcript & captions size below.")
                }
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
                // Files are on disk — plain on/off toggle. `Toggle`'s label is
                // itself a tap target on macOS, which would fight the info tip's
                // own tap; putting the switch in a `LabeledContent` value slot
                // instead (same shape as the download-control branch below)
                // keeps the tip and the switch as two separate, unambiguous
                // controls.
                LabeledContent {
                    Toggle("", isOn: $offlineModeEnabled).labelsHidden()
                } label: { offlineModeLabel }
            } else {
                // Not downloaded yet — the row's action is Download (or progress),
                // not a toggle. It flips to the toggle above once the files land.
                LabeledContent { MacOfflineDownloadControl() } label: { offlineModeLabel }
            }
        }
        Section("Session Audio") {
            LabeledContent {
                Toggle("", isOn: $saveSessionAudio).labelsHidden()
            } label: {
                SettingsInfoTip.label("Save session audio for playback", tip: "Keeps a copy of each session's audio so you can play it back and tap a line to jump to that moment. Audio is stored on this Mac and removed when you delete the session.")
            }
        }
        Section("Re-transcription") {
            LabeledContent {
                // Disabled without saved session audio: with no `.m4a` there's
                // nothing to re-process, and the automatic pass is silent (no
                // error surfaces), so an enabled-but-inert toggle would look
                // like a broken feature.
                Toggle("", isOn: $autoRetranscribe).labelsHidden()
                    .disabled(!saveSessionAudio)
            } label: {
                SettingsInfoTip.label("Automatically re-transcribe after each session", tip: "After each session is saved, re-process it for higher accuracy. It follows Offline Mode: on-device Parakeet when Offline Mode is on (English only, no speaker labels), or cloud Soniox when it's off (speaker labels). You can also re-transcribe any saved session manually from its ⋯ menu. Requires saved session audio.")
            }
        }
        Section("Speaker Names") {
            LabeledContent {
                // Disabled in Offline Mode: on-device transcription produces no
                // speaker labels and skips summary generation, so there is
                // nothing to name — an enabled-but-inert toggle would read as a
                // broken feature (same reasoning as the re-transcription toggle
                // above).
                Toggle("", isOn: $autoNameSpeakers).labelsHidden()
                    .disabled(offlineModeEnabled)
            } label: {
                SettingsInfoTip.label("Name speakers automatically from the summary", tip: speakerNamingFootnote)
            }
        }
        MacMarkdownExportSection()
    }

    /// Label + info tip shared by the Offline Mode row's two states (toggle vs.
    /// download control).
    private var offlineModeLabel: some View {
        SettingsInfoTip.label("Enable Offline Mode", tip: offlineModeFootnote)
    }

    /// Explanatory text shown in the automatic speaker-naming row's info tip.
    private var speakerNamingFootnote: String {
        if offlineModeEnabled {
            return "Unavailable in Offline Mode — on-device transcription doesn't separate speakers, and AI summaries don't run offline."
        }
        return autoNameSpeakers
            ? "When a summary is generated, speakers who introduce themselves or are addressed by name are renamed for you — \"Speaker 1\" becomes \"Ramdan\". Uncertain speakers keep their generic label, and you can always correct a name from Edit Speakers."
            : "Speakers keep their generic \"Speaker 1\" labels. You can name them yourself any time from a session's Edit Speakers."
    }

    /// Explanatory text shown in the Offline Mode row's info tip.
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
        Section {
            Toggle("Show captions overlay when a session starts", isOn: $captionsAutoShow)
            LabeledContent {
                Slider(value: $textSizeMultiplier,
                       in: TranscriptTextSize.range,
                       step: TranscriptTextSize.step)
                    .frame(width: 180)
            } label: {
                SettingsInfoTip.label("Transcript text size", tip: "Scales both the live transcript and the floating captions. Also adjustable during a session from the transport bar or the menu-bar item.")
            }
            LabeledContent {
                Slider(value: $captionsOpacity, in: 0.2...1.0)
                    .frame(width: 180)
            } label: {
                SettingsInfoTip.label("Background opacity", tip: "Controls the overlay's translucency on macOS 15 and earlier. On macOS 26+ the overlay uses Liquid Glass and manages its own translucency.")
            }
        } header: {
            SettingsInfoTip.label("Captions", tip: "The overlay floats above other apps so you can read live captions while watching a meeting, video, or slides. Drag it to move, drag an edge to resize, and toggle it any time from the Session menu (⇧⌘C) or the menu-bar item.")
        }
    }

}

#Preview {
    MacSettingsView()
}

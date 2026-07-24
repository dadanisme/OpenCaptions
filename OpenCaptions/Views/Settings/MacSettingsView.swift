//
//  MacSettingsView.swift
//  OpenCaptions
//
//  The macOS Settings window (Cmd+,). Home for advanced account actions. The
//  General tab gathers all preferences (appearance, recording, captions); the
//  Account tab holds identity + Sign Out + Delete Account and Shortcuts holds hot
//  keys. It is a TabView so further panes slot in without restructuring.
//  See docs/2026-07-05-macos-auth-and-scoping.md.
//

import AppKit
import SwiftUI

struct MacSettingsView: View {
    @Environment(MacAuthManager.self) private var auth
    /// "Show captions overlay when recording starts" — read by `LiveSessionStore`
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
    /// at record time via the same UserDefaults key. Only takes effect while the
    /// `sessionPlayback` remote flag is on.
    @AppStorage(LiveSessionStore.sessionAudioKey) private var saveSessionAudio = true
    /// Automatic re-transcription after recording. When on, a saved session is
    /// re-processed automatically; the engine follows Offline Mode (Parakeet offline /
    /// Soniox cloud). Read by `RetranscriptionManager`. Only takes effect while the
    /// `postSessionRetranscription` remote flag is on; the section is hidden until then.
    @AppStorage(LiveSessionStore.retranscriptionAutoKey) private var autoRetranscribe = false
    /// Offline Mode. Off → cloud Soniox (diarized); on → on-device Nemotron with no
    /// network. Read at session start by `MacTranscriptionViewModel.start` and used to
    /// gate cloud summary generation. Can only be turned on once both on-device models
    /// are downloaded.
    @AppStorage(LiveSessionStore.offlineModeKey) private var offlineModeEnabled = false

    var body: some View {
        TabView {
            MacAccountSettingsView()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
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
                // Files are on disk — plain on/off toggle. Locked ON for an offline
                // guest: the cloud path is unavailable without an account.
                Toggle("Enable Offline Mode", isOn: $offlineModeEnabled)
                    .disabled(auth.isGuest)
                    .onChange(of: offlineModeEnabled) { _, newValue in
                        // Mirror to Firestore when signed in (no-op otherwise).
                        FirestoreSyncService.shared.syncOfflineMode(newValue)
                    }
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
        if FeatureFlagService.shared.isEnabled(.postSessionRetranscription) {
            Section("Re-transcription") {
                Toggle("Automatically re-transcribe after recording", isOn: $autoRetranscribe)
                Text("After each recording is saved, re-process it for higher accuracy. It follows Offline Mode: on-device Parakeet when Offline Mode is on (English only, no speaker labels), or cloud Soniox when it's off (speaker labels). You can also re-transcribe any saved session manually from its ⋯ menu. Requires saved session audio.")
                    .appScaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Explanatory note under the Offline Mode toggle.
    private var offlineModeFootnote: String {
        if auth.isGuest {
            return "You're using Open Captions offline — transcription runs entirely on this Mac (English only). Sign in from the Account tab to enable cloud transcription with speaker labels."
        }
        if !offlineFilesReady {
            return "Download the offline files to enable Offline Mode. It's a one-time download kept on this Mac."
        }
        return offlineModeEnabled
            ? "Transcribe entirely on this Mac (English only) — no internet needed and your audio never leaves your device. AI summaries aren't available offline. Applies to your next recording."
            : "Transcribe in the cloud with speaker labels. Requires an internet connection. Applies to your next recording."
    }

    @ViewBuilder
    private var captionsSections: some View {
        Section("Captions") {
            Toggle("Show captions overlay when recording starts", isOn: $captionsAutoShow)
            LabeledContent("Transcript text size") {
                Slider(value: $textSizeMultiplier,
                       in: TranscriptTextSize.range,
                       step: TranscriptTextSize.step)
                    .frame(width: 180)
            }
            Text("Scales both the live transcript and the floating captions. Also adjustable while recording from the transport bar or the menu-bar item.")
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
            Text("The overlay floats above other apps so you can read live captions while watching a meeting, video, or slides. Drag it to move, drag an edge to resize, and toggle it any time from the Recording menu (⇧⌘C) or the menu-bar item.")
                .appScaledFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

}

#Preview {
    MacSettingsView()
        .environment(MacAuthManager.shared)
}

//
//  MenuBarContent.swift
//  OpenCaptions
//
//  The dropdown for the system menu-bar item: a status line + full recording
//  transport (Pause-Resume / End & Save / Show-Hide Captions / Audio Source /
//  New Session) plus Open/Quit. Rendered as a native menu
//  (`.menuBarExtraStyle(.menu)`), so each row maps to a menu item; actions read
//  from the shared `MenuBarState` (or call `LiveSessionStore` directly) and bring
//  the app forward. The Audio Source picker changes the live capture source (a
//  hot-swap) while recording, or the default the next recording uses while idle.
//
//  The status row shows only the state (recording / paused / idle) — no elapsed
//  timer, since a native menu can't live-refresh while open.
//

import AppKit
import SwiftUI

struct MenuBarContent: View {
    @Environment(MenuBarState.self) private var state
    @Environment(\.openWindow) private var openWindow

    /// Persisted capture source, shared with the in-window pill's `@AppStorage` on
    /// the same key — so this picker's checkmark tracks a source changed from either
    /// surface. The binding's setter routes through the store (live hot-swap or idle
    /// default) rather than writing the key blindly. Default falls back to `.microphone`.
    @AppStorage(LiveSessionStore.audioSourceKey) private var sourceRaw = AudioSource.microphone.rawValue

    /// Shared transcript font-size multiplier, surfaced here as discrete steps (a
    /// native menu can't host a slider). Same key the pill/Settings sliders write,
    /// so this submenu's checkmark tracks a change made from either.
    @AppStorage(LiveSessionStore.transcriptTextSizeKey) private var textSizeMultiplier = 1.0

    var body: some View {
        if state.status == .idle {
            Button(action: newRecording) {
                Label("New Session", systemImage: "record.circle")
            }
        } else {
            Button { state.endAndSave?() } label: {
                Label("End & Save", systemImage: "stop.fill")
            }
            .disabled(state.endAndSave == nil)
        }

        Divider()

        Button { state.togglePause?() } label: {
            Label(
                state.status == .paused ? "Resume" : "Pause",
                systemImage: state.status == .paused ? "play.fill" : "pause.fill"
            )
        }
        .disabled(state.togglePause == nil)

        Button { state.toggleCaptions?() } label: {
            Label(
                state.captionsVisible ? "Hide Captions" : "Show Captions",
                systemImage: state.captionsVisible ? "captions.bubble.fill" : "captions.bubble"
            )
        }
        .disabled(state.toggleCaptions == nil)

        audioSourcePicker
        fontSizePicker

        Divider()

        Button { showWindow() } label: {
            Label("Show Open Captions", systemImage: "macwindow")
        }
        Button { NSApplication.shared.terminate(nil) } label: {
            Label("Quit Open Captions", systemImage: "power")
        }
    }

    /// Audio-source submenu (Microphone / System Audio / both), rendered by the
    /// native menu as a checkmarked list. Changing it while a session is live
    /// hot-swaps the source; while idle it sets the default the next recording
    /// uses. Disabled while paused — the live source can't be swapped mid-pause
    /// (the pill's selector is likewise off then), and it's not "idle" either.
    private var audioSourcePicker: some View {
        Picker(selection: source) {
            ForEach(AudioSource.allCases) { option in
                Label(option.label, systemImage: option.systemImage).tag(option)
            }
        } label: {
            Label("Audio Source", systemImage: source.wrappedValue.systemImage)
        }
        .disabled(state.status == .paused)
    }

    /// Reads the persisted source; routes a change through the store so a live
    /// session hot-swaps (with mic gating) and an idle selection persists a default.
    private var source: Binding<AudioSource> {
        Binding(
            get: { AudioSource(rawValue: sourceRaw) ?? .microphone },
            set: { LiveSessionStore.shared.selectAudioSource($0) }
        )
    }

    /// Transcript font-size submenu (discrete percentage steps up to 300%). Always
    /// available — it's a display preference that also sets what the next
    /// recording/overlay use.
    private var fontSizePicker: some View {
        Picker(selection: fontSizeStep) {
            ForEach(TranscriptTextSize.menuSteps, id: \.self) { mult in
                Text(TranscriptTextSize.percentLabel(mult)).tag(mult)
            }
        } label: {
            Label("Text Size", systemImage: "textformat.size")
        }
    }

    /// Reads the shared multiplier as the nearest discrete step (so the checkmark
    /// stays sensible even after a slider set an in-between value); a change writes
    /// that step's multiplier back to the shared key.
    private var fontSizeStep: Binding<Double> {
        Binding(
            get: { TranscriptTextSize.nearestStep(to: textSizeMultiplier) },
            set: { textSizeMultiplier = $0 }
        )
    }

    /// Starts a new recording straight from the menu-bar item — without also
    /// raising the app. Tries a headless start first (mic source, or system audio
    /// already granted); only if that can't proceed (permission UI needed) does it
    /// fall back to opening the window and handing off to the list screen.
    private func newRecording() {
        Task {
            if await LiveSessionStore.shared.startHeadlessRecording() { return }
            showWindow()
            if let start = state.startRecording {
                start()
            } else {
                state.pendingStartRequest = true
            }
        }
    }

    /// Brings Open Captions's window to the front, reopening it if it was closed.
    private func showWindow() {
        activateApp()
        openWindow(id: MainWindowID.main)
    }

    @ViewBuilder
    private var statusRow: some View {
        switch state.status {
        case .idle:
            Button(action: newRecording) {
                Label("New Session", systemImage: "record.circle")
            }
        case .recording:
            Text("● Recording")
        case .paused:
            Text("❙❙ Paused")
        }
    }

    /// Brings Open Captions (and its window) to the front so a menu-bar action's result
    /// is visible.
    @MainActor
    private func activateApp() {
        NSApplication.shared.activate()
    }
}

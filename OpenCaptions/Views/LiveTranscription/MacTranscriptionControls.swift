//
//  MacTranscriptionControls.swift
//  OpenCaptions
//
//  The floating "transport pill" for the live recording screen (Apple Music
//  style): a compact Liquid Glass capsule with three equal zones — an audio-input
//  selector, a center play/pause glyph, and a destructive End glyph. Extracted
//  from MacLiveTranscriptionView to keep each file focused (and under the 250-line
//  limit). Pure presentation: it reads transcription state from the view model and
//  reports the End tap back to its parent, which owns the confirm/save flow.
//

import SwiftUI

struct MacTranscriptionControls: View {
    /// Drives play/pause state + actions; read reactively (an @Observable ref).
    let viewModel: MacTranscriptionViewModel
    /// Disables transport while an End/Save is in flight.
    let isStopping: Bool
    /// Selected capture source. The parent's binding gates permission + hot-swap.
    @Binding var source: AudioSource
    /// Invoked when End is tapped; the parent decides confirm-vs-save-directly.
    let onEnd: () -> Void

    /// Shared transcript font-size multiplier (see `TranscriptTextSize`), scaling
    /// the live transcript + overlay captions. Same key the menu-bar and Settings
    /// write, so a change here reflects everywhere live.
    @AppStorage(LiveSessionStore.transcriptTextSizeKey) private var textSizeMultiplier = 1.0
    /// Drives the font-size slider popover.
    @State private var showTextSizePopover = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                audioInputSelector
                fontSizeSelector
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            transportControl
                .layoutPriority(1)
            endButton
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .liquidGlassBackground(in: Capsule())
        // Cap the bar width so it stays a centered floating pill on wide windows
        // instead of stretching edge to edge.
        .frame(maxWidth: 700)
        .padding(.horizontal)
        .padding(.bottom, 12)
    }

    /// Leading audio-source selector (Microphone / System Audio). Enabled only
    /// while actively recording, so a change hot-swaps the live source; picking
    /// System Audio routes through the parent's screen-recording gate. The word
    /// status lives in the window title-bar subtitle (see `MacLiveTranscriptionView`).
    private var audioInputSelector: some View {
        Menu {
            ForEach(AudioSource.allCases) { option in
                Button {
                    source = option
                } label: {
                    Label(option.label, systemImage: option.systemImage)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: source.systemImage)
                Text(source.label)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .disabled(isStopping || !viewModel.isRunning)
        .help("Select audio source")
    }

    /// Font-size control: a compact glyph opening a popover with a fine-grained
    /// slider that scales the live transcript AND the overlay captions. A native
    /// macOS `Menu` can't host a `Slider`, so this uses a popover (the issue's
    /// sanctioned alternative). Always enabled — it's a display preference.
    private var fontSizeSelector: some View {
        Button {
            showTextSizePopover.toggle()
        } label: {
            Image(systemName: "textformat.size")
                .font(.callout)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Text size")
        .accessibilityLabel("Text size")
        .popover(isPresented: $showTextSizePopover, arrowEdge: .bottom) {
            textSizeSlider
        }
    }

    /// The popover's slider — a port of the iOS display-settings text-size row: a
    /// small "A" and large "A" flanking a fine-grained slider over the shared
    /// multiplier.
    private var textSizeSlider: some View {
        HStack(spacing: 12) {
            Text("A")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(
                value: $textSizeMultiplier,
                in: TranscriptTextSize.range,
                step: TranscriptTextSize.step
            )
            .frame(width: 160)
            .accessibilityLabel("Text size")
            Text("A")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Center play/pause, rendered as a bare Apple-Music-style glyph (no button
    /// chrome), swapping symbols with a smooth transition.
    private var transportControl: some View {
        Button {
            if viewModel.isPaused {
                Task { await viewModel.resume() }
            } else {
                viewModel.pause()
            }
        } label: {
            Image(systemName: viewModel.isPaused ? "play.fill" : "pause.fill")
                .font(.title2)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isStopping || (!viewModel.isRunning && !viewModel.isPaused))
        .help(viewModel.isPaused ? "Resume" : "Pause")
    }

    /// Ends & saves the session — a bare red (danger) glyph matching the transport
    /// style. The parent confirms first when a session is live/paused.
    private var endButton: some View {
        Button(action: onEnd) {
            Image(systemName: "xmark")
                .font(.title3)
                .foregroundStyle(.red)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isStopping)
        .help("End & Save")
        // Icon-only: .help is a tooltip/hint, so spell out the destructive action
        // for VoiceOver (the implicit "xmark" label reads as a harmless "close").
        .accessibilityLabel("End and save")
    }
}

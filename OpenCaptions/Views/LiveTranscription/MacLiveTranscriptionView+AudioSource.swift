//
//  MacLiveTranscriptionView+AudioSource.swift
//  OpenCaptions
//
//  Source selection + permission glue for the live recording screen, split out
//  to keep MacLiveTranscriptionView under the per-file line limit. Owns the
//  transport-pill binding, the start-time microphone gate, and the mid-session
//  live source hot-swap.
//
//  Permission model: system-audio capture uses a Core Audio process tap,
//  which has NO preflight/request API — the OS shows the "Audio Recording" prompt
//  on the first capture start. So system-audio sources start optimistically; only
//  the microphone (which has a public preflight) is gated before capture.
//

import AppKit
import SwiftUI
import SwiftData

extension MacLiveTranscriptionView {

    /// The currently persisted capture source.
    var selectedSource: AudioSource { AudioSource(rawValue: sourceRaw) ?? .microphone }

    /// Binding the transport-pill picker reads/writes; the setter routes the
    /// change through permission gating + the live hot-swap.
    var sourceBinding: Binding<AudioSource> {
        Binding(get: { selectedSource }, set: { handleSourceSelection($0) })
    }

    /// Requests the microphone grant (if the source needs it), then starts the
    /// session. System-audio capture isn't gated here — the process tap prompts
    /// for "Audio Recording" on its first start, inside `viewModel.start`.
    @MainActor
    func startIfPermitted() async {
        // Rebind, don't restart: if this session has already started (running,
        // paused, or failed-with-kept-transcript), the window was just reopened
        // onto it — leave it running and show its current state.
        guard !viewModel.hasStarted else { return }
        let source = selectedSource
        if source.requiresMicrophone {
            guard await MacAudioService.requestMicPermission() else {
                access = .micDenied
                return
            }
        }
        access = .ok
        await viewModel.start(modelContainer: modelContext.container, source: source)
    }

    /// Handles a transport-pill source change. Requests the mic first if the new
    /// source needs it (a no-op once authorized); on a denial the picker reverts
    /// (`sourceRaw` unchanged). System-audio capture prompts on the swap's start.
    func handleSourceSelection(_ newSource: AudioSource) {
        guard newSource != selectedSource else { return }
        if newSource.requiresMicrophone {
            Task { @MainActor in
                guard await MacAudioService.requestMicPermission() else { return }
                applySourceSwitch(to: newSource)
            }
        } else {
            applySourceSwitch(to: newSource)
        }
    }

    /// Applies a live source swap and persists the choice ONLY if it actually took
    /// effect. During the connect window (isRunning true but no live pump yet) the
    /// switch no-ops; committing sourceRaw anyway would diverge the picker from the
    /// real capture. On a no-op the picker reverts to the current source.
    private func applySourceSwitch(to newSource: AudioSource) {
        if viewModel.switchAudioSource(to: newSource) {
            sourceRaw = newSource.rawValue
        }
    }
}

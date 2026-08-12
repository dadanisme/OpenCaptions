//
//  MacOnboardingView.swift
//  OpenCaptions
//
//  First-run setup assistant, shown by the app gate until onboarding is complete.
//  A single-card wizard: a progress-dot header, the current step's content, and a
//  Back / primary action bar. Steps: Welcome → Mode → Download (offline only) →
//  Capture → Permissions → Ready.
//
//  The Mode step forks the flow: cloud needs no extra setup and goes straight to
//  Capture; offline downloads the on-device model first. On finish,
//  `complete()` records the chosen mode and sets the onboarding-complete flag,
//  which flips the app gate (`OpenCaptionsApp`) to the main UI.
//  See docs/2026-08-10-remove-accounts-and-firestore.md.
//

import SwiftUI

struct MacOnboardingView: View {
    @State private var step: OnboardingStep = .welcome
    @State private var mode: OnboardingMode?
    @State private var source: AudioSource = .microphone
    @State private var micGranted = false
    @State private var systemAudioPrimed = false

    /// Offline can't finish until both on-device models are on disk (recording
    /// hard-fails otherwise). Read here so Continue enables as the download lands.
    private var modelsReady: Bool {
        FluidAudioModelManager.nemotron.status == .ready
            && FluidAudioModelManager.parakeet.status == .ready
    }

    var body: some View {
        VStack(spacing: 0) {
            // Pinned top chrome — the progress dots stay visible at any window height.
            MacOnboardingStepIndicator(current: step)
                .padding(.top, 26)
                .padding(.bottom, 6)

            // Only the middle step content scrolls; the dots (above) and action bar
            // (below) are pinned OUTSIDE the scroll so they stay on-screen no matter
            // how short the window is — the fix for when a window shorter than
            // the content clipped the fixed top/bottom chrome. The content is centered
            // when it fits (`minHeight: geo.height`) and scrolls only when it's taller
            // than the region (large app-text size, a short display, or a window macOS
            // clamped below the content min); `.basedOnSize` suppresses the scroller
            // while it fits. Wrapping the content in a ScrollView is safe now: the old
            // scroller-flash came from a crossfade that briefly mounted two step frames
            // — `advance()` swaps instantly today, so only one is ever live.
            GeometryReader { geo in
                ScrollView(.vertical) {
                    stepContent
                        .padding(.horizontal, 40)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .frame(minHeight: geo.size.height, alignment: .center)
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            // Pinned bottom chrome — the Back / primary action bar is always reachable.
            Divider()
            actionBar
                .padding(.horizontal, 30)
                .padding(.vertical, 14)
        }
        // Open at 600 (every step fits at the default text size) via `idealHeight`,
        // but floor low enough that on a short display or at a large app-text size
        // the window can shrink and the middle scrolls rather than clipping the
        // pinned chrome. `.windowResizability(.contentMinSize)` (OpenCaptionsApp)
        // enforces this floor and opens the window at the 600 ideal.
        .frame(minWidth: 500, minHeight: 400, idealHeight: 600)
    }

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:
            MacOnboardingWelcomeStep()
        case .mode:
            MacOnboardingModeStep(mode: $mode)
        case .download:
            MacOnboardingDownloadStep()
        case .capture:
            MacOnboardingCaptureStep(source: $source)
        case .permissions:
            MacOnboardingPermissionsStep(
                source: source, micGranted: $micGranted, systemAudioPrimed: $systemAudioPrimed
            )
        case .ready:
            MacOnboardingReadyStep(mode: mode ?? .cloud, source: source)
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack {
            if showsBack {
                Button("Back", action: back)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
            Spacer()
            Button(action: primaryAction) {
                Text(primaryTitle)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 8)
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(!primaryEnabled)
        }
    }

    private var showsBack: Bool { step != .welcome }

    private var primaryTitle: String {
        switch step {
        case .welcome: return "Get Started"
        case .ready: return "Start Transcribing"
        default: return "Continue"
        }
    }

    private var primaryEnabled: Bool {
        switch step {
        case .mode: return mode != nil
        case .download: return modelsReady
        default: return true
        }
    }

    // MARK: - Navigation

    private func primaryAction() {
        if step == .ready { complete() } else { advance() }
    }

    /// Advances to the next step, skipping `.download` entirely for the cloud
    /// path — cloud needs no extra setup before Capture.
    private func advance() {
        guard var next = step.next else { return }
        if next == .download, mode == .cloud { next = next.next ?? next }
        // Instant swap (no crossfade) — the progress dots animate on their own.
        step = next
    }

    private func back() {
        guard var previous = step.previous else { return }
        if previous == .download, mode == .cloud { previous = previous.previous ?? previous }
        guard previous >= .welcome else { return }
        step = previous
    }

    /// Persists the capture choice and chosen mode, then marks onboarding
    /// complete. Writing the gate flag flips the app gate (`OpenCaptionsApp`)
    /// to the main UI. Onboarding's Mode step stays a binary cloud/offline
    /// choice — offline maps to Nemotron, the same on-device engine the old
    /// binary Offline Mode toggle ran live; Parakeet remains selectable only
    /// from the full three-way picker in Settings → General.
    private func complete() {
        UserDefaults.standard.set(source.rawValue, forKey: LiveSessionStore.audioSourceKey)
        let kind: MacTranscriptionEngineKind = mode == .offline ? .nemotron : .soniox
        UserDefaults.standard.set(kind.rawValue, forKey: LiveSessionStore.transcriptionEngineKindKey)
        UserDefaults.standard.set(true, forKey: LiveSessionStore.hasCompletedOnboardingKey)
    }
}

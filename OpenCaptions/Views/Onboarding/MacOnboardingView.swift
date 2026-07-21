//
//  MacOnboardingView.swift
//  OgmoMac
//
//  First-run setup assistant, shown by the app gate until onboarding is complete.
//  A single-card wizard: a progress-dot header, the current step's content, and a
//  Back / primary action bar. Steps: Welcome → Mode → { Sign in | Download } →
//  Capture → Permissions → Ready.
//
//  The Mode step forks the flow: the cloud path signs in (and auto-advances once
//  `auth.isSignedIn` flips), the offline path downloads the on-device model. On
//  finish, `completeOnboarding` records the mode and the app gate swaps in the
//  main UI. A returning, already-onboarded user who signs in here is routed
//  straight into the app by the gate instead. See docs/2026-07-11-macos-onboarding.md.
//

import SwiftUI

struct MacOnboardingView: View {
    @Environment(MacAuthManager.self) private var auth

    @State private var step: OnboardingStep
    @State private var mode: OnboardingMode?
    @State private var source: AudioSource = .microphone
    @State private var micGranted = false
    @State private var systemAudioPrimed = false

    /// Where the flow starts and how far Back can rewind. A user who is already
    /// signed in (but hasn't finished onboarding) skips Welcome/Mode/Sign-in and
    /// starts — and floors Back — at Capture.
    private let startedSignedIn: Bool

    init() {
        let signedIn = MacAuthManager.shared.isSignedIn
        startedSignedIn = signedIn
        _step = State(initialValue: signedIn ? .capture : .welcome)
        _mode = State(initialValue: signedIn ? .cloud : nil)
    }

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
            // how short the window is — the fix for #312, where a window shorter than
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
        // Open at 600 (every step fits at the default text size — the Sign-in step is
        // the tallest) via `idealHeight`, but floor low enough that on a short display
        // or at a large app-text size the window can shrink and the middle scrolls
        // rather than clipping the pinned chrome. `.windowResizability(.contentMinSize)`
        // (OgmoMacApp) enforces this floor and opens the window at the 600 ideal.
        .frame(minWidth: 500, minHeight: 400, idealHeight: 600)
        // Advance off the cloud Sign-in step once signed in. Triggered on BOTH the
        // sign-in edge (sign-in resolved while on .setup) AND arrival at .setup
        // (user reached it already signed in — e.g. after backing out mid-request).
        // The cloud setup step has no manual Continue, so this is the only way
        // forward; checking arrival too prevents a race from stranding the user.
        .onChange(of: auth.isSignedIn) { _, _ in advancePastSignInIfNeeded() }
        .onChange(of: step) { _, _ in advancePastSignInIfNeeded() }
    }

    private func advancePastSignInIfNeeded() {
        if step == .setup, mode != .offline, auth.isSignedIn { advance() }
    }

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:
            MacOnboardingWelcomeStep()
        case .mode:
            MacOnboardingModeStep(mode: $mode)
        case .setup:
            if mode == .offline {
                MacOnboardingDownloadStep()
            } else {
                MacOnboardingSignInStep()
            }
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
            if showsPrimary {
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
    }

    private var backFloor: OnboardingStep { startedSignedIn || auth.isSignedIn ? .capture : .welcome }
    private var showsBack: Bool { step > backFloor }

    /// The cloud Sign-in step has no manual Continue — signing in advances the flow.
    private var showsPrimary: Bool { !(step == .setup && mode != .offline) }

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
        case .setup: return mode == .offline ? modelsReady : true
        default: return true
        }
    }

    // MARK: - Navigation

    private func primaryAction() {
        if step == .ready { complete() } else { advance() }
    }

    private func advance() {
        guard let next = step.next else { return }
        // Instant swap (no crossfade) — the progress dots animate on their own.
        step = next
    }

    private func back() {
        guard let previous = step.previous, previous >= backFloor else { return }
        step = previous
    }

    /// Persists the capture choice and records onboarding completion. Writing the
    /// gate flags flips the app gate (`OgmoMacApp`) to the main UI.
    private func complete() {
        UserDefaults.standard.set(source.rawValue, forKey: LiveSessionStore.audioSourceKey)
        auth.completeOnboarding(guest: mode == .offline)
    }
}

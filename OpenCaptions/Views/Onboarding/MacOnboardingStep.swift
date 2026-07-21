//
//  MacOnboardingStep.swift
//  OgmoMac
//
//  The onboarding state machine's step + account-mode types, shared by the
//  coordinator (`MacOnboardingView`) and its step subviews.
//
//  Flow: Welcome → Mode → { Sign in | Download } → Capture → Permissions → Ready.
//  The Mode step forks step 3: the cloud path signs in; the offline path downloads
//  the on-device model. Both rejoin at Capture. See docs/2026-07-11-macos-onboarding.md.
//

import Foundation

/// A single onboarding step, ordered. `setup` is the fork: its content is the
/// sign-in form (cloud) or the model download (offline), chosen at `mode`.
enum OnboardingStep: Int, CaseIterable, Comparable {
    case welcome
    case mode
    case setup
    case capture
    case permissions
    case ready

    static func < (lhs: OnboardingStep, rhs: OnboardingStep) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
}

/// How the user chose to use Ogmo. `nil` until they pick on the Mode step.
enum OnboardingMode: Equatable {
    /// Signed-in cloud transcription (Soniox): synced, diarized, metered minutes.
    case cloud
    /// Local guest, on-device engine (Nemotron): free, private, no account.
    case offline
}

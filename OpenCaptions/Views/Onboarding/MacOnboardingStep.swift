//
//  MacOnboardingStep.swift
//  OpenCaptions
//
//  The onboarding state machine's step + mode types, shared by the
//  coordinator (`MacOnboardingView`) and its step subviews.
//
//  Flow: Welcome → Mode → Download (offline only) → Capture → Permissions →
//  Ready. `.download` is visited only on the offline path — the coordinator
//  skips it entirely for cloud, which needs no extra setup step.
//

import Foundation

/// A single onboarding step, ordered.
enum OnboardingStep: Int, CaseIterable, Comparable {
    case welcome
    case mode
    case download
    case capture
    case permissions
    case ready

    static func < (lhs: OnboardingStep, rhs: OnboardingStep) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
}

/// How the user chose to transcribe. `nil` until they pick on the Mode step.
enum OnboardingMode: Equatable {
    /// Cloud transcription (Soniox): most accurate, speaker labels, needs network.
    case cloud
    /// On-device transcription (Nemotron): private, free, no network, English only.
    case offline
}

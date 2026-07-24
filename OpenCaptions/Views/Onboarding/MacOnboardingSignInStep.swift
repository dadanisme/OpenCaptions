//
//  MacOnboardingSignInStep.swift
//  OpenCaptions
//
//  Step 3 (cloud path): sign in. Wraps the shared `MacSignInControls`. The
//  coordinator auto-advances when `auth.isSignedIn` flips true — a returning,
//  already-onboarded user is instead whisked straight into the app by the app gate.
//

import SwiftUI

struct MacOnboardingSignInStep: View {
    var body: some View {
        VStack(spacing: 22) {
            MacOnboardingHeader(
                systemImage: "person.crop.circle",
                title: "Sign in to Open Captions",
                subtitle: "Keep your transcripts and minute balance in sync across your Mac and iPhone."
            )
            MacSignInControls()
        }
    }
}

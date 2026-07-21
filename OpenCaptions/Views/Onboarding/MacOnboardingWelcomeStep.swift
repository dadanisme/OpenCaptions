//
//  MacOnboardingWelcomeStep.swift
//  OpenCaptions
//
//  Step 1: the value proposition. A hero header plus three feature highlights.
//

import SwiftUI

struct MacOnboardingWelcomeStep: View {
    var body: some View {
        VStack(spacing: 24) {
            MacOnboardingHeader(
                assetName: "opencaptions-logo",
                title: "Real-time transcription, right on your Mac",
                subtitle: "Open Captions turns anything you hear into clean, searchable text — with speakers, summaries, and action items."
            )

            VStack(alignment: .leading, spacing: 16) {
                feature(
                    "captions.bubble",
                    "Live captions as you speak",
                    "Words appear the instant they're heard, with a floating captions overlay."
                )
                feature(
                    "person.2.wave.2",
                    "Automatic speaker labels",
                    "Know who said what — Open Captions separates voices as they talk."
                )
                feature(
                    "sparkles",
                    "AI summaries & action items",
                    "Every session distills into a summary and a checklist you can act on."
                )
            }
            .frame(maxWidth: 360)
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol)
                .appScaledFont(.body)
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .appScaledFont(.subheadline)
                    .fontWeight(.semibold)
                Text(detail)
                    .appScaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

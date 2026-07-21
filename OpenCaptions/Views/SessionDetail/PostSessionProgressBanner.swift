//
//  PostSessionProgressBanner.swift
//  OpenCaptions
//
//  A slim, NON-blocking status pill shown while a batch pass runs over a session's
//  audio in the background — either a re-transcription (#245) or a file import (#302).
//  Both are `PostSessionProgress`-driven and mutually exclusive for a given session
//  (import blocks re-transcribe), so a single component + a single overlay slot in the
//  detail view render whichever is in flight. The user can keep reading/scrolling — or
//  leave the window — while the work continues (it's owned by an app-lifetime manager,
//  not this view). Docked as a top overlay.
//

import SwiftUI

struct PostSessionProgressBanner: View {
    /// Which batch pass this pill represents (drives the wording + optional file prefix).
    enum Kind {
        case retranscribe
        case importFile(name: String)
    }

    let kind: Kind
    let progress: PostSessionProgress
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(label)
                .appScaledFont(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button("Cancel", action: onCancel)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        // Liquid Glass to match the audio player pill (falls back to material on
        // older macOS inside the helper).
        .liquidGlassBackground(in: Capsule())
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    /// "[file — ]<stage> NN%" with the file prefix for imports and an optional
    /// percentage when the engine reports one.
    private var label: String {
        let pct = progress.fraction.map { " \(Int(($0 * 100).rounded()))%" } ?? ""
        return prefix + stageText + pct
    }

    private var prefix: String {
        if case .importFile(let name) = kind { return "\(name) — " }
        return ""
    }

    private var isImport: Bool {
        if case .importFile = kind { return true }
        return false
    }

    private var stageText: String {
        switch progress.stage {
        case .preparing: return isImport ? "Preparing audio…" : "Preparing re-transcription…"
        case .uploading: return "Uploading audio…"
        case .transcribing: return isImport ? "Transcribing…" : "Re-transcribing…"
        case .downloading: return "Downloading transcript…"
        case .finalizing: return "Finalizing transcript & summary…"
        }
    }
}

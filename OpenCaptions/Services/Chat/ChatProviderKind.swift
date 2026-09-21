//
//  ChatProviderKind.swift
//  OpenCaptions
//
//  The Chat provider selection — cloud OpenRouter or on-device Apple Foundation
//  Models (macOS 26+). Mirrors `SummaryProviderKind`'s shape and availability-gate
//  logic exactly.
//
//  Kept as its own type rather than reusing `SummaryProviderKind` because the two
//  pickers are independent settings: which model summarizes a session has no
//  bearing on which model answers questions about it — the same reasoning that
//  already separates the Summary Model from the Transcription Engine. Chat's
//  on-device window fills far faster than a one-shot summary's (the transcript
//  PLUS the whole growing conversation is resent every turn), so a user who is
//  happy summarizing on-device may still want Chat on OpenRouter, or vice versa.
//  See `LiveSessionStore+ChatProvider.swift` and Settings → AI Models → Chat Model.
//

import FoundationModels

/// A user-selectable Chat provider on macOS.
enum ChatProviderKind: String, CaseIterable, Identifiable {
    case openRouter
    case foundationModels

    var id: String { rawValue }

    /// Label for the Settings picker.
    var displayName: String {
        switch self {
        case .openRouter: return "OpenRouter (Cloud)"
        case .foundationModels: return "Apple Intelligence (On-device)"
        }
    }

    var isOnDevice: Bool { self == .foundationModels }

    /// Whether this provider can run right now. OpenRouter has no static gate — a
    /// missing key or network failure surfaces as a runtime `SessionChatError`, so
    /// there's nothing to check ahead of time. Foundation Models needs macOS 26+ and
    /// Apple Intelligence enabled for this Mac.
    var isAvailable: Bool {
        switch self {
        case .openRouter:
            return true
        case .foundationModels:
            guard #available(macOS 26, *) else { return false }
            return SystemLanguageModel.default.isAvailable
        }
    }

    /// User-facing reason `.foundationModels` can't run right now; `nil` when it can
    /// (or for `.openRouter`, which has no static gate to explain).
    var unavailableReason: String? {
        guard self == .foundationModels else { return nil }
        guard #available(macOS 26, *) else { return "Requires macOS 26 or later." }
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "This Mac doesn't support Apple Intelligence."
            case .appleIntelligenceNotEnabled:
                return "Turn on Apple Intelligence in System Settings → Apple Intelligence & Siri."
            case .modelNotReady:
                return "The on-device model is still downloading — try again shortly."
            @unknown default:
                return "Apple Intelligence isn't available right now."
            }
        }
    }
}

//
//  SummaryProviderKind.swift
//  OpenCaptions
//
//  The two-way summary provider selection — cloud OpenRouter or on-device Apple
//  Foundation Models (macOS 26+). Mirrors `MacTranscriptionEngineKind`'s shape, but
//  there's no model download here: Apple Intelligence's own model is managed entirely
//  by the OS, so `.foundationModels` only ever needs an availability CHECK, never a
//  download control. See docs/2026-08-12-macos-foundation-models-summaries.md.
//

import FoundationModels

/// A user-selectable summary provider on macOS.
enum SummaryProviderKind: String, CaseIterable, Identifiable {
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
    /// missing key or network failure surfaces as a runtime `SessionSummaryError`
    /// exactly as it does today, so there's nothing to check ahead of time. Foundation
    /// Models needs macOS 26+ and Apple Intelligence enabled for this Mac.
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

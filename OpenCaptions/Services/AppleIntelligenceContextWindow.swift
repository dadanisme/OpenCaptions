//
//  AppleIntelligenceContextWindow.swift
//  OpenCaptions
//
//  Shared context-window-exceeded detection for every Apple Intelligence
//  transport: `SummaryService+FoundationModels` (a one-shot structured summary)
//  and `SessionChatService+FoundationModels` (a growing multi-turn conversation).
//  Both drive the same `LanguageModelSession` machinery and so hit the identical
//  overflow failure mode — extracted here when Chat arrived rather than forked a
//  second time. See docs/2026-09-16-macos-session-chat.md.
//

import Foundation
import FoundationModels

@available(macOS 26, *)
enum AppleIntelligenceContextWindow {

    /// Checks both eras of the framework's context-overflow error: `LanguageModelError`
    /// (macOS 27+) and the `LanguageModelSession.GenerationError` it superseded. The
    /// latter is still what an exact-macOS-26 runtime throws — `LanguageModelError`
    /// itself didn't exist before 27 — so it has to stay checked as long as any
    /// caller's own floor is macOS 26, not 27.
    static func isExceeded(_ error: Error) -> Bool {
        if #available(macOS 27, *), let languageModelError = error as? LanguageModelError,
           case .contextSizeExceeded = languageModelError {
            return true
        }
        return isLegacyExceeded(error)
    }

    /// Isolates the one intentionally-deprecated reference in this file: checked only
    /// because `LanguageModelSession.GenerationError` — deprecated in macOS 27 in favor
    /// of `LanguageModelError` — is still the only type an exact-macOS-26 runtime can
    /// throw for this. Marking this function itself deprecated for the same version
    /// suppresses the warning that referencing it would otherwise raise.
    @available(macOS, deprecated: 27.0, message: "Intentionally still checked — see call site.")
    private static func isLegacyExceeded(_ error: Error) -> Bool {
        guard let generationError = error as? LanguageModelSession.GenerationError else { return false }
        if case .exceededContextWindowSize = generationError { return true }
        return false
    }

    /// A user-facing "how big was this" detail for a context-exceeded error, e.g.
    /// "5,412 tokens, over the 4,096-token on-device limit". Two sources, in
    /// preference order:
    ///
    /// 1. **macOS 27+**: `LanguageModelError.contextSizeExceeded` already carries the
    ///    exact measured `tokenCount` and `contextSize` for the attempt that just
    ///    failed — no extra work needed.
    /// 2. **macOS 26.4–26.x**: the deprecated `GenerationError` this OS range throws
    ///    instead carries no structured numbers (just a debug string), so this
    ///    independently measures `text` alone via the model's own tokenizer
    ///    (`SystemLanguageModel.tokenCount(for:)`, itself only available from 26.4).
    ///    No `contextSize` to report here — only the measured text's own count.
    ///
    /// Below macOS 26.4, neither source exists; callers get `nil` and fall back to
    /// the plain, count-less copy.
    static func overflowDetail(for error: Error, text: String) async -> String? {
        if #available(macOS 27, *), let languageModelError = error as? LanguageModelError,
           case .contextSizeExceeded(let details) = languageModelError {
            return "\(details.tokenCount.formatted()) tokens, over the \(details.contextSize.formatted())-token on-device limit"
        }
        guard #available(macOS 26.4, *) else { return nil }
        guard let tokenCount = try? await SystemLanguageModel.default.tokenCount(for: text) else { return nil }
        return "\(tokenCount.formatted()) tokens in this session"
    }
}

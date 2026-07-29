//
//  MacNameMentionNotifier.swift
//  OpenCaptions
//
//  Alerts the signed-in user when their name is spoken in a live transcription.
//  This is net-new product surface: beyond highlighting the name, it raises a
//  notification.
//
//  Focus-gated hybrid: when Open Captions is the frontmost app the user is looking at the
//  transcript, so a transient in-app HUD badge (the same overlay the hotkeys use)
//  is enough; when Open Captions is backgrounded, a macOS local notification reaches them in
//  whatever app they're in. Fires only on FINALIZED text (never the noisy partial)
//  and debounces so a name repeated in quick succession doesn't spam.
//
//  The live path commits one token at a time, so this keeps a short rolling window of
//  recently finalized text and matches against that — a name split across tokens
//  ("Muhammad" + " Ramdan") still triggers, which a per-token match would miss.
//
//  Detection reuses `NameMentionMatcher` (the same whole-word matcher backing the
//  transcript highlight), so what gets highlighted and what triggers an alert can
//  never drift apart. Local notifications need no entitlement and no Info.plist
//  usage string under the App Sandbox.
//
//  Notification permission is requested lazily, ONLY when a mention actually needs
//  an OS notification (a real mention while backgrounded) — never eagerly, so an
//  offline guest (no name) or a user whose name is never spoken is never prompted,
//  and the frontmost HUD path needs no permission at all.
//

import AppKit
import Foundation
import UserNotifications

@MainActor
final class MacNameMentionNotifier {
    static let shared = MacNameMentionNotifier()
    private init() {}

    /// Its own HUD overlay, independent of the hotkey manager's — they show at
    /// different times, and the badge panel is cheap.
    private let hud = MacHUDOverlayController()

    /// Minimum gap between two alerts. A name mentioned repeatedly (e.g. a back-and-
    /// forth where the user is addressed several times) alerts at most once per window.
    private let debounceInterval: CFAbsoluteTime = 5

    private var lastFiredAt: CFAbsoluteTime = 0
    /// The session generation currently tracked. A change means a new recording
    /// started, so the debounce clock resets (the first mention of a session always
    /// alerts). `MacTranscriptionViewModel.serviceGeneration` supplies it.
    private var trackedGeneration = -1

    /// Recently finalized text, so a name spread over consecutive tokens still
    /// matches. Bounded to `windowLimit` characters and cleared whenever a mention is
    /// detected — including one the debounce suppresses — so a matched name can never
    /// re-trigger from stale text once the debounce window elapses.
    private var window = ""
    private let windowLimit = 240

    /// Compiled matcher for the current display name (see `mentionsName`).
    private var cachedRegex: NSRegularExpression?
    private var cachedRegexName: String?

    /// Handles one fragment of finalized transcript text (a token, a sentence, or the
    /// tail committed at stop). Fires an alert when the rolling window mentions the
    /// signed-in user's name. No-op for an offline guest (nil name).
    func handle(finalizedFragment text: String, sessionGeneration: Int) {
        // New session → reset the window and debounce clock so the first mention
        // always alerts and no text carries over from the previous recording.
        if sessionGeneration != trackedGeneration {
            trackedGeneration = sessionGeneration
            lastFiredAt = 0
            window = ""
        }

        window += text
        if window.count > windowLimit {
            window = String(window.suffix(windowLimit))
            // The cut lands at an arbitrary offset, and a regex `\b` matches at the
            // START of the searched string — so "…Ramdan" trimmed to "dan …" would
            // alert a user named Dan. Drop the partial leading word so only whole
            // spoken words can match. (Spaceless scripts have no such boundary; they
            // keep the raw suffix, where `\b` semantics don't apply anyway.)
            if let firstSpace = window.firstIndex(where: { $0.isWhitespace }) {
                window = String(window[firstSpace...])
            }
        }

        guard let name = MacAuthManager.shared.userName,
              mentionsName(name, in: window) else { return }

        // Consume the match either way: alerting again for the same words after the
        // debounce elapsed would be a false second mention.
        window = ""

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastFiredAt >= debounceInterval else { return }
        lastFiredAt = now

        // Frontmost → the user sees the transcript; a transient badge suffices.
        // Backgrounded → reach them where they are with an OS notification.
        if NSApp.isActive {
            hud.show(symbol: "at.circle.fill", message: "You were mentioned")
        } else {
            postLocalNotification()
        }
    }

    /// Whole-word match against the rolling window, reusing one compiled regex per
    /// name — this runs once per finalized token now, not once per sentence, so
    /// recompiling the pattern each time would be pure waste. Pattern construction
    /// still comes from `NameMentionMatcher`, the single source of truth.
    private func mentionsName(_ name: String, in text: String) -> Bool {
        if cachedRegexName != name {
            cachedRegexName = name
            cachedRegex = NameMentionMatcher.regex(for: name)
        }
        guard let regex = cachedRegex else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    private func postLocalNotification() {
        Task {
            let center = UNUserNotificationCenter.current()
            // Request-then-post: `requestAuthorization` is idempotent and resolves to
            // the FINAL decision (waiting for the user's answer if the one-time prompt
            // is still up), so the very first backgrounded mention posts once granted
            // instead of racing a settings read that would see `.notDetermined` and
            // silently drop it. Asked only here — on a real backgrounded mention.
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = "You were mentioned"
            // Deliberately no transcript text — the sentence could be sensitive and
            // would surface on the Lock Screen / Notification Center.
            content.body = "Your name was spoken in the transcription."
            content.sound = .default

            // Immediate (nil trigger); a fresh id per alert so successive mentions
            // don't overwrite/coalesce into one.
            let request = UNNotificationRequest(
                identifier: "name-mention-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }
}

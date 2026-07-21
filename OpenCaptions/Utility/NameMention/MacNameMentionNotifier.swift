//
//  MacNameMentionNotifier.swift
//  OgmoMac
//
//  Alerts the signed-in user when their name is spoken in a live transcription
//  (issue #255). This is net-new product surface — iOS only *highlights* the name,
//  it never notifies.
//
//  Focus-gated hybrid: when Ogmo is the frontmost app the user is looking at the
//  transcript, so a transient in-app HUD badge (the same overlay the hotkeys use)
//  is enough; when Ogmo is backgrounded, a macOS local notification reaches them in
//  whatever app they're in. Fires only on FINALIZED sentences (never the noisy
//  partial) and debounces so a name repeated in quick succession doesn't spam.
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

    /// Handles one finalized transcript sentence. Fires an alert when the sentence
    /// mentions the signed-in user's name. No-op for an offline guest (nil name).
    func handle(finalizedLine text: String, sessionGeneration: Int) {
        // New session → reset the debounce clock so the first mention always alerts.
        if sessionGeneration != trackedGeneration {
            trackedGeneration = sessionGeneration
            lastFiredAt = 0
        }

        guard let name = MacAuthManager.shared.userName,
              NameMentionMatcher.containsMention(of: name, in: text) else { return }

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

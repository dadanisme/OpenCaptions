//
//  HotKeyManager.swift
//  OpenCaptions
//
//  App-level owner of the system-wide transcription hotkeys. Loads
//  and persists per-action bindings, registers them with Carbon (see
//  `HotKeyManager+Carbon`), and dispatches each press to a state-respecting
//  operation on `LiveSessionStore` — then shows a brief HUD confirming what
//  happened. Because it drives `LiveSessionStore` (which owns the session
//  independently of any window), the hotkeys work while Open Captions is in the
//  background or its window is closed.
//
//  `@Observable @MainActor` singleton (the `MacAuthManager`/`MenuBarState`
//  pattern) so the Settings pane reflects edits live. Carbon delivers hotkey
//  events on the main thread, so all handling stays on the main actor.
//

import AppKit
import Carbon.HIToolbox
import Observation

@Observable
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()
    private init() {}

    /// Current binding per action — the source of truth. Observable so the
    /// Settings pane re-renders on edits.
    private(set) var bindings: [HotKeyAction: HotKeyBinding] = [:]

    /// Per-action reason a binding is NOT currently active (missing modifier,
    /// duplicate, or OS-refused). Surfaced by the Settings pane; recomputed on
    /// every (re)registration in `reregisterAll()` — which lives in the Carbon
    /// extension file, so this can't be `private(set)`. Written only there.
    var issues: [HotKeyAction: HotKeyIssue] = [:]

    /// Live Carbon registrations, keyed by action. Raw refs aren't UI state.
    @ObservationIgnored var registrations: [HotKeyAction: EventHotKeyRef] = [:]
    /// The single installed Carbon event handler (nil until `start()`).
    @ObservationIgnored var eventHandler: EventHandlerRef?

    /// HUD shown on each press. Owned here so it outlives any window.
    @ObservationIgnored private let hud = MacHUDOverlayController()

    @ObservationIgnored private var isStarted = false

    // MARK: - Lifecycle

    /// Loads persisted bindings, installs the Carbon handler, and registers every
    /// hotkey. Idempotent — safe to call from the app's re-running launch task.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        loadBindings()
        installEventHandler()
        reregisterAll()
    }

    // MARK: - Bindings

    /// The binding for an action, falling back to its default if unset.
    func binding(for action: HotKeyAction) -> HotKeyBinding {
        bindings[action] ?? action.defaultBinding
    }

    /// Updates one action's binding, persists it, and re-registers everything so
    /// validity/duplicate state (`issues`) recomputes across the whole set.
    func setBinding(_ binding: HotKeyBinding, for action: HotKeyAction) {
        bindings[action] = binding
        persist(binding, for: action)
        reregisterAll()
    }

    /// Restores every action to its default chord.
    func resetToDefaults() {
        for action in HotKeyAction.allCases {
            bindings[action] = action.defaultBinding
            persist(action.defaultBinding, for: action)
        }
        reregisterAll()
    }

    private func loadBindings() {
        for action in HotKeyAction.allCases {
            if let data = UserDefaults.standard.data(forKey: action.defaultsKey),
               let decoded = try? JSONDecoder().decode(HotKeyBinding.self, from: data) {
                bindings[action] = decoded
            } else {
                bindings[action] = action.defaultBinding
            }
        }
    }

    private func persist(_ binding: HotKeyBinding, for action: HotKeyAction) {
        guard let data = try? JSONEncoder().encode(binding) else { return }
        UserDefaults.standard.set(data, forKey: action.defaultsKey)
    }

    // MARK: - Dispatch

    /// Called from the Carbon handler (on the main thread) with the fired
    /// hotkey's id; resolves it to an action and performs it.
    func handleHotKey(id: UInt32) {
        guard let action = HotKeyAction.allCases.first(where: { $0.hotKeyID == id }) else { return }
        perform(action)
    }

    /// Runs a toggle action against the current session state. Every branch shows
    /// a HUD — a confirmation for a real change, or a muted note for a no-op /
    /// failure — so a background press always gives honest feedback.
    func perform(_ action: HotKeyAction) {
        let store = LiveSessionStore.shared
        switch action {
        case .toggleRecording:
            if store.isActive {
                // A session exists (recording, paused, or failed-with-kept
                // transcript): Stop & Save it.
                hud.show(.recordingStopped)
                Task { await store.endFromMenuBar() }
            } else {
                startRecording(store)
            }

        case .togglePause:
            guard let vm = store.viewModel else { hud.show(.noSession); return }
            if vm.isPaused {
                // Report the REAL outcome: resume can fail the session if the
                // socket died during the pause (dead socket / mic-resume error).
                Task { hud.show(await store.resume() ? .recordingResumed : .resumeFailed) }
            } else {
                // store.pause() reflects what the VM actually did — it no-ops
                // during the pre-connect window, where this shows the muted note.
                guard store.pause() else { hud.show(.notRecording); return }
                hud.show(.recordingPaused)
            }

        case .toggleCaptions:
            guard store.isActive else { hud.show(.noSession); return }
            store.toggleCaptions()
            hud.show(store.captionsVisible ? .captionsShown : .captionsHidden)
        }
    }

    /// Starts a headless recording, or — when it can't proceed headlessly (signed
    /// out, or a denied mic that needs the window's permission UI) — raises the app.
    private func startRecording(_ store: LiveSessionStore) {
        // Recording needs an account OR a completed offline guest — a not-yet-
        // onboarded user is sent to the window (onboarding) instead.
        guard MacAuthManager.shared.isSignedIn || MacAuthManager.shared.isGuest else {
            hud.show(.signInRequired); raiseApp(); return
        }
        Task {
            if await store.startHeadlessRecording() {
                hud.show(.recordingStarted)
            } else if store.pendingPaywall {
                // Blocked on an empty minute balance, not a permission problem —
                // startHeadlessRecording already raised the window for the paywall.
                hud.show(.outOfMinutes)
                raiseApp()
            } else {
                hud.show(.permissionNeeded)
                raiseAppForPermission()
            }
        }
    }

    // MARK: - App raise (Start fallback)

    /// Brings Open Captions forward and opens its window (reopening if closed).
    private func raiseApp() {
        NSApplication.shared.activate()
        LiveSessionStore.shared.openMainWindow?()
    }

    /// Start needs permission UI we can't show headlessly (mic denied): bring the
    /// app forward and queue a start so the list screen shows the prompt on appear.
    private func raiseAppForPermission() {
        MenuBarState.shared.pendingStartRequest = true
        raiseApp()
    }
}

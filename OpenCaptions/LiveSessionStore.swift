//
//  LiveSessionStore.swift
//  OgmoMac
//
//  App-level owner of the ACTIVE transcription session. The recording view model
//  used to live as `@State` inside `MacLiveTranscriptionView`, so closing the
//  main window destroyed it (and `onDisappear` discarded the session). This
//  singleton hoists that ownership above the window: the session — audio capture,
//  Soniox socket, transcript — keeps running with the window closed, and a
//  reopened window rebinds to it instead of starting fresh.
//
//  It also owns the two things that must outlive the window with the session: the
//  floating captions overlay, and the menu-bar transport wiring (`MenuBarState`)
//  so Pause / End / Captions keep working from the status-bar item while the
//  window is closed. Status is mirrored into `MenuBarState` via an observation
//  loop so the menu-bar label stays correct without an on-screen view.
//
//  Mirrors the shared `@Observable @MainActor` singleton pattern of
//  `MacAuthManager` / `MenuBarState`.
//

import Foundation
import Observation
import SwiftData

@Observable
@MainActor
final class LiveSessionStore {
    static let shared = LiveSessionStore()
    private init() {}

    /// UserDefaults key for the "show captions overlay when recording starts"
    /// preference. Shared with `MacSettingsView`'s `@AppStorage` toggle.
    static let captionsAutoShowKey = "ogmo.captionsOverlay.autoShow"

    /// UserDefaults key for the persisted capture source. Mirrors the
    /// `@AppStorage("ogmo.audioSource")` in `MacLiveTranscriptionView` so the
    /// menu-bar quick start reads the same choice the live screen writes.
    static let audioSourceKey = "ogmo.audioSource"

    /// UserDefaults key for the overlay's background opacity (0…1). Applied to the
    /// material fallback on macOS < 26; ignored when Liquid Glass is used. Shared
    /// between `MacSettingsView` and `CaptionsOverlayView`.
    static let captionsOpacityKey = "ogmo.captionsOverlay.backgroundOpacity"

    /// UserDefaults key for the transcript font-size MULTIPLIER (see
    /// `TranscriptTextSize`). Shared by every surface that reads or scales the
    /// transcript — the in-window live view, the captions overlay, the transport
    /// pill's slider, the menu-bar picker, and Settings — so a change from any one
    /// reflects everywhere live. Default is `1.0` (registered in `OgmoMacApp`).
    static let transcriptTextSizeKey = "ogmo.transcript.textSizeMultiplier"

    /// UserDefaults key for the APP-WIDE UI font-size MULTIPLIER (see
    /// `AppTextSize.swift`). Deliberately SEPARATE from `transcriptTextSizeKey` so
    /// the general chrome and the transcript/captions scale independently — changing
    /// one never affects the other. Read reactively by `.appTextScaling()` and bound
    /// to Settings' General slider. Reuses `TranscriptTextSize.range/.step`; default
    /// is `1.0` (registered in `OgmoMacApp`). Issue #270.
    static let appTextSizeKey = "ogmo.app.textSizeMultiplier"

    /// UserDefaults key for the "save session audio for playback" preference.
    /// Read at record time by `MacTranscriptionViewModel.start` (via a raw
    /// `UserDefaults.standard.bool` lookup) and bound to `MacSettingsView`'s
    /// `@AppStorage` toggle. Default is `true` (registered in `OgmoMacApp`).
    static let sessionAudioKey = "ogmo.sessionAudio.save"

    /// UserDefaults key (Bool) for AUTOMATIC re-transcription after a recording is
    /// saved (#245). When on, the just-saved session is re-processed automatically; the
    /// engine FOLLOWS Offline Mode (Parakeet offline / Soniox cloud) — there's no engine
    /// choice. Bound to `MacSettingsView`'s toggle and read by `RetranscriptionManager`.
    /// Only takes effect while the `postSessionRetranscription` remote flag is on. The
    /// MANUAL re-transcribe menu is independent — gated by the remote flag alone. Default
    /// `false` (registered in `OgmoMacApp`).
    static let retranscriptionAutoKey = "ogmo.retranscription.auto"

    /// UserDefaults key for the Offline Mode toggle (Bool). Off → Soniox (cloud);
    /// on → on-device Nemotron transcription with no network. Read at session start
    /// by `MacTranscriptionViewModel.start` and by `MacSessionDetailView` to gate
    /// cloud summary generation. Bound to the toggle in Settings → Recording.
    /// Default `false` (registered in `OgmoMacApp`). Issue #274.
    static let offlineModeKey = "ogmo.offlineMode.enabled"

    /// UserDefaults key (Bool) for the global "finished onboarding" gate flag. The
    /// app gate (`OgmoMacApp`) shows the main UI only when this is set AND the user
    /// is either signed in or a local guest. Written by `completeOnboarding` and
    /// mirrored from the per-owner key on sign-in (see `MacAuthManager+Onboarding`).
    /// Mirrors the iOS `"hasCompletedOnboarding"` convention.
    static let hasCompletedOnboardingKey = "hasCompletedOnboarding"

    /// UserDefaults key (Bool) marking a "use without an account" local guest: a
    /// user who finished onboarding via the offline path. Distinguishes a deliberate
    /// offline guest (enter the app) from a signed-out/expired cloud user (must
    /// re-authenticate). Cleared on any real sign-in. Guests are force-locked to the
    /// on-device engine. See `docs/2026-07-11-macos-onboarding.md`.
    static let guestModeKey = "ogmo.guestMode"

    /// The active session's view model, or nil when idle. Non-nil is the single
    /// source of truth for "a session is live" (running, paused, or failed with a
    /// kept transcript) — it drives whether the window shows the live screen.
    private(set) var viewModel: MacTranscriptionViewModel?

    /// Whether the floating captions overlay is currently shown. Observable so the
    /// menu command's Show/Hide label tracks it.
    private(set) var captionsVisible = false

    /// Set true when a metered (cloud) recording is blocked for want of a minute
    /// balance — by either the in-window Record action or the headless menu-bar
    /// start. `TranscriptionsScreen` presents the paywall for it and resets it.
    var pendingPaywall = false

    /// True while a session exists (used to gate reopen-time reconcile + new-record).
    var isActive: Bool { viewModel != nil }

    /// The floating captions panel. Window-independent so it stays up while the
    /// main window is closed.
    @ObservationIgnored private let captions = CaptionsOverlayController()

    /// The app's shared SwiftData container, stashed at launch (see
    /// `OgmoMacApp`). Lets the store start a recording from the menu-bar item
    /// without an on-screen view to supply `modelContext.container`.
    @ObservationIgnored var modelContainer: ModelContainer?

    /// Opens (or refocuses) the main window. Stashed once at launch from the
    /// app's root scene — the only place `@Environment(\.openWindow)` is
    /// available — so non-view code (the global-hotkey Start fallback, which must
    /// raise the mic-permission UI) can bring the window back even when it's
    /// closed. See `OgmoMacApp`.
    @ObservationIgnored var openMainWindow: (() -> Void)?

    /// Process-activity assertion held for the duration of a live session
    /// (recording OR paused) so recording keeps running when the Mac would
    /// otherwise idle. `.userInitiated` does two things: (1) keeps the app out of
    /// macOS **App Nap** — when the window is backgrounded/occluded, App Nap
    /// coalesces `RunLoop.main` timers by tens of seconds, pushing the
    /// paused-session 15 s Soniox keepalive (`OnlineTranscriberService.startKeepalive`)
    /// past the server's ~20 s idle timeout and dropping the socket (this target has
    /// no reconnection, so the session then fails on `resume()`); and (2) disables
    /// **idle system sleep**, so a recording continues when the user steps away (the
    /// display can still turn off — only the *system* stays awake). It does NOT
    /// override lid-close (clamshell) sleep, which still stops a laptop recording.
    /// Managed only through `updateBackgroundActivity()`.
    /// See docs/2026-07-09-macos-app-nap-keepalive.md.
    @ObservationIgnored private var backgroundActivity: NSObjectProtocol?

    // MARK: - Session lifecycle

    /// Creates and installs a fresh session view model, wires the menu-bar
    /// transport to it, begins mirroring its status, and shows the captions
    /// overlay if the user opted in. The caller (the live view) starts capture.
    @discardableResult
    func makeSession() -> MacTranscriptionViewModel {
        let vm = MacTranscriptionViewModel()
        viewModel = vm
        registerMenuBar()
        armStatusMirroring()
        syncStatus()
        if UserDefaults.standard.bool(forKey: Self.captionsAutoShowKey) {
            setCaptions(visible: true, for: vm)
        }
        return vm
    }

    /// Starts a new recording from the menu-bar item WITHOUT needing the main
    /// window on screen — the whole point of the status-bar "New Recording": just
    /// start transcribing, don't also raise the app.
    ///
    /// Returns `true` if capture started headlessly. Returns `false` when the
    /// start needs the window's permission UI — a denied/undetermined-then-denied
    /// mic, or a system-audio source whose Screen Recording grant is missing (its
    /// gating shows an alert). The caller then falls back to opening the window.
    @discardableResult
    func startHeadlessRecording() async -> Bool {
        guard !isActive, let container = modelContainer else { return false }
        // Clear any stale paywall request so it reflects only THIS attempt — otherwise
        // a leftover true (from an earlier block whose paywall was never dismissed)
        // would make a later mic-denied start misreport as "out of minutes".
        pendingPaywall = false

        let source = AudioSource(
            rawValue: UserDefaults.standard.string(forKey: Self.audioSourceKey) ?? ""
        ) ?? .microphone

        // A denied mic has no headless UI to explain itself — defer to the window's
        // mic-denied screen. (A first-time prompt still resolves fine here.)
        if source.requiresMicrophone {
            guard await MacAudioService.requestMicPermission() else { return false }
        }
        // System-audio capture (process tap) has no preflight — the OS shows the
        // "Audio Recording" prompt on the first capture start, so it needs no
        // headless gate here.

        // Gate metered (cloud) recordings on the minute balance. Offline Mode is
        // free. On a block, raise the window + request the paywall (there's no
        // headless purchase UI) and report failure so the caller opens the window.
        let offline = UserDefaults.standard.bool(forKey: Self.offlineModeKey)
        guard await MacSubscriptionManager.shared.canStartSession(metered: !offline) else {
            pendingPaywall = true
            openMainWindow?()
            return false
        }

        let vm = makeSession()
        await vm.start(modelContainer: container, userId: MacAuthManager.shared.ownerId, source: source)
        // start() can early-return without recording — an on-device engine whose model isn't
        // downloaded, or a connection failure — leaving isRunning=false + errorMessage set. Don't
        // claim a headless success: drop the dead session so the caller falls back to opening the
        // window, where the fresh in-window start re-hits the same guard and surfaces the hint.
        guard vm.isRunning else {
            clearSession()
            return false
        }
        return true
    }

    /// Tears down the current session's app-level state: hides the overlay,
    /// clears the menu-bar transport, and drops the view model. Called after the
    /// view (or the menu-bar path) has already stopped/discarded the VM.
    func clearSession() {
        setCaptions(visible: false, for: nil)
        clearMenuBar()
        // Settle billing for a metered session even on an abandon path that skips
        // stop() (e.g. Back after a failure): deduct the minutes used and clear the
        // session-active suppression flag. Idempotent — a prior stop()/discard()
        // already ran endBilling, so this is a no-op then.
        viewModel?.endBilling()
        viewModel = nil
        // Session fully gone — release the App Nap assertion synchronously.
        // Belt-and-suspenders alongside the observation-driven release, which has
        // already fired when stop()/failSession flipped isRunning/isPaused false.
        updateBackgroundActivity()
    }

    /// Tears down any live session synchronously on sign-out, BEFORE the auth cache
    /// is cleared. Without this, the window-independent session keeps running past
    /// sign-out — its 30 s billing checkpoint would re-arm `pending_minutes_to_deduct`
    /// and re-sign-in's balance refresh would flush it against the NEXT user. Discards
    /// (doesn't save) the in-progress transcript — signing out mid-recording abandons
    /// it — while `discard()` → `endBilling()` stops the billing clock and clears the
    /// session-active flag. The caller (`MacAuthManager.signOut`) then clears pending
    /// so the outgoing user's last partial minute isn't charged to the next user
    /// (matches iOS sign-out semantics). #242 review.
    func discardActiveSession() {
        guard let vm = viewModel else { return }
        vm.discard()
        clearSession()
    }

    /// End & Save from the menu-bar item (works while the window is closed). Stops
    /// the VM (which persists the transcript) and clears the session. No detail
    /// navigation — there may be no window; the saved session is in history.
    func endFromMenuBar() async {
        guard let vm = viewModel else { return }
        _ = await vm.stop()
        clearSession()
    }

    /// Pause/resume the live session (menu-bar item). Nil-safe.
    func togglePause() {
        guard let vm = viewModel else { return }
        if vm.isPaused {
            Task { await vm.resume() }
        } else {
            vm.pause()
        }
    }

    /// Pauses the live session, delegating to the view model so the result
    /// reflects what actually happened — `vm.pause()` no-ops during the
    /// pre-connect window (no push task yet), and this propagates that `false` so
    /// the Pause/Resume hotkey shows a no-op note instead of a false "Paused".
    @discardableResult
    func pause() -> Bool {
        guard let vm = viewModel else { return false }
        return vm.pause()
    }

    /// Resumes the live session and reports the REAL outcome: `true` if it's
    /// recording again afterward, `false` if it wasn't paused or the resume
    /// failed the session (e.g. the socket died during the pause). The
    /// Pause/Resume hotkey uses this to confirm honestly.
    @discardableResult
    func resume() async -> Bool {
        guard let vm = viewModel, vm.isPaused else { return false }
        await vm.resume()
        return vm.isRunning
    }

    // MARK: - Audio source

    /// Selects the capture source from the menu-bar item. While a session is
    /// actively capturing (running or paused) this HOT-SWAPS the source (requesting
    /// mic access first if the new source needs it); otherwise it records the choice
    /// as the default the next recording will use. Persistence goes through the
    /// shared `audioSourceKey` — the same key the in-window pill's `@AppStorage`
    /// reads — so both surfaces' selection stays in sync.
    func selectAudioSource(_ source: AudioSource) {
        // Route to a live hot-swap only when a session is genuinely capturing. A
        // view model that exists but is neither running nor paused is a session
        // that FAILED mid-recording yet kept its transcript for Stop & Save (see
        // `failSession`) — treat that like idle and persist the choice as the next
        // recording's default, rather than handing it to `switchAudioSource`, which
        // no-ops when `!isRunning` and would silently drop the selection.
        guard let vm = viewModel, vm.isRunning || vm.isPaused else {
            // Idle (or failed-kept): set the default the next recording uses.
            persistSource(source)
            return
        }
        // Live: gate mic first (a no-op once authorized), then hot-swap. Persist
        // ONLY if the swap actually took effect — during the connect window or a
        // pause `switchAudioSource` no-ops, and committing the key anyway would
        // diverge the picker from the real capture (mirrors the pill's guard).
        if source.requiresMicrophone {
            Task { @MainActor in
                guard await MacAudioService.requestMicPermission() else { return }
                if vm.switchAudioSource(to: source) { persistSource(source) }
            }
        } else if vm.switchAudioSource(to: source) {
            persistSource(source)
        }
    }

    /// Writes the selected source to the shared UserDefaults key. Both the pill's
    /// and the menu bar's `@AppStorage` read this key and re-read it whenever their
    /// view re-evaluates (the menu bar rebuilds its dropdown on every open), so each
    /// surface's checkmark reflects a change made from the other.
    private func persistSource(_ source: AudioSource) {
        UserDefaults.standard.set(source.rawValue, forKey: Self.audioSourceKey)
    }

    // MARK: - Captions overlay

    /// Toggles the captions overlay for the active session.
    func toggleCaptions() {
        guard let vm = viewModel else { return }
        setCaptions(visible: !captionsVisible, for: vm)
    }

    private func setCaptions(visible: Bool, for vm: MacTranscriptionViewModel?) {
        if visible, let vm {
            captions.show(viewModel: vm)
        } else {
            captions.hide()
        }
        captionsVisible = captions.isVisible
        MenuBarState.shared.captionsVisible = captionsVisible
    }

    // MARK: - Menu-bar transport

    private func registerMenuBar() {
        let state = MenuBarState.shared
        state.togglePause = { [weak self] in self?.togglePause() }
        state.endAndSave = { [weak self] in Task { await self?.endFromMenuBar() } }
        state.toggleCaptions = { [weak self] in self?.toggleCaptions() }
    }

    private func clearMenuBar() {
        let state = MenuBarState.shared
        state.togglePause = nil
        state.endAndSave = nil
        state.toggleCaptions = nil
        state.status = .idle
    }

    // MARK: - Status mirroring

    /// Pushes the current running/paused state into `MenuBarState` so the
    /// status-bar label/icon stay correct even with no on-screen view.
    private func syncStatus() {
        let state = MenuBarState.shared
        if let vm = viewModel {
            state.status = vm.isPaused ? .paused : (vm.isRunning ? .recording : .idle)
        } else {
            state.status = .idle
        }
    }

    /// Observes the VM's `isRunning`/`isPaused` and re-arms itself on each change
    /// (the SwiftData/Observation kill-switch pattern from iOS). Stops re-arming
    /// once the session is cleared.
    private func armStatusMirroring() {
        withObservationTracking {
            _ = viewModel?.isRunning
            _ = viewModel?.isPaused
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, self.viewModel != nil else { return }
                self.syncStatus()
                self.updateBackgroundActivity()
                self.armStatusMirroring()
            }
        }
    }

    // MARK: - App Nap suppression

    /// Acquires or releases the process-activity assertion so it is held EXACTLY
    /// while a session is recording or paused, and dropped otherwise. Idempotent,
    /// so it is safe to call from the observation loop (on every isRunning/isPaused
    /// change) and from `clearSession`. Holding it ACROSS a pause is the whole
    /// point: a pause stops audio I/O — the only thing otherwise keeping the app
    /// active — so without this the paused keepalive timer gets App-Napped past
    /// Soniox's idle timeout. Released the instant recording truly ends (including
    /// a `failSession` that keeps the transcript but stops recording), so a
    /// failed-but-unsaved session doesn't hold the assertion.
    private func updateBackgroundActivity() {
        let shouldHold = viewModel?.isRunning == true || viewModel?.isPaused == true
        if shouldHold, backgroundActivity == nil {
            backgroundActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiated,
                reason: "Live transcription in progress"
            )
        } else if !shouldHold, let token = backgroundActivity {
            ProcessInfo.processInfo.endActivity(token)
            backgroundActivity = nil
        }
    }
}

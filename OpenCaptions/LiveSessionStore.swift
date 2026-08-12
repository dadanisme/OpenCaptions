//
//  LiveSessionStore.swift
//  OpenCaptions
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
//  `MenuBarState`.
//

import Foundation
import Observation
import SwiftData

@Observable
@MainActor
final class LiveSessionStore {
    static let shared = LiveSessionStore()
    private init() {}

    /// UserDefaults key for the "show captions overlay when a session starts"
    /// preference. Shared with `MacSettingsView`'s `@AppStorage` toggle.
    static let captionsAutoShowKey = "opencaptions.captionsOverlay.autoShow"

    /// UserDefaults key for the persisted capture source. Mirrors the
    /// `@AppStorage("opencaptions.audioSource")` in `MacLiveTranscriptionView` so the
    /// menu-bar quick start reads the same choice the live screen writes.
    static let audioSourceKey = "opencaptions.audioSource"

    /// UserDefaults key for the overlay's background opacity (0…1). Applied to the
    /// material fallback on macOS < 26; ignored when Liquid Glass is used. Shared
    /// between `MacSettingsView` and `CaptionsOverlayView`.
    static let captionsOpacityKey = "opencaptions.captionsOverlay.backgroundOpacity"

    /// UserDefaults key for the transcript font-size MULTIPLIER (see
    /// `TranscriptTextSize`). Shared by every surface that reads or scales the
    /// transcript — the in-window live view, the captions overlay, the transport
    /// pill's slider, the menu-bar picker, and Settings — so a change from any one
    /// reflects everywhere live. Default is `1.0` (registered in `OpenCaptionsApp`).
    static let transcriptTextSizeKey = "opencaptions.transcript.textSizeMultiplier"

    /// UserDefaults key for the APP-WIDE UI font-size MULTIPLIER (see
    /// `AppTextSize.swift`). Deliberately SEPARATE from `transcriptTextSizeKey` so
    /// the general chrome and the transcript/captions scale independently — changing
    /// one never affects the other. Read reactively by `.appTextScaling()` and bound
    /// to Settings' General slider. Reuses `TranscriptTextSize.range/.step`; default
    /// is `1.0` (registered in `OpenCaptionsApp`).
    static let appTextSizeKey = "opencaptions.app.textSizeMultiplier"

    /// UserDefaults key for the "save session audio for playback" preference.
    /// Read at record time by `MacTranscriptionViewModel.start` (via a raw
    /// `UserDefaults.standard.bool` lookup) and bound to `MacSettingsView`'s
    /// `@AppStorage` toggle. Default is `true` (registered in `OpenCaptionsApp`).
    static let sessionAudioKey = "opencaptions.sessionAudio.save"

    /// UserDefaults key (Bool) for AUTOMATIC re-transcription after a recording is
    /// saved. When on, the just-saved session is re-processed automatically; the
    /// engine FOLLOWS the Transcription Engine selection (`transcriptionEngineKindKey`)
    /// — there's no separate engine choice here. Bound to `MacSettingsView`'s toggle
    /// and read by `RetranscriptionManager`.
    /// Requires saved session audio — with `sessionAudioKey` off there's no `.m4a` to
    /// re-process. The MANUAL re-transcribe menu is independent of this key. Default
    /// `false` (registered in `OpenCaptionsApp`).
    static let retranscriptionAutoKey = "opencaptions.retranscription.auto"

    /// UserDefaults key (Bool) for AUTOMATIC speaker naming from the summary pass.
    /// When on, a generated summary also predicts who each diarized speaker is and
    /// confidently-named speakers are renamed silently; when off, labels stay
    /// "Speaker N" and Edit Speakers is the only way to name them. Bound to
    /// `MacSettingsView`'s toggle and read by `SummaryViewModel` at apply time.
    /// Gates only whether the prediction is APPLIED — the request the model receives is
    /// identical either way, so toggling this never changes the summary text itself.
    /// Diarization is cloud-only, so this has no effect with an on-device engine
    /// selected. Default `true` (registered in `OpenCaptionsApp`) — it must be
    /// registered, since a raw
    /// `UserDefaults.bool` read of an unregistered key returns `false` and would ship
    /// the feature silently off. See docs/2026-07-29-macos-speaker-auto-naming.md.
    static let speakerNamingAutoKey = "opencaptions.speakerNaming.auto"

    /// UserDefaults key for the user's custom vocabulary — the terms biased into
    /// recognition. Holds JSON-encoded `[VocabularyTerm]` as `Data`, so it is
    /// deliberately NOT in `register(defaults:)` (a blob has no sensible registered
    /// default); `VocabularyStore+Persistence` defaults in code instead, and treats
    /// the key's ABSENCE as a first launch to seed. Owned by `VocabularyStore`, read
    /// by both Soniox paths. Device-local — never synced.
    static let vocabularyTermsKey = "opencaptions.vocabulary.terms"

    /// UserDefaults key (String) for the freeform background note sent as Soniox
    /// `context.text` (an agenda, prior notes, a topic). Shares the context character
    /// budget with `vocabularyTermsKey`. Removed rather than stored as "" when
    /// cleared. Owned by `VocabularyStore`.
    static let vocabularyBackgroundTextKey = "opencaptions.vocabulary.backgroundText"

    /// UserDefaults key (String) for the user's own name, set in Settings →
    /// General. Device-local, never synced. Feeds three features: Soniox's
    /// live-transcription context payload, the vocabulary screen's
    /// "always-included" own-name term, and the `@Name` mention-highlight/
    /// notify feature. Empty string (the `@AppStorage` default) means "not set".
    static let yourNameKey = "opencaptions.yourName"

    /// The user's own name preference, or `nil` if unset/blank, for consumers
    /// that want `String?` rather than dealing with the empty-string default
    /// themselves (Soniox context, vocabulary, mention-highlight/notify).
    static var yourName: String? {
        let value = UserDefaults.standard.string(forKey: yourNameKey) ?? ""
        return value.isEmpty ? nil : value
    }

    /// UserDefaults key (Bool) for the global "finished onboarding" gate flag —
    /// the sole gate `OpenCaptionsApp` reads to decide between `ContentView` and
    /// `MacOnboardingView`. Written once by `MacOnboardingView.complete()`.
    static let hasCompletedOnboardingKey = "hasCompletedOnboarding"

    /// The active session's view model, or nil when idle. Non-nil is the single
    /// source of truth for "a session is live" (running, paused, or failed with a
    /// kept transcript) — it drives whether the window shows the live screen.
    private(set) var viewModel: MacTranscriptionViewModel?

    /// Whether the floating captions overlay is currently shown. Observable so the
    /// menu command's Show/Hide label tracks it.
    private(set) var captionsVisible = false

    /// True while a session exists (used to gate reopen-time reconcile + new-record).
    var isActive: Bool { viewModel != nil }

    /// The floating captions panel. Window-independent so it stays up while the
    /// main window is closed.
    @ObservationIgnored private let captions = CaptionsOverlayController()

    /// The app's shared SwiftData container, stashed at launch (see
    /// `OpenCaptionsApp`). Lets the store start a recording from the menu-bar item
    /// without an on-screen view to supply `modelContext.container`.
    @ObservationIgnored var modelContainer: ModelContainer?

    /// Opens (or refocuses) the main window. Stashed once at launch from the
    /// app's root scene — the only place `@Environment(\.openWindow)` is
    /// available — so non-view code (the global-hotkey Start fallback, which must
    /// raise the mic-permission UI) can bring the window back even when it's
    /// closed. See `OpenCaptionsApp`.
    @ObservationIgnored var openMainWindow: (() -> Void)?

    /// A `NavSection` to jump to the next time `ContentView` appears. Set by
    /// `OpenCaptionsCommands`'s Cmd+, handler when the main window is closed (so
    /// there's no live `openSettings` focused value to call directly) alongside
    /// `openMainWindow?()` — `ContentView.onAppear` consumes and clears it.
    var pendingSection: NavSection?

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
    /// window on screen — the whole point of the status-bar "New Session": just
    /// start transcribing, don't also raise the app.
    ///
    /// Returns `true` if capture started headlessly. Returns `false` when the
    /// start needs the window's permission UI — a denied/undetermined-then-denied
    /// mic, or a system-audio source whose Screen Recording grant is missing (its
    /// gating shows an alert). The caller then falls back to opening the window.
    @discardableResult
    func startHeadlessRecording() async -> Bool {
        guard !isActive, let container = modelContainer else { return false }

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

        let vm = makeSession()
        await vm.start(modelContainer: container, source: source)
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
        viewModel = nil
        // Session fully gone — release the App Nap assertion synchronously.
        // Belt-and-suspenders alongside the observation-driven release, which has
        // already fired when stop()/failSession flipped isRunning/isPaused false.
        updateBackgroundActivity()
    }

    /// Tears down any live session synchronously on sign-out, BEFORE the auth cache
    /// is cleared. Without this, the window-independent session keeps running past
    /// sign-out. Discards (doesn't save) the in-progress transcript — signing out
    /// mid-recording abandons it.
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
    /// (`withObservationTracking` is one-shot, so each fire must re-arm). Stops
    /// re-arming once the session is cleared.
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

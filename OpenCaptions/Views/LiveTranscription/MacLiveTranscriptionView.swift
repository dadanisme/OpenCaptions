//
//  MacLiveTranscriptionView.swift
//  OpenCaptions
//
//  Live recording screen: requests mic access, streams a Soniox transcript with
//  speaker labels, supports pause/resume, and on stop saves the session. Shown
//  as the navigation-stack ROOT (see TranscriptionsScreen) so it owns its own
//  back button. The window title bar shows the working session title; status
//  lives in the title-bar subtitle instead of an in-content header.
//

import SwiftData
import SwiftUI

struct MacLiveTranscriptionView: View {
    // Not `private`: the source/permission logic lives in a same-type extension
    // (MacLiveTranscriptionView+AudioSource) to keep this file under the limit.
    @Environment(\.modelContext) var modelContext
    @Environment(MacAuthManager.self) var auth
    @Environment(LiveSessionStore.self) var store

    /// The active session's view model, owned by `LiveSessionStore` so it (and its
    /// audio + socket) survive this view — and the whole window — being torn down.
    let viewModel: MacTranscriptionViewModel
    /// Persisted capture-source choice (rawValue). The app's first @AppStorage.
    @AppStorage("opencaptions.audioSource") var sourceRaw = AudioSource.microphone.rawValue
    /// Shared transcript font-size multiplier — scales the live transcript's
    /// semantic fonts (see `TranscriptTextSize`). Same key the pill/menu-bar/
    /// Settings write, so a change from any surface reflects here live.
    @AppStorage(LiveSessionStore.transcriptTextSizeKey) private var textSizeMultiplier = 1.0
    /// Permission gate for the DESIRED source; `.ok` shows the live transcript.
    @State var access: AudioAccessState = .ok
    @State private var isStopping = false
    @State private var showBackConfirm = false
    @State private var showStopConfirm = false
    /// Auto-scroll gate. Starts pinned; a `MacScrollStateObserver` flips it
    /// off when the user scrolls up to read earlier text and back on when they
    /// scroll to the bottom, so incoming tokens no longer yank the view down.
    @State private var shouldAutoScroll = true
    /// Speaker being renamed; non-nil drives the rename sheet. A fresh value each
    /// time so the sheet's text field reseeds deterministically. Not `private`: set
    /// by `beginRename` in the +Speakers same-type extension.
    @State var renameTarget: RenameTarget?
    /// Stable bubble ID under the pointer, for the click-to-rename hover cue.
    @State private var hoveredBubbleID: Int?
    /// Non-nil presents the share dialog for the minted cloud session.
    // Not `private`: the share logic lives in MacLiveTranscriptionView+Sharing.
    @State var shareTarget: ShareTarget?

    /// Called with the saved session's ID on Stop & Save (parent opens detail).
    /// Leaving the recording screen otherwise is driven by clearing the store's
    /// session (which makes the parent re-show the list), so there's no separate
    /// exit callback.
    let onFinish: (PersistentIdentifier?) -> Void

    /// The transcript surface plus its layout/navigation chrome. Kept separate
    /// from `body` so the two modifier chains type-check independently.
    private var recordingSurface: some View {
        content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Host the floating transport bar as a bottom safe-area inset so the live
        // transcript rests ABOVE it (newest line stays readable) while older lines
        // still scroll translucently behind the glass. Hidden when access is denied.
        .safeAreaInset(edge: .bottom) {
            if case .ok = access {
                MacTranscriptionControls(
                    viewModel: viewModel,
                    isStopping: isStopping,
                    source: sourceBinding,
                    onEnd: handleEnd
                )
            }
        }
        .navigationTitle(viewModel.workingTitle)
        .navigationSubtitle(statusText)
    }

    var body: some View {
        // Split from `recordingSurface` so each expression type-checks in
        // reasonable time (the full chain otherwise exceeds the solver's budget).
        recordingSurface
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: handleBack) {
                    Image(systemName: "chevron.backward")
                }
                .disabled(isStopping)
                .help("Back")
                .accessibilityLabel("Back")
            }
            shareToolbarItem
        }
        .sheet(item: $shareTarget) { target in
            MacShareSessionSheet(sessionId: target.id)
        }
        .alert("End session?", isPresented: $showBackConfirm) {
            Button("End") { Task { await stopAndExit() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Going back will end and save this transcription.")
        }
        .alert("End session?", isPresented: $showStopConfirm) {
            Button("End") { Task { await stopAndSave() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will end the transcription and save it.")
        }
        .sheet(item: $renameTarget) { target in
            MacRenameSpeakerSheet(currentName: target.currentName) { newName in
                viewModel.rename(speaker: target.speakerID, to: newName)
            }
        }
        // Starts capture on first appearance; on a later appearance (window
        // reopened mid-session) it no-ops so we rebind to the running session.
        // The session is NOT discarded on disappear — the store keeps it alive
        // when the window closes; menu-bar transport + status live in the store.
        .task { await startIfPermitted() }
        // Expose pause/resume + end to the main menu. Rebuilt when `isPaused`
        // changes so the Pause/Resume menu label stays in sync.
        .focusedSceneValue(\.liveRecording, LiveRecordingActions(
            isPaused: viewModel.isPaused,
            togglePause: togglePause,
            end: handleEnd
        ))
        // Expose show/hide captions to the main menu; rebuilt when visibility
        // changes so the label stays in sync.
        .focusedSceneValue(\.captionsOverlay, CaptionsOverlayActions(
            isVisible: store.captionsVisible,
            toggle: { store.toggleCaptions() }
        ))
    }

    /// Toggles pause/resume — the same logic as the transport pill's center
    /// button, also exposed to the main menu via `.focusedSceneValue`.
    func togglePause() {
        if viewModel.isPaused {
            Task { await viewModel.resume() }
        } else {
            viewModel.pause()
        }
    }

    /// Shown in the window title-bar subtitle (replaces the old in-content status).
    private var statusText: String {
        guard case .ok = access else { return "" }
        if let error = viewModel.errorMessage { return error }
        if viewModel.isPreparingEngine { return "Preparing model…" }
        if viewModel.isPaused { return "Paused" }
        if viewModel.isRunning { return "" }
        return "Connecting…"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if case .ok = access {
            transcript
                // On-device engines load a CoreML model before the first token; cover the
                // (empty) transcript with a "Preparing model…" overlay while that runs.
                .overlay {
                    if viewModel.isPreparingEngine {
                        MacPreparingModelOverlay()
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: viewModel.isPreparingEngine)
        } else {
            MacAudioPermissionView()
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(viewModel.finalLines.ids.enumerated()), id: \.element) { index, id in
                        bubble(at: index).id(id)
                    }
                    if !viewModel.partialLine.isEmpty {
                        partialBubble.id("partial")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                // Detects user-driven scroll and drives `shouldAutoScroll` so we stop
                // yanking the view to the newest line while the user reads earlier
                // text; resumes once they scroll back to the bottom.
                .background(
                    MacScrollStateObserver(shouldAutoScroll: $shouldAutoScroll)
                        .frame(width: 0, height: 0)
                )
            }
            // Pin to the newest content with an imperative scroll to a REAL realized
            // view — the live partial if present, else the last committed line — never
            // a zero-height anchor a LazyVStack may not have materialized. The newest
            // line settles just above the floating pill (whose height the
            // `.safeAreaInset` in `body` reserves). Fires on ids.count (a new line OR
            // a top flush both change it, so a flush re-pins) and partialLine
            // (streaming) — but ONLY while pinned to the bottom, so a token
            // arriving while the user reads earlier text leaves their position alone.
            // We deliberately do NOT use `.defaultScrollAnchor(.bottom)`: it hangs the
            // app when the flush removes rows from the LazyVStack.
            .onChange(of: viewModel.finalLines.ids.count) { _, _ in
                if shouldAutoScroll { scrollToNewest(proxy) }
            }
            .onChange(of: viewModel.partialLine) { _, _ in
                if shouldAutoScroll { scrollToNewest(proxy) }
            }
            // User scrolled back to the bottom — snap the last sliver and resume.
            .onChange(of: shouldAutoScroll) { _, resumed in
                if resumed { scrollToNewest(proxy) }
            }
            .onAppear { scrollToNewest(proxy) }
        }
    }

    /// Scrolls the newest content to the bottom: the live partial if present, else
    /// the last committed line. Targets a real, realized row — never a zero-height
    /// anchor — so it pins reliably and re-pins after a top flush, with no
    /// `.defaultScrollAnchor(.bottom)` (which hangs on row removal).
    private func scrollToNewest(_ proxy: ScrollViewProxy) {
        if !viewModel.partialLine.isEmpty {
            proxy.scrollTo("partial", anchor: .bottom)
        } else if let lastID = viewModel.finalLines.ids.last {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }

    @ViewBuilder
    private func bubble(at index: Int) -> some View {
        if index < viewModel.finalLines.textLines.count {
            let speaker = speaker(at: index)
            let bubbleID = viewModel.finalLines.ids[index]
            let renameable = canRename(speaker)
            let isHovered = renameable && hoveredBubbleID == bubbleID
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    // App glyph when this line came from system audio; renders
                    // nothing (no reserved slot) for mic / own-voice lines.
                    SourceAppIcon(bundleID: sourceApp(at: index), sizeMultiplier: textSizeMultiplier)
                    Text(timestamp(at: index))
                        .font(.transcript(.caption, multiplier: textSizeMultiplier))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    // Speaker label only for diarized speakers (positive ids). On-device
                    // engines are single-stream (speaker == -1) — no label, no rename.
                    if speaker > 0 {
                        Text(speakerName(at: index))
                            .font(.transcript(.caption, multiplier: textSizeMultiplier))
                            .fontWeight(.semibold)
                            .foregroundStyle(speakerColor(at: index))
                    }
                    // Pencil appears on hover so the whole bubble reads as editable.
                    if isHovered {
                        Image(systemName: "pencil")
                            .font(.transcript(.caption, multiplier: textSizeMultiplier))
                            .foregroundStyle(speakerColor(at: index).opacity(0.7))
                    }
                }
                // No .textSelection here: the whole bubble is a click target for
                // rename, and selectable text would swallow clicks on the words.
                HighlightedMessageText(viewModel.finalLines.textLines[index], userName: auth.userName)
                    .font(.transcript(.body, multiplier: textSizeMultiplier))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.primary.opacity(0.06) : .clear)
            )
            // Rectangle content shape makes the FULL padded bubble (not just the
            // text glyphs) the hit region for both hover and tap.
            .contentShape(Rectangle())
            .onHover { hovering in
                guard renameable else { return }
                if hovering {
                    hoveredBubbleID = bubbleID
                } else if hoveredBubbleID == bubbleID {
                    hoveredBubbleID = nil
                }
            }
            .onTapGesture {
                if renameable { beginRename(at: index) }
            }
            .help(renameable ? "Click to rename this speaker" : "")
        }
    }

    private func timestamp(at index: Int) -> String {
        guard index < viewModel.finalLines.times.count else { return "0:00:00" }
        return ConversationFormatter.speakerTimestamp(fromMs: viewModel.finalLines.times[index].start_ms)
    }

    private var partialBubble: some View {
        // `cached: false` — the partial streams a new string each token; keep it out
        // of the shared segment cache so it can't evict committed-line entries.
        HighlightedMessageText(viewModel.partialLine, userName: auth.userName, cached: false)
            .font(.transcript(.body, multiplier: textSizeMultiplier))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Match the finalized bubbles' insets so the live line's left edge
            // lines up with the committed text above it.
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
    }

    // MARK: - Actions

    private func handleBack() {
        if viewModel.isRunning || viewModel.isPaused {
            showBackConfirm = true
        } else {
            // Not running (e.g. after a failure): Back abandons the kept transcript
            // and returns to the list. Clearing the store's session drops the view.
            store.clearSession()
        }
    }

    /// End tapped in the transport pill. Confirm only when there's an active/paused
    /// session (misclick guard); after a failure the session already ended, so save
    /// directly. Also exposed to the main menu's "End & Save" via `.focusedSceneValue`.
    func handleEnd() {
        if viewModel.isRunning || viewModel.isPaused {
            showStopConfirm = true
        } else {
            Task { await stopAndSave() }
        }
    }

    private func stopAndSave() async {
        isStopping = true
        let savedID = await viewModel.stop()
        store.clearSession()
        onFinish(savedID)
    }

    private func stopAndExit() async {
        isStopping = true
        _ = await viewModel.stop()
        store.clearSession()
    }

}

//
//  MacSessionDetailView+Playback.swift
//  OpenCaptions
//
//  The audio player bar and the playback-synced transcript: highlights the line
//  under the playhead, auto-scrolls to it, and lets a line's timestamp be tapped
//  to seek. Split from MacSessionDetailView to stay under the line limit.
//

import SwiftData
import SwiftUI

extension MacSessionDetailView {
    // MARK: - Transcript (synced to playback)

    var transcriptTab: some View {
        let sortedLines = session.lines.sorted {
            ($0.startMs, $0.timestamp) < ($1.startMs, $1.timestamp)
        }
        // Playback affordances (highlight + tap-to-seek) are live only when a
        // recording is loaded — mirrors the player bar's gate.
        let playbackEnabled = playback.isAvailable
        // The line whose start is the latest at or before the playhead.
        let activeID: PersistentIdentifier? = playbackEnabled
            ? sortedLines.last(where: { $0.startMs <= playback.currentMs })?.persistentModelID
            : nil

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(sortedLines) { line in
                        // A search deep link's target line stays highlighted
                        // regardless of playback position — it's a permanent
                        // "this is what you searched for" marker, not a
                        // playhead indicator, so it doesn't clear once
                        // playback moves elsewhere.
                        transcriptRow(
                            line,
                            isActive: line.persistentModelID == activeID || line.persistentModelID == scrollToLineID,
                            seekable: playbackEnabled
                        )
                        .id(line.persistentModelID)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            // Follow the playhead, but only while playing so manual scrolling
            // (or scrubbing) isn't yanked back.
            .onChange(of: activeID) { _, id in
                guard playback.isPlaying, let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
            // Deep link from a Transcriptions search hit: center on the
            // matched line once this tab appears. Re-fires each time the
            // user comes back to this tab (this view is torn down when
            // `tab` switches to `.summary`), which is fine — re-centering on
            // revisit isn't surprising. The seek (audio playhead) is
            // separate and one-time-only — see `seekToSearchTargetIfNeeded`.
            .task {
                guard let targetID = scrollToLineID else { return }
                // Lets the LazyVStack's first layout pass land before
                // `scrollTo` — calling it immediately on appear can
                // otherwise be a no-op against unmeasured content.
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                withAnimation { proxy.scrollTo(targetID, anchor: .center) }
            }
        }
    }

    private func transcriptRow(_ line: TranscriptionLine, isActive: Bool, seekable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                // App glyph for system-audio lines; nothing for mic lines. Pass the
                // app-wide scale so the glyph grows with the timestamp/speaker text.
                SourceAppIcon(bundleID: line.sourceAppBundleID, sizeMultiplier: appTextScale)
                Text(ConversationFormatter.speakerTimestamp(fromMs: line.startMs))
                    .appScaledFont(.caption).monospacedDigit()
                    .foregroundStyle(.tertiary)
                // Color the speaker label by its diarization id (not its name), so
                // the color stays tied to the speaker and survives a rename — and
                // matches the live transcript. Only shown for diarized speakers
                // (positive ids); on-device engines are single-stream (id -1), so
                // those sessions show just the timestamp, no "Speaker -1" label.
                if line.speakerId > 0 {
                    Text(line.speakerName)
                        .appScaledFont(.caption).fontWeight(.semibold)
                        .foregroundStyle(SpeakerPalette.color(for: line.speakerId))
                }
            }
            // Name-mention highlight reads the signed-in user's name straight from
            // the shared auth manager: the base MacSessionDetailView is at the file
            // line limit, so avoid threading a stored/@Environment name through it.
            HighlightedMessageText(line.text, userName: LiveSessionStore.yourName)
                .appScaledFont(.body)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isActive ? Color.accentColor.opacity(0.12) : .clear)
        )
        // Tap anywhere on the bubble to snap playback to this line and play.
        // Only active once a recording is loaded.
        .contentShape(Rectangle())
        .onTapGesture {
            guard seekable else { return }
            playback.seek(toMs: line.startMs)
            playback.play()
        }
        .help(seekable ? "Jump to this moment" : "")
        // Right-click to rename this bubble's speaker (diarized speakers only) —
        // left-click stays reserved for tap-to-seek above. Commits through the
        // same persist path as the toolbar batch editor.
        .contextMenu {
            if line.speakerId > 0 {
                Button {
                    renameTarget = SpeakerRenameTarget(
                        speakerID: line.speakerId, currentName: line.speakerName)
                } label: {
                    Label("Rename Speaker…", systemImage: "pencil")
                }
            }
        }
    }

    // MARK: - Tab switcher

    /// Summary/Transcript switcher: a native segmented `Picker` — the same control
    /// Apple Calendar uses for its Day/Week/Month/Year "tab view". Native so its
    /// Liquid Glass + shadow render correctly (a hand-rolled `glassEffect` capsule
    /// renders a heavier, mismatched shadow). Each segment is a `Label` (icon +
    /// title, not just text) for accessibility — VoiceOver and Switch Control
    /// users get more than a bare icon-only toolbar button would give them.
    /// Hosted centered (`.principal`) in the toolbar by `MacSessionDetailView`,
    /// matching `MacSettingsView`'s tab switcher; the segment highlight animates
    /// while `mainContent` swaps instantly (a `Picker` selection change isn't
    /// wrapped in `withAnimation`, so it never crossfades the content).
    var tabSwitcher: some View {
        Picker("View", selection: $tab) {
            Label("Summary", systemImage: "sparkles").tag(Tab.summary)
            Label("Transcript", systemImage: "text.alignleft").tag(Tab.transcript)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    // MARK: - Bottom player pill

    /// The bottom-anchored floating player pill, shown only when a recording is
    /// loaded. Capped + centered so it stays a floating pill on wide windows
    /// rather than stretching edge to edge.
    @ViewBuilder
    var bottomBar: some View {
        if playback.isAvailable {
            playerBar
                .frame(maxWidth: 700)
                .padding(.horizontal)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Player bar

    var playerBar: some View {
        HStack(spacing: 12) {
            Button { playback.togglePlayPause() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .appScaledFont(.title2)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 24)
            }
            .buttonStyle(.plain)

            Text(ConversationFormatter.playbackTime(fromMs: playback.currentMs))
                .appScaledFont(.caption).monospacedDigit().foregroundStyle(.secondary)

            Slider(
                value: Binding(
                    get: { playback.currentTime },
                    set: { playback.seek(to: $0) }
                ),
                in: 0...max(playback.duration, 0.01),
                onEditingChanged: { playback.isScrubbing = $0 }
            )

            Text(ConversationFormatter.playbackTime(fromMs: Int((playback.duration * 1000).rounded())))
                .appScaledFont(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .liquidGlassBackground(in: Capsule())
    }
}

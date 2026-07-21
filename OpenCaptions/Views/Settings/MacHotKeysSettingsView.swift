//
//  MacHotKeysSettingsView.swift
//  OpenCaptions
//
//  The "Shortcuts" Settings pane (issue #249): rebind each global hotkey by
//  RECORDING it — click a row, then press the chord you want. Capture uses a
//  single local `NSEvent` key-down monitor (no permission needed), and
//  `NSEvent.keyCode` is the same virtual-key space Carbon registers, so the press
//  is stored verbatim. Esc cancels.
//
//  Two subtleties the capture handles: (1) while recording we SUSPEND the live
//  Carbon hotkeys — otherwise pressing a chord that's already bound (even this
//  slot's own current chord) would be consumed by Carbon and fire the action
//  instead of being captured; (2) the local monitor is app-wide, so we cancel
//  recording the moment the Settings window loses key focus, or a keystroke in
//  another Open Captions window could be swallowed and silently bound.
//
//  Each row shows the current chord and a warning when a binding can't be
//  registered (no modifier, duplicate, or claimed elsewhere). Changes apply and
//  persist immediately through `HotKeyManager`.
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

struct MacHotKeysSettingsView: View {
    /// Observed so rows re-render as bindings/issues change.
    @State private var manager = HotKeyManager.shared
    /// The action currently capturing a chord, or nil. Only one at a time.
    @State private var recording: HotKeyAction?
    /// The live key-down monitor while recording (removed when capture ends).
    @State private var monitor: Any?
    /// Whether the Settings window is key. Recording is cancelled the moment it
    /// isn't, so the app-wide capture monitor can't swallow keystrokes meant for
    /// another Open Captions window.
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        Form {
            Section {
                ForEach(HotKeyAction.allCases) { action in
                    HotKeyRecorderRow(
                        action: action,
                        binding: manager.binding(for: action),
                        issue: manager.issues[action],
                        isRecording: recording == action,
                        toggle: { toggleRecording(action) }
                    )
                }
            } header: {
                Text("Global Shortcuts")
            } footer: {
                Text("These work system-wide, even when Open Captions is in the background or its window is closed. Click a shortcut, then press the keys you want (include at least one of ⌃ ⌥ ⌘). A brief badge on screen confirms every press.")
                    .appScaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Reset to Defaults") {
                    stopRecording()
                    manager.resetToDefaults()
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { stopRecording() }
        // Losing key focus (user clicked another window) cancels an armed capture.
        .onChange(of: controlActiveState) { _, state in
            if state != .key { stopRecording() }
        }
    }

    // MARK: - Recording

    /// Starts capturing for `action`, or stops if it's already the one recording.
    private func toggleRecording(_ action: HotKeyAction) {
        if recording == action { stopRecording(); return }
        recording = action
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            capture(event)
        }
        // Suspend the live global hotkeys so the pressed chord reaches the monitor
        // above instead of firing an action (lets any chord — even this slot's
        // current one — be re-recorded). Restored in `stopRecording()`.
        manager.suspendRegistrations()
    }

    /// Handles a key-down while recording: Esc cancels; any other key is bound
    /// (with whatever modifiers are held) to the recording action. Returns nil to
    /// swallow the event so it doesn't beep or type into the Settings window.
    private func capture(_ event: NSEvent) -> NSEvent? {
        guard let action = recording else { return event }
        let modifiers = carbonModifiers(from: event)
        if event.keyCode == UInt16(kVK_Escape), modifiers == 0 {
            stopRecording()
            return nil
        }
        manager.setBinding(
            HotKeyBinding(keyCode: UInt32(event.keyCode), modifiers: modifiers),
            for: action
        )
        stopRecording()
        return nil
    }

    private func stopRecording() {
        // No-op when nothing is being recorded, so unrelated focus changes (the
        // controlActiveState observer) don't needlessly churn the registrations.
        guard recording != nil || monitor != nil else { return }
        recording = nil
        removeMonitor()
        // Restore the global hotkeys suspended in `toggleRecording`.
        manager.reregisterAll()
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Translates an event's modifier flags into Carbon modifier bits.
    private func carbonModifiers(from event: NSEvent) -> UInt32 {
        let flags = event.modifierFlags
        var result: UInt32 = 0
        if flags.contains(.command) { result |= HotKeyModifier.command.rawValue }
        if flags.contains(.option) { result |= HotKeyModifier.option.rawValue }
        if flags.contains(.control) { result |= HotKeyModifier.control.rawValue }
        if flags.contains(.shift) { result |= HotKeyModifier.shift.rawValue }
        return result
    }
}

/// One row: action name + a button that shows the current chord and, when
/// clicked, records a new one; plus a warning when the binding isn't active.
private struct HotKeyRecorderRow: View {
    let action: HotKeyAction
    let binding: HotKeyBinding
    let issue: HotKeyIssue?
    let isRecording: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(action.title, systemImage: action.symbol)
                Spacer()
                Button(action: toggle) {
                    Text(isRecording ? "Type shortcut…" : binding.displayString)
                        .appScaledFont(.callout, design: .monospaced)
                        .frame(minWidth: 130)
                }
                .buttonStyle(.bordered)
                .tint(isRecording ? .accentColor : nil)
                .help(isRecording ? "Press the keys, or Esc to cancel" : "Click to record a new shortcut")
            }
            if let issue {
                Label(issue.warningText, systemImage: "exclamationmark.triangle.fill")
                    .appScaledFont(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    MacHotKeysSettingsView()
        .frame(width: 480, height: 460)
}

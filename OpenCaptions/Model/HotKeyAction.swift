//
//  HotKeyAction.swift
//  OgmoMac
//
//  The three transcription actions controllable by a global hotkey (issue #249).
//  Each is a TOGGLE — one chord flips between the two states (start⇄stop,
//  pause⇄resume, show⇄hide captions), mirroring how OBS/Krisp expose a single
//  global key per function — and maps to a state-respecting operation on
//  `LiveSessionStore`, a stable Carbon hotkey id, and a Settings label/icon.
//
//  Default chords all use the ⌃⌥⌘ ("hyper") modifier: it is essentially never
//  claimed by macOS or by app menu shortcuts (which lean on ⌘/⌘⇧/⌘⌥), so a
//  system-wide registration won't stomp on another app's keys — satisfying the
//  issue's "avoid conflicts with common shortcuts" better than the suggested
//  ⌘⇧ combos would (those collide with Save-As, hard-reload, etc.). Fully
//  user-editable in Settings. See docs/2026-07-10-macos-global-hotkeys.md.
//

import Carbon.HIToolbox
import Foundation

enum HotKeyAction: String, CaseIterable, Identifiable {
    /// Start a recording when idle; Stop & Save when one is active.
    case toggleRecording
    /// Pause when recording; Resume when paused.
    case togglePause
    /// Show or hide the floating captions overlay.
    case toggleCaptions

    var id: String { rawValue }

    /// Stable id carried in the Carbon `EventHotKeyID`; the C handler maps it
    /// back to this action. Never reused or reordered, so a live registration
    /// always resolves to the same action.
    var hotKeyID: UInt32 {
        switch self {
        case .toggleRecording: return 1
        case .togglePause: return 2
        case .toggleCaptions: return 3
        }
    }

    /// Settings-row title.
    var title: String {
        switch self {
        case .toggleRecording: return "Start / Stop Recording"
        case .togglePause: return "Pause / Resume"
        case .toggleCaptions: return "Show / Hide Captions"
        }
    }

    /// SF Symbol for the Settings row.
    var symbol: String {
        switch self {
        case .toggleRecording: return "record.circle"
        case .togglePause: return "playpause"
        case .toggleCaptions: return "captions.bubble"
        }
    }

    /// Default chord: ⌃⌥⌘ + a mnemonic letter (R / P / C).
    var defaultBinding: HotKeyBinding {
        let hyper = HotKeyModifier.hard.rawValue // ⌃⌥⌘
        let keyCode: Int
        switch self {
        case .toggleRecording: keyCode = kVK_ANSI_R
        case .togglePause: keyCode = kVK_ANSI_P
        case .toggleCaptions: keyCode = kVK_ANSI_C
        }
        return HotKeyBinding(keyCode: UInt32(keyCode), modifiers: hyper)
    }

    /// UserDefaults key holding this action's persisted binding (JSON).
    var defaultsKey: String { "ogmo.hotkey.\(rawValue)" }
}

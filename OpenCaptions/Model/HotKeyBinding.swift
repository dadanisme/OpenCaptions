//
//  HotKeyBinding.swift
//  OpenCaptions
//
//  Value types describing a single global-hotkey chord. A binding is
//  a Carbon virtual key code plus a Carbon modifier-flags mask, stored VERBATIM
//  as the values `RegisterEventHotKey` expects, so registration needs no
//  translation. Bindings persist to UserDefaults as JSON.
//
//  Global hotkeys go through Carbon's `RegisterEventHotKey` (not
//  `NSEvent.addGlobalMonitorForEvents`) deliberately: Carbon hotkeys need NO
//  Accessibility/Input-Monitoring permission, CONSUME the event (so the chord
//  never leaks into the frontmost app), and are App-Store-safe under the sandbox.
//  A global monitor would require a permission grant AND still forward the keys.
//  See docs/2026-07-10-macos-global-hotkeys.md.
//

import Carbon.HIToolbox
import Foundation

/// Carbon modifier-flag bits as an `OptionSet` over the exact `UInt32` values
/// `RegisterEventHotKey` consumes. (Carbon's own `cmdKey`/`optionKey`/… are `Int`.)
struct HotKeyModifier: OptionSet, Hashable {
    let rawValue: UInt32

    static let command = HotKeyModifier(rawValue: UInt32(cmdKey))
    static let option = HotKeyModifier(rawValue: UInt32(optionKey))
    static let control = HotKeyModifier(rawValue: UInt32(controlKey))
    static let shift = HotKeyModifier(rawValue: UInt32(shiftKey))

    /// The "hard" modifiers a global hotkey must include at least one of; without
    /// one, the chord would be a bare (or Shift-only) key that clobbers normal
    /// typing everywhere.
    static let hard: HotKeyModifier = [.command, .option, .control]
}

/// One global-hotkey chord: a Carbon key code + modifier mask.
struct HotKeyBinding: Codable, Equatable {
    /// Carbon virtual key code (e.g. `kVK_ANSI_R`).
    var keyCode: UInt32
    /// OR of `HotKeyModifier` raw values.
    var modifiers: UInt32

    var modifierSet: HotKeyModifier { HotKeyModifier(rawValue: modifiers) }

    /// True when at least one of ⌃/⌥/⌘ is present. The manager refuses to register
    /// a chord that fails this (it would intercept plain keystrokes system-wide).
    var hasRequiredModifier: Bool { !modifierSet.isDisjoint(with: .hard) }

    /// Human-readable chord in the conventional ⌃⌥⇧⌘ order, parts joined with
    /// " + ", e.g. "⌃ + ⌥ + ⌘ + R".
    var displayString: String {
        var parts: [String] = []
        if modifierSet.contains(.control) { parts.append("⌃") }
        if modifierSet.contains(.option) { parts.append("⌥") }
        if modifierSet.contains(.shift) { parts.append("⇧") }
        if modifierSet.contains(.command) { parts.append("⌘") }
        parts.append(HotKeyKey.label(for: keyCode))
        return parts.joined(separator: " + ")
    }
}

/// Maps a Carbon virtual key code (which is the same code space as
/// `NSEvent.keyCode`, so a press-recorded chord stores it verbatim) to a display
/// label. Covers ANSI letters/digits, the common special keys, and punctuation;
/// anything unmapped falls back to "Key N".
enum HotKeyKey {
    static func label(for code: UInt32) -> String {
        labels[Int(code)] ?? "Key \(code)"
    }

    private static let labels: [Int: String] = {
        var map: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
            kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
            kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
            kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
            kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
            kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←",
            kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
            kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";",
            kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
            kVK_ANSI_Slash: "/", kVK_ANSI_Grave: "`",
        ]
        let functionKeys = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
            kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
        ]
        for (index, code) in functionKeys.enumerated() { map[code] = "F\(index + 1)" }
        return map
    }()
}

/// Why an action's chord could not be registered — surfaced by the Settings pane.
enum HotKeyIssue {
    /// No ⌃/⌥/⌘ present.
    case missingModifier
    /// Identical to another action's chord.
    case duplicate
    /// The OS refused it (already owned by the system or another app).
    case systemConflict

    var warningText: String {
        switch self {
        case .missingModifier: return "Add at least one of ⌃ ⌥ ⌘ — this shortcut isn't active."
        case .duplicate: return "Already used by another Open Captions shortcut — this one isn't active."
        case .systemConflict: return "In use by the system or another app — this shortcut isn't active."
        }
    }
}

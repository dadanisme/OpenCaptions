//
//  HotKeyManager+Carbon.swift
//  OgmoMac
//
//  The low-level Carbon glue for `HotKeyManager`: installs one process-wide
//  `kEventHotKeyPressed` handler, and registers/unregisters each action's chord
//  via `RegisterEventHotKey`. Split from the manager to keep both files small
//  and the C-interop isolated.
//
//  Carbon's HotKey API is the App-Store-safe, permission-free way to get
//  system-wide hotkeys under the sandbox: no Accessibility grant, and it CONSUMES
//  the chord so it never leaks into the frontmost app. See HotKeyBinding.swift.
//

import Carbon.HIToolbox

extension HotKeyManager {

    /// Four-char code ("Ogmo") tagging this app's hotkey registrations.
    static var signature: OSType { 0x4F676D6F }

    /// Installs the single Carbon handler that fires for every registered chord.
    /// Idempotent — installs at most once.
    func installEventHandler() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var ref: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventCallback,
            1,
            &spec,
            nil, // no userData — the callback reaches the shared singleton directly
            &ref
        )
        if status == noErr { eventHandler = ref }
    }

    /// Tears down all live registrations WITHOUT touching `bindings`, so a chord
    /// can be press-recorded in Settings. While suspended, a pressed chord — even
    /// one currently bound to an action — reaches the app's local key monitor
    /// instead of being consumed by Carbon and firing that action. Pair with
    /// `reregisterAll()` (restore). Idempotent.
    func suspendRegistrations() {
        for (_, ref) in registrations { UnregisterEventHotKey(ref) }
        registrations.removeAll()
    }

    /// Re-registers every action's chord from `bindings`, rebuilding `issues`.
    /// Unregisters all first so a changed/removed chord never lingers. A chord is
    /// skipped (with a recorded issue) if it lacks a hard modifier, duplicates one
    /// already claimed this pass, or the OS refuses it.
    func reregisterAll() {
        for (_, ref) in registrations { UnregisterEventHotKey(ref) }
        registrations.removeAll()
        var newIssues: [HotKeyAction: HotKeyIssue] = [:]

        var claimed = Set<HotKeyChord>()
        for action in HotKeyAction.allCases {
            let binding = binding(for: action)
            guard binding.hasRequiredModifier else {
                newIssues[action] = .missingModifier
                continue
            }
            let chord = HotKeyChord(keyCode: binding.keyCode, modifiers: binding.modifiers)
            guard !claimed.contains(chord) else {
                newIssues[action] = .duplicate
                continue
            }
            if register(binding, for: action) {
                claimed.insert(chord)
            } else {
                newIssues[action] = .systemConflict
            }
        }
        issues = newIssues
    }

    /// Registers one action's chord. Returns whether the OS accepted it.
    private func register(_ binding: HotKeyBinding, for action: HotKeyAction) -> Bool {
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: action.hotKeyID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            binding.keyCode,
            binding.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return false }
        registrations[action] = ref
        return true
    }
}

/// Chord identity for intra-app duplicate detection.
private struct HotKeyChord: Hashable {
    let keyCode: UInt32
    let modifiers: UInt32
}

/// The process-wide Carbon hotkey handler. Carbon delivers these on the main run
/// loop, so hopping onto the main actor is safe and synchronous. Extracts the
/// fired chord's id and forwards it to the shared manager.
private func hotKeyEventCallback(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    let id = hotKeyID.id
    MainActor.assumeIsolated {
        HotKeyManager.shared.handleHotKey(id: id)
    }
    return noErr
}

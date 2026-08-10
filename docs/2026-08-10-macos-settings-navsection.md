# macOS Settings as a NavSection

**Date:** 2026-08-10 · **Scope:** Open Captions (native macOS) only · **Issue:** [#34](https://github.com/dadanisme/OpenCaptions/issues/34)

Settings used to be its own SwiftUI `Settings { }` scene: a separate `NSWindow`
hosting `MacSettingsView` in a fixed 480×460 frame, opened via Cmd+, or the
sidebar's `SettingsLink`. Every other user-facing surface — Transcriptions,
Action Items, Key Points, Vocabulary, Workspaces — is instead a `NavSection`
destination rendered in the main window's `NavigationSplitView` detail column.
The `NavSection` enum's own doc comment already anticipated this ("adding
future destinations (settings, etc.) a one-line change"), and the fixed-size
Settings window had already been cited twice as a constraint to design
*around* rather than fix: `2026-07-28-macos-custom-vocabulary.md` and
`2026-08-06-macos-workspaces.md` both moved a would-be Settings pane into a
sidebar destination specifically because a variable-length list editor
"doesn't fit the fixed Settings window."

This note covers moving Settings itself into that same pattern.

## `.settings` is a `NavSection` case, but not a `List` row

`NavSection` gained a `.settings` case like any other, but it's filtered out of
the sidebar's `ForEach(NavSection.allCases)` and rendered instead by
`SidebarSettingsFooter`, pinned below the list via `.safeAreaInset(edge: .bottom)`
— exactly where it already lived visually. The footer used to be a
`SettingsLink` (opening the separate window); now it's a plain `Button` that
sets `section = .settings`, with a light accent tint when that's the current
section so it can show its own selected state the way the `List`'s native
`.tag`-based rows do automatically.

`MacSettingsView` itself is unchanged in spirit — still the three-tab `TabView`
(General, Shortcuts, Support) — just no longer boxed into
`.frame(width: 480, height: 460)`. It's wrapped in a `NavigationStack` with
`.navigationTitle("Settings")`, matching `VocabularyScreen` / `WorkspacesScreen`.

## Cmd+, no longer comes free

A `Settings { }` scene gives SwiftUI's App menu a "Settings…" item and Cmd+,
for nothing. Removing the scene removes that for free — so
`OpenCaptionsCommands` now fills the `.appSettings` `CommandGroup` placement
itself:

```swift
CommandGroup(replacing: .appSettings) {
    Button("Settings…") {
        if let openSettings {
            openSettings()
        } else {
            LiveSessionStore.shared.pendingSection = .settings
            LiveSessionStore.shared.openMainWindow?()
        }
    }
    .keyboardShortcut(",", modifiers: .command)
}
```

`openSettings` is a new `@FocusedValue` (`MacFocusedValues.swift`), following
the same "screen publishes, menu reads" pattern every other command already
uses — except it's published by `ContentView` itself, unconditionally,
rather than by whichever screen happens to be frontmost. Settings access
shouldn't depend on which section is showing, and `ContentView`'s
`NavigationSplitView` is present for the whole time the main window is (it's
what switches *between* sections), so attaching `.focusedSceneValue` there
keeps the command reachable regardless of section.

That focused value is still nil whenever `ContentView` isn't mounted, though
— during onboarding, but also (unlike onboarding) while the **main window is
closed**, which this app explicitly supports (`MenuBarExtra` keeps it running,
and closing the window no longer quits it). A first pass here left Cmd+,
simply `.disabled(openSettings == nil)` in that state, silently regressing a
guarantee the old `Settings { }` scene gave for free — Settings was reachable
regardless of window state. The fix mirrors the existing global-hotkey Start
fallback (`LiveSessionStore.openMainWindow`, captured once from
`OpenCaptionsApp`'s `@Environment(\.openWindow)` via `WindowOpenerBridge`):
a new `LiveSessionStore.pendingSection` stashes `.settings` and
`openMainWindow?()` reopens the window; `ContentView.onAppear` consumes and
clears it. Onboarding is unaffected — the stash just sits until `ContentView`
first mounts post-onboarding, at worst landing the user on Settings a beat
early.

## Every row's explanation moved behind an "i" icon

Settings' fixed 480-pt width used to force every toggle, slider, and picker to
carry its explanation as an always-visible `.caption`/`.secondary` paragraph
directly underneath — the only way to fit both the control and its caveats in
so little horizontal space. The wider detail column removes that constraint,
but the paragraphs didn't just move: `Views/Settings/SettingsInfoTip.swift` is
a new reusable "i"-icon button that reveals the same text in a `.popover` on
click, placed inline next to the row's own label —

```swift
LabeledContent {
    Toggle("", isOn: $saveSessionAudio).labelsHidden()
} label: {
    SettingsInfoTip.label("Save session audio for playback", tip: "Keeps a copy of each session's audio so you can play it back…")
}
```

— so a glance at Settings now reads as a list of controls, and the prose is
available on demand rather than always competing for attention. Every row
that had one of these paragraphs converted the same way, across all four
Settings files (`MacSettingsView`, `MacHotKeysSettingsView`,
`MacMarkdownExportSection`, `MacSupportSettingsView`); the one paragraph that
wasn't attached to any single control — the free-standing note explaining what
the captions overlay is — moved onto the "Captions" section header's tip
instead of staying a `Section` of its own.

Two things changed after a first pass, both from review:

- **The tip is never nested inside a `Toggle`'s own label.** `Toggle(isOn:) { label }`
  makes its whole label a tap target on macOS, same as the switch itself — an
  `SettingsInfoTip` button living inside that label would have two
  overlapping controls fighting for the same tap (Save Session Audio, Offline
  Mode, Re-transcription, Speaker Names — the four toggles that carry a tip).
  Each was restructured the same way `App text size` / `Transcript text size`
  already were: `LabeledContent { Toggle("", isOn:).labelsHidden() } label: { ... }`,
  so the switch and the tip are two unambiguous, non-overlapping controls. A
  `.disabled(...)` that used to sit on the whole `Toggle` (e.g.
  re-transcription without saved session audio) now sits on just the inner
  switch, so the label and its tip stay readable even when the setting itself
  is disabled.
- **The repeated `HStack(spacing: 6) { Text(title); SettingsInfoTip(text:) }`
  composition** (nine call sites) is now `SettingsInfoTip.label(_:tip:)`, a
  static builder on `SettingsInfoTip` itself.

## No stale window-dismissal logic to fix

The issue's acceptance criteria called out fixing `MacAccountSettingsView`'s
`NSApp.keyWindow`-based dismissal (used to close the Settings window after
Sign Out / Delete Account). That code no longer exists — accounts were removed
wholesale in `2026-08-10-remove-accounts-and-firestore.md`, in a commit that
landed before this issue was picked up. There is no `NSApp.keyWindow` usage
anywhere in the app to fix.

## Docs with now-stale mentions (not edited)

Per this project's convention (see CLAUDE.md's Documentation section and
`2026-08-10-remove-accounts-and-firestore.md`'s precedent), these aren't
rewritten in place, just flagged here so a reader doesn't mistake the leftover
"fixed Settings window" framing for current behavior:
`2026-07-28-macos-custom-vocabulary.md` ("the Settings window is a fixed
480×460"), `2026-08-06-macos-workspaces.md` ("doesn't fit the fixed Settings
window"), and `2026-07-10-macos-app-wide-font-size.md` ("The Settings window
itself scales, so the slider previews live" — still true in spirit, since
Settings still inherits `.appTextScaling()`, just from the main window's root
now rather than its own scene).

## Follow-ups: the tab switcher and the sidebar footer

Two cosmetic requests landed right after the initial move:

- **The General/Shortcuts/Support switcher is now a toolbar `Picker`, not a
  `TabView`.** A plain `TabView` renders its own OS tab bar as a full-width
  band at the top of the content — fine inside a small fixed window, but
  visually heavy now that Settings is a full-width sidebar destination like
  every other one, none of which carry that kind of banner. It's replaced
  with the exact pattern `MacSessionDetailView` already uses for its
  Summary/Transcript switcher: a private `Tab: Hashable` enum, `@State`
  selection, a `Picker(...).pickerStyle(.segmented).labelsHidden().fixedSize()`,
  and content switched by a manual `switch tab { ... }` rather than `TabView`'s
  native paging. It's placed via a bare `ToolbarItem { tabSwitcher }` — no
  explicit `placement:` — which is what puts it in the toolbar's default
  trailing (top-right) position, matching where the session detail switcher
  already lives.
- **`SidebarSettingsFooter` dropped its "Settings" text entirely.** The row is
  now "Open Captions, v⟨short version⟩" on the leading side (pure
  informational chrome, not tappable) and an icon-only trailing button — the
  only interactive part of the row. The gear swaps `gearshape` ↔
  `gearshape.fill` and tints with `Color.accentColor` while `.settings` is the
  current section, replacing the old whole-row accent-tint background (which
  no longer made sense once half the row is non-interactive label text).

## Two pre-existing characteristics that now also apply to Settings

Putting Settings into `ContentView`'s single mutually-exclusive detail
`switch` means it inherits two things every *other* `NavSection` (Vocabulary,
Workspaces, Action Items, Key Points) already lived with, which a reviewer
flagged as if they were new:

- **Cmd+W closes the whole main window, not "just Settings."** There's one
  `Window` scene now, so Cmd+W while on the Settings screen closes it exactly
  as it would while on Vocabulary — reopening resets `section` to
  `.transcriptions`. The old `Settings { }` scene made this specific case feel
  different (Cmd+W really did close *only* Settings), but that was an
  artifact of Settings being the only section with its own window, not a
  property worth preserving for Settings alone while every other section
  still closes the whole app window on Cmd+W.
- **Opening Settings during a live recording unmounts the live view and its
  menu commands.** `MacLiveTranscriptionView` publishes `liveRecording` (Pause/
  Resume, End & Save) only while `TranscriptionsScreen` is the mounted detail
  view; switching to *any* other section — Settings now included — unmounts
  it and disables those Session-menu items until the user switches back. This
  already happened for Vocabulary/Workspaces/etc. before this change; Settings
  simply stopped being the one exception. The recording itself is unaffected
  (per `MacTranscriptionViewModel`'s "a session outlives its window"
  design — the session lives on the view model, not the view), and the
  menu-bar item's own transport controls work regardless of which detail
  screen is showing, so there's always a way to pause/end. Making the Session
  menu itself section-independent would mean re-sourcing `liveRecording`'s
  actions from `LiveSessionStore` at the `ContentView` level for every
  section, including reproducing `MacLiveTranscriptionView`'s end-of-session
  confirm flow outside the view that owns it — a real change to session
  menu availability across the *whole* app, not a Settings-specific fix, and
  out of scope here.

## Known deferrals

- **"Settings is for simple toggles only" as a boundary rule.** Vocabulary and
  Workspaces went into their own `NavSection` rather than a Settings tab
  specifically because Settings' old fixed window couldn't host a
  variable-length list editor. Settings no longer has that constraint, so
  that boundary is worth revisiting — not done here, since the issue only
  asked to move Settings itself, not to reconsider what else might belong
  inside it.
- **No localization**, matching every other user-facing string in the app.

## Files

**New**
- `OpenCaptions/Views/Settings/SettingsInfoTip.swift` — the "i"-icon popover.

**Edited**
- `OpenCaptions/OpenCaptionsApp.swift` — the `Settings { }` scene removed.
- `OpenCaptions/ContentView.swift` — the `settings` `NavSection` case, detail
  routing, sidebar `List` filter, `openSettings` focused value, the
  `pendingSection` consume-on-appear fallback.
- `OpenCaptions/OpenCaptionsCommands.swift` — the `.appSettings` command,
  with the closed-main-window fallback.
- `OpenCaptions/Utility/HotKeys/MacFocusedValues.swift` — `openSettings`.
- `OpenCaptions/LiveSessionStore.swift` — `pendingSection`.
- `OpenCaptions/Views/Shell/SidebarSettingsFooter.swift` — `Button` instead
  of `SettingsLink`; then, in the follow-up, the "Open Captions, v⟨version⟩" +
  icon-only-button layout replacing the "Settings" text row.
- `OpenCaptions/Views/Settings/MacSettingsView.swift` — `NavigationStack`
  wrapper, dropped fixed frame, info-tip conversions, `LabeledContent`-wrapped
  toggles for the four rows that carry a tip; then, in the follow-up, the
  `TabView` replaced by the `Tab` enum + toolbar `Picker` switcher.
- `OpenCaptions/Views/Settings/MacHotKeysSettingsView.swift`,
  `MacMarkdownExportSection.swift`, `MacSupportSettingsView.swift` —
  info-tip conversions via `SettingsInfoTip.label(_:tip:)`.

## Verification

No test target; the build is run in Xcode per the project's workflow. Manual
checklist:

1. Cmd+, opens Settings in the main window's detail column, not a separate
   window; the sidebar's Settings row shows a selected tint while it's open.
2. Close the main window entirely (Cmd+W), then press Cmd+, from the menu bar
   (or the app is frontmost with no window) — the main window reopens
   straight to Settings rather than doing nothing.
3. Every other sidebar section still switches normally, and Settings' row
   stays pinned below them rather than appearing in the scrolling list.
4. Each "i" icon opens a popover with the row's explanation and dismisses on
   an outside click; clicking directly on a tip-carrying toggle's info icon
   never also flips the switch, and clicking the switch never opens the
   popover. No row is left without its previous explanation reachable
   somehow.
5. General/Shortcuts/Support panes all render at full detail-column width
   without clipping, and the segmented switcher in the toolbar (top-right)
   correctly swaps between them.
6. Quit and relaunch — every preference read/written through this screen
   (name, text sizes, Offline Mode, toggles) still persists exactly as before,
   since none of the `@AppStorage` keys changed.
7. The sidebar footer reads "Open Captions, v⟨version⟩" with no "Settings"
   text; only the gear icon is clickable, and it fills/tints while Settings
   is the current section.

//
//  ContentView.swift
//  OpenCaptions
//
//  Root split view: the sidebar is the app's navigation menu; the detail column
//  hosts the selected section's screen (currently the transcription list, which
//  also drives recording + session detail via its own NavigationStack).
//

import SwiftData
import SwiftUI

struct ContentView: View {
    @State private var section: NavSection? = .transcriptions

    var body: some View {
        NavigationSplitView {
            // Settings is a `NavSection` case too, but it's excluded here and
            // rendered instead by `SidebarSettingsFooter`, pinned below the list —
            // it isn't one of the app's content sections.
            List(selection: $section) {
                ForEach(NavSection.allCases.filter { $0 != .settings }) { item in
                    // Explicit scaling: the sidebar `List` is AppKit-backed and can
                    // ignore the inherited default font, so opt the row in directly.
                    Label(item.title, systemImage: item.symbol)
                        .appScaledFont(.body)
                        .tag(item)
                }
            }
            .navigationTitle("Open Captions")
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            .safeAreaInset(edge: .bottom) { SidebarSettingsFooter(section: $section) }
        } detail: {
            switch section ?? .transcriptions {
            case .transcriptions:
                TranscriptionsScreen()
            case .actionItems:
                ActionItemsScreen()
            case .keyPoints:
                KeyPointsScreen()
            case .vocabulary:
                // The custom vocabulary is a device-local preference (see
                // `VocabularyStore`), not per-library data.
                VocabularyScreen()
            case .workspaces:
                WorkspacesScreen()
            case .settings:
                MacSettingsView()
            }
        }
        // Published regardless of which section is showing, so Cmd+, (the
        // `.appSettings` command in `OpenCaptionsCommands`) can always reach it.
        .focusedSceneValue(\.openSettings) { section = .settings }
        // Cmd+, while the main window was closed stashes `.settings` here
        // (there being no `openSettings` focused value yet to call directly)
        // instead of reopening straight to it — this picks that up the moment
        // the window (and this view) reappears.
        .onAppear {
            if let pending = LiveSessionStore.shared.pendingSection {
                section = pending
                LiveSessionStore.shared.pendingSection = nil
            }
        }
    }
}

/// Top-level navigation sections shown in the sidebar. `.settings` is a
/// destination like any other — it just renders as a pinned footer row
/// instead of a `List` entry (see the `ForEach` filter above).
enum NavSection: String, CaseIterable, Identifiable, Hashable {
    case transcriptions
    case actionItems
    case keyPoints
    case vocabulary
    case workspaces
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transcriptions: return "Transcriptions"
        case .actionItems: return "Action Items"
        case .keyPoints: return "Key Points"
        case .vocabulary: return "Vocabulary"
        case .workspaces: return "Workspaces"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .transcriptions: return "waveform"
        case .actionItems: return "checklist"
        case .keyPoints: return "lightbulb"
        case .vocabulary: return "text.book.closed"
        case .workspaces: return "briefcase"
        case .settings: return "gearshape"
        }
    }
}

#Preview {
    ContentView()
        .environment(LiveSessionStore.shared)
        .modelContainer(for: [TranscriptionSession.self, TranscriptionLine.self, ActionItem.self, Workspace.self], inMemory: true)
}

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
            List(selection: $section) {
                ForEach(NavSection.allCases) { item in
                    // Explicit scaling: the sidebar `List` is AppKit-backed and can
                    // ignore the inherited default font, so opt the row in directly.
                    Label(item.title, systemImage: item.symbol)
                        .appScaledFont(.body)
                        .tag(item)
                }
            }
            .navigationTitle("Open Captions")
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            .safeAreaInset(edge: .bottom) { SidebarSettingsFooter() }
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
            }
        }
    }
}

/// Top-level navigation sections shown in the sidebar. The enum makes adding
/// future destinations (settings, etc.) a one-line change.
enum NavSection: String, CaseIterable, Identifiable, Hashable {
    case transcriptions
    case actionItems
    case keyPoints
    case vocabulary
    case workspaces

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transcriptions: return "Transcriptions"
        case .actionItems: return "Action Items"
        case .keyPoints: return "Key Points"
        case .vocabulary: return "Vocabulary"
        case .workspaces: return "Workspaces"
        }
    }

    var symbol: String {
        switch self {
        case .transcriptions: return "waveform"
        case .actionItems: return "checklist"
        case .keyPoints: return "lightbulb"
        case .vocabulary: return "text.book.closed"
        case .workspaces: return "briefcase"
        }
    }
}

#Preview {
    ContentView()
        .environment(LiveSessionStore.shared)
        .modelContainer(for: [TranscriptionSession.self, TranscriptionLine.self, ActionItem.self, Workspace.self], inMemory: true)
}

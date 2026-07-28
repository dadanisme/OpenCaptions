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
    @Environment(MacAuthManager.self) private var auth
    @Environment(\.modelContext) private var modelContext
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
            .safeAreaInset(edge: .bottom) { SidebarProfileFooter() }
        } detail: {
            switch section ?? .transcriptions {
            case .transcriptions:
                // Scope to the effective owner: the uid when signed in, or the
                // "local" guest sentinel offline. Matches the id the save path
                // stamps, so a guest sees their own recordings.
                TranscriptionsScreen(userId: auth.ownerId)
            case .actionItems:
                // Same per-user scope: a read-only rollup of action items across
                // all of this owner's sessions.
                ActionItemsScreen(userId: auth.ownerId)
            case .keyPoints:
                // Same per-user scope: a read-only rollup of key points across
                // all of this owner's sessions.
                KeyPointsScreen(userId: auth.ownerId)
            case .vocabulary:
                // No user scope: the custom vocabulary is a device-local preference
                // (see `VocabularyStore`), not per-owner data.
                VocabularyScreen()
            }
        }
        // Claim any pre-auth (`userId == nil`) sessions for the signed-in user so
        // they show up in the scoped list. Re-runs when the user changes.
        .task(id: auth.userID) {
            guard let uid = auth.userID else { return }
            await SessionOwnerBackfill.run(container: modelContext.container, userId: uid)
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

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transcriptions: return "Transcriptions"
        case .actionItems: return "Action Items"
        case .keyPoints: return "Key Points"
        case .vocabulary: return "Vocabulary"
        }
    }

    var symbol: String {
        switch self {
        case .transcriptions: return "waveform"
        case .actionItems: return "checklist"
        case .keyPoints: return "lightbulb"
        case .vocabulary: return "text.book.closed"
        }
    }
}

#Preview {
    ContentView()
        .environment(MacAuthManager.shared)
        .environment(LiveSessionStore.shared)
        .modelContainer(for: [TranscriptionSession.self, TranscriptionLine.self, ActionItem.self], inMemory: true)
}

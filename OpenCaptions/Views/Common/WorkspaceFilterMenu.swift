//
//  WorkspaceFilterMenu.swift
//  OpenCaptions
//
//  The toolbar filter shared by every workspace-aware rollup — Transcriptions,
//  Action Items, Key Points: "All Workspaces" / "Unassigned" / one entry per
//  `Workspace`, sorted by name. Previously a private implementation detail of
//  `TranscriptionsScreen`; extracted so Action Items and Key Points can reach
//  the same behavior instead of re-implementing it.
//

import SwiftData
import SwiftUI

/// How a workspace-aware list is narrowed by workspace. Identifies a workspace
/// by `PersistentIdentifier` rather than holding the `Workspace` itself, since
/// `Workspace` has no `Equatable` conformance to compare `@State` against.
enum WorkspaceFilter: Hashable {
    case all
    case unassigned
    case workspace(PersistentIdentifier)

    /// Whether a session filed under `workspace` (nil for unassigned) passes
    /// this filter.
    func matches(_ workspace: Workspace?) -> Bool {
        switch self {
        case .all:
            return true
        case .unassigned:
            return workspace == nil
        case .workspace(let id):
            return workspace?.persistentModelID == id
        }
    }
}

struct WorkspaceFilterMenu: View {
    @Binding var filter: WorkspaceFilter
    let workspaces: [Workspace]

    var body: some View {
        Menu {
            Button {
                filter = .all
            } label: {
                filterLabel("All Workspaces", isSelected: filter == .all)
            }
            Button {
                filter = .unassigned
            } label: {
                filterLabel("Unassigned", isSelected: filter == .unassigned)
            }
            if !workspaces.isEmpty {
                Divider()
                ForEach(workspaces) { workspace in
                    Button {
                        filter = .workspace(workspace.persistentModelID)
                    } label: {
                        filterLabel(workspace.name, isSelected: filter == .workspace(workspace.persistentModelID))
                    }
                }
            }
        } label: {
            Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
        }
        .help("Filter by workspace")
    }

    @ViewBuilder
    private func filterLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}

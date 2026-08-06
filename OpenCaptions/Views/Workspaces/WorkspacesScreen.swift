//
//  WorkspacesScreen.swift
//  OpenCaptions
//
//  The "Workspaces" sidebar section: create/rename/delete the workspaces sessions
//  can be filed under, and optionally give each its own export folder. A full-width
//  sidebar destination rather than a Settings pane for the same reason Vocabulary
//  is: it's a variable-length list editor, which the fixed Settings window can't
//  host comfortably.
//
//  Pure manager — it doesn't also render a filtered session list. Filtering by
//  workspace lives on the Transcriptions screen's own toolbar; assigning a session
//  to a workspace happens from there and from the session detail toolbar.
//  See docs/2026-08-06-macos-workspaces.md.
//

import SwiftData
import SwiftUI

struct WorkspacesScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var workspaces: [Workspace]

    private let userId: String
    /// Presents the add-workspace sheet, opened from the toolbar's + button.
    @State private var isAddingWorkspace = false
    /// Non-nil presents the rename sheet for exactly this workspace.
    @State private var renameTarget: Workspace?
    /// Non-nil presents the delete confirmation for exactly this workspace.
    @State private var pendingDeletion: Workspace?

    /// Scopes the workspace list to the signed-in user, the same
    /// custom-`init`-plus-`#Predicate` pattern `TranscriptionsScreen` uses (a
    /// `@Query`'s default initializer can't read a runtime value).
    init(userId: String) {
        self.userId = userId
        _workspaces = Query(
            filter: #Predicate<Workspace> { $0.userId == userId },
            sort: \.name
        )
    }

    var body: some View {
        NavigationStack {
            listContent
                .navigationTitle("Workspaces")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isAddingWorkspace = true
                        } label: {
                            Label("Add Workspace", systemImage: "plus")
                        }
                        .help("Add a workspace")
                    }
                }
        }
        .sheet(isPresented: $isAddingWorkspace) {
            WorkspaceNameSheet(title: "Add Workspace", confirmTitle: "Add") { name in
                createWorkspace(named: name)
            }
        }
        .sheet(item: $renameTarget) { workspace in
            WorkspaceNameSheet(title: "Rename Workspace", confirmTitle: "Rename", initialName: workspace.name) { newName in
                workspace.name = newName
                try? modelContext.save()
            }
        }
        .confirmationDialog(
            "Delete this workspace?",
            isPresented: isDeletionPresented,
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { workspace in
            Button("Delete", role: .destructive) { performDelete(workspace) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its sessions aren't deleted — they move back to the default export location and lose this workspace.")
        }
    }

    @ViewBuilder
    private var listContent: some View {
        if workspaces.isEmpty {
            ContentUnavailableView(
                "No Workspaces",
                systemImage: "briefcase",
                description: Text("Tap + to create a workspace to file sessions under, and optionally route its exported files to their own folder.")
            )
        } else {
            List {
                ForEach(workspaces) { workspace in
                    workspaceRow(workspace)
                        .contextMenu { contextMenu(for: workspace) }
                }
            }
        }
    }

    private func createWorkspace(named name: String) {
        let workspace = Workspace(name: name, userId: userId)
        modelContext.insert(workspace)
        try? modelContext.save()
    }

    private func workspaceRow(_ workspace: Workspace) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(workspace.name)
                .appScaledFont(.headline)
            Text(folderDisplayPath(workspace))
                .appScaledFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }

    private func folderDisplayPath(_ workspace: Workspace) -> String {
        // A non-mutating peek — `resolvedExportRoot()` self-heals a stale/dead
        // bookmark by writing back to the model, which a view body must not do
        // as a side effect of rendering.
        workspace.displayExportRoot()?.displayPath ?? "Default location"
    }

    @ViewBuilder
    private func contextMenu(for workspace: Workspace) -> some View {
        Button("Rename…") { renameTarget = workspace }

        Button(workspace.exportBookmark == nil ? "Choose Export Folder…" : "Change Export Folder…") {
            Task { await workspace.chooseExportFolder() }
        }

        if workspace.exportBookmark != nil {
            Button("Reveal Folder") { workspace.revealExportFolder() }
            Button("Use Default Location") {
                Task { await workspace.clearExportFolder() }
            }
        }

        Divider()
        Button("Delete", role: .destructive) { pendingDeletion = workspace }
    }

    private func performDelete(_ workspace: Workspace) {
        Task {
            await SessionExportCoordinator.deleteWorkspace(workspace, context: modelContext)
        }
        pendingDeletion = nil
    }

    private var isDeletionPresented: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }
}

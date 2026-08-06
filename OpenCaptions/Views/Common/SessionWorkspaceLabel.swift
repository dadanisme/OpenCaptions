//
//  SessionWorkspaceLabel.swift
//  OpenCaptions
//
//  The workspace a session is filed under, shown as a small icon + name next to
//  the date on session list rows. Renders NOTHING when the session has no
//  workspace — the normal case, since assigning one is optional — matching
//  `SessionSpeakersLine`'s "nothing to show" convention so it never reserves
//  extra space or reads as a placeholder.
//

import SwiftUI

struct SessionWorkspaceLabel: View {
    let session: TranscriptionSession

    var body: some View {
        if let workspace = session.workspace {
            HStack(spacing: 3) {
                // Same glyph as the Workspaces sidebar item, so the two read as
                // the same concept at a glance.
                Image(systemName: "briefcase.fill")
                Text(workspace.name)
            }
            .appScaledFont(.caption)
            .lineLimit(1)
        }
    }
}

//
//  MacMarkdownExportSection.swift
//  OpenCaptions
//
//  Settings → General → "Markdown Export": where every session is mirrored to disk.
//
//  Its own file rather than another `Section` inside `MacSettingsView` because it
//  has real behaviour (a picker, an async relocate, a busy state) and that file is
//  already near the ~250-line limit. There is no enable/disable toggle — export is
//  always on; this row only changes WHERE it writes.
//  See docs/2026-07-31-macos-markdown-export.md.
//

import SwiftData
import SwiftUI

struct MacMarkdownExportSection: View {
    @State private var location = MarkdownExportLocation.shared

    var body: some View {
        Section("Markdown Export") {
            LabeledContent("Folder") {
                HStack(spacing: 8) {
                    Text(location.root.displayPath)
                        .appScaledFont(.caption)
                        .foregroundStyle(.secondary)
                        // Middle truncation keeps the folder NAME readable, which is
                        // the part that identifies the location; the leading path
                        // components are the expendable half.
                        .truncationMode(.middle)
                        .lineLimit(1)
                        .help(location.root.displayPath)
                        .frame(maxWidth: .infinity, alignment: .trailing)

                    Button("Reveal") { location.revealInFinder() }
                    Button("Browse…") {
                        Task { await location.chooseFolder(container: LiveSessionStore.shared.modelContainer) }
                    }
                    .disabled(location.isRelocating)
                }
            }
            if location.isRelocating {
                // The move is a file copy per session; on a big library with mirrored
                // audio that is not instant, and a silent freeze would read as a hang.
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Moving your existing sessions…").appScaledFont(.caption)
                }
                .foregroundStyle(.secondary)
            }
            Text(footnote)
                .appScaledFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footnote: String {
        let shared = "Every session is written here as a dated folder containing transcript.md, summary.md once a summary exists, and a copy of the session audio. Files are kept in step automatically — renamed when a session is retitled, and removed when you delete it."
        guard location.isDefaultLocation else { return shared }
        return shared + " Right now they go to Open Captions' own storage, which is awkward to reach — choose a folder like your Documents to keep them somewhere you can open, sync, or search."
    }
}

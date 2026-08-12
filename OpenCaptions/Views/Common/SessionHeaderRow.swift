//
//  SessionHeaderRow.swift
//  OpenCaptions
//
//  Session grouping row shared by the Action Items and Key Points lists — the
//  first row of each section, tappable to open the source session. Rendered as a
//  plain row rather than a pinned `Section` header, styled to read like the
//  Transcriptions list. The two screens previously hand-duplicated this exact view.
//

import SwiftUI

struct SessionHeaderRow: View {
    let session: TranscriptionSession
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.sessionTitle)
                        .appScaledFont(.headline)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(session.sessionDate, format: .dateTime.month().day().hour().minute())
                            .appScaledFont(.caption)
                        SessionWorkspaceLabel(session: session)
                        SessionSpeakersLine(session: session)
                    }
                    .foregroundStyle(.tertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .appScaledFont(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }
}

//
//  SessionSpeakersLine.swift
//  OpenCaptions
//
//  The "who was in this session" summary (e.g. "Yoga, Abby, and 2 more") shown
//  next to the date on session list rows, dot-separated. Renders NOTHING when
//  the session has no diarized speakers — the normal case for an on-device engine — so
//  it never reads as a loading/error placeholder and reserves no extra space.
//  Shared by the Transcriptions, Action Items, and Key Points lists.
//

import SwiftUI

struct SessionSpeakersLine: View {
    let session: TranscriptionSession

    var body: some View {
        if !session.resolvedSpeakerNamesSummary.isEmpty {
            Text("· \(session.resolvedSpeakerNamesSummary)")
                .appScaledFont(.caption)
                .lineLimit(1)
        }
    }
}

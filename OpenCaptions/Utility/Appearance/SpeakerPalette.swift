//
//  SpeakerPalette.swift
//  OpenCaptions
//
//  Shared speaker → color mapping for diarized transcripts. Kept in one place so
//  the main live transcript (`MacLiveTranscriptionView`) and the floating
//  captions overlay (`CaptionsOverlayView`) color the same speaker identically.
//

import SwiftUI

enum SpeakerPalette {
    /// Deterministic color for a diarized speaker id. Positive ids (1, 2, …) map
    /// into a fixed palette; the `-1`/`0` sentinels (unknown / pre-diarization)
    /// fall back to a neutral secondary tint.
    static func color(for speaker: Int) -> Color {
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal]
        guard speaker > 0 else { return .secondary }
        return palette[(speaker - 1) % palette.count]
    }
}

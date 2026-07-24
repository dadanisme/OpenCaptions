//
//  TimestampFormatter.swift
//  OpenCaptions
//
//  Shared formatting for session-relative elapsed/offset timestamps.
//

import Foundation

/// Formats session-relative offsets (relative to session start) as `h:mm:ss`.
///
/// This is for elapsed/offset timestamps only — distinct from wall-clock date
/// formatting (`h:mm a`) and duration displays, which are formatted separately.
enum TimestampFormatter {
    /// Formats a millisecond offset as `h:mm:ss` (e.g. `0:03:07`).
    static func hms(fromMs ms: Int) -> String {
        hms(fromSeconds: max(0, ms) / 1000)
    }

    /// Formats a seconds-based interval as `h:mm:ss` (e.g. `0:03:07`).
    static func hms(from interval: TimeInterval) -> String {
        hms(fromSeconds: max(0, Int(interval)))
    }

    private static func hms(fromSeconds totalSeconds: Int) -> String {
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
}

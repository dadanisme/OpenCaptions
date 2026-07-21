//
//  SessionAudioOrphanSweep.swift
//  OpenCaptions
//
//  Launch-time cleanup of recorded-audio files no saved session references —
//  clears partial/unplayable files left by a crash or a never-saved recording.
//  Mirrors `SessionOwnerBackfill`'s detached-context launch pattern.
//

import Foundation
import SwiftData

enum SessionAudioOrphanSweep {
    /// Deletes every `.m4a` in the audio directory not referenced by a session.
    /// Runs on a background context. Bails if the fetch fails (never sweeps on a
    /// spurious error, which would otherwise wipe still-referenced recordings).
    static func run(container: ModelContainer) async {
        // A recording in progress isn't referenced by any saved row yet
        // (audioFileName is stamped only at save), so read the live filename and
        // include it — otherwise a recording started during launch (e.g. a menu-bar
        // quick start, between the caller's not-active check and this awaited sweep)
        // could have its still-open file deleted out from under the writer.
        let inFlight = await MainActor.run { LiveSessionStore.shared.viewModel?.audioFileName }
        let task = Task.detached(priority: .utility) {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<TranscriptionSession>(
                predicate: #Predicate { $0.audioFileName != nil }
            )
            guard let sessions = try? context.fetch(descriptor) else { return }
            var referenced = Set(sessions.compactMap(\.audioFileName))
            if let inFlight { referenced.insert(inFlight) }
            SessionAudioStore.sweepOrphans(referenced: referenced)
        }
        await task.value
    }
}

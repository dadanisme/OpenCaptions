//
//  DerivedFieldsBackfill.swift
//  OpenCaptions
//
//  One-time launch migration: recomputes the cached list-card fields
//  (`durationMs`, `previewText`, `speakerNamesSummary`) for legacy sessions that
//  predate one of them. Cheap no-op once every session has been computed.
//

import Foundation
import SwiftData

enum DerivedFieldsBackfill {
    static func run(container: ModelContainer) async {
        let task = Task.detached(priority: .utility) {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<TranscriptionSession>(
                predicate: #Predicate { $0.speakerNamesSummary == nil }
            )

            guard let sessions = try? context.fetch(descriptor), !sessions.isEmpty else { return }

            for session in sessions {
                session.recomputeDerivedFields()
            }

            do {
                try context.save()
                print("✅ Backfilled derived fields for \(sessions.count) session(s)")
            } catch {
                print("❌ Derived-fields backfill failed: \(error.localizedDescription)")
            }
        }
        await task.value
    }
}

//
//  SpeakerNameResolver.swift
//  OpenCaptions
//
//  Turns the summary response's speaker predictions into the `[id: name]` edit
//  dictionary `SpeakerRenamer` persists. This is the ONLY place the two confidence
//  thresholds live — the model is never told what they are, it just reports
//  calibrated confidence and the app decides.
//  See docs/2026-07-29-macos-speaker-auto-naming.md.
//

import Foundation

enum SpeakerNameResolver {

    // MARK: - Thresholds

    /// A lone candidate above this confidence renames the speaker outright
    /// ("Speaker 1" → "Ramdan"). Deliberately high: a confidently wrong name is
    /// worse than an honest generic label, and there is no undo.
    private static let confidentThreshold: Double = 0.85

    /// Floor for a candidate to be worth showing at all. Between this and
    /// `confidentThreshold` the speaker is treated as unresolved-but-narrowed, and
    /// every survivor is joined; below it, the generic label stays.
    private static let plausibleThreshold: Double = 0.35

    /// Joins the survivors when the model couldn't settle on one name
    /// ("Speaker 2" → "Simon/Sam").
    private static let candidateSeparator = "/"

    // MARK: - Resolve

    /// Maps the model's predictions to `[speakerId: newName]`, keeping only the ids
    /// it named with enough confidence. Never throws and never partially fails: an
    /// unusable prediction is dropped, so `[:]` (no renames) is a normal result.
    static func resolve(_ identifications: [SpeakerIdentification]) -> [Int: String] {
        var names: [Int: String] = [:]
        for identification in identifications {
            // Non-positive ids aren't real speakers — `-1` means the session wasn't
            // diarized at all, and a stray `0` is invisible to the speaker editor —
            // so they're never renameable no matter how sure the model is.
            guard identification.speakerId > 0 else { continue }
            guard let name = name(from: identification.candidates ?? []) else { continue }
            names[identification.speakerId] = name
        }
        return names
    }

    /// Applies the threshold rules to one speaker's candidates:
    /// - exactly one candidate above `confidentThreshold` → that name alone;
    /// - otherwise every candidate above `plausibleThreshold`, slash-joined;
    /// - nothing above `plausibleThreshold` → `nil` (keep the generic label).
    ///
    /// The "exactly one" test is what keeps both thresholds load-bearing: a clear
    /// winner wins outright even when a weaker candidate also clears the floor,
    /// while two equally confident contradictory names surface as "Simon/Sam"
    /// rather than being silently picked between.
    private static func name(from candidates: [SpeakerIdentification.Candidate]) -> String? {
        // Sorted by descending confidence so the joined list reads most-likely-first.
        // A NaN confidence fails every comparison below and is dropped — the safe
        // direction, since it can only ever mean "don't rename".
        let ranked = deduplicated(candidates).sorted { $0.confidence > $1.confidence }

        let confident = ranked.filter { $0.confidence > confidentThreshold }
        if confident.count == 1, let winner = confident.first {
            return winner.name
        }

        let plausible = ranked.filter { $0.confidence > plausibleThreshold }
        guard !plausible.isEmpty else { return nil }
        return plausible.map(\.name).joined(separator: candidateSeparator)
    }

    /// Trims each name, drops the blank ones, and collapses case-insensitive
    /// duplicates onto their highest-confidence occurrence — the model can list the
    /// same name twice, and "Sam/Sam" is not a speaker name.
    private static func deduplicated(
        _ candidates: [SpeakerIdentification.Candidate]
    ) -> [SpeakerIdentification.Candidate] {
        var best: [String: SpeakerIdentification.Candidate] = [:]
        var order: [String] = []
        for candidate in candidates {
            let name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = name.lowercased()
            if let existing = best[key] {
                guard candidate.confidence > existing.confidence else { continue }
            } else {
                order.append(key)
            }
            best[key] = .init(name: name, confidence: candidate.confidence)
        }
        return order.compactMap { best[$0] }
    }
}

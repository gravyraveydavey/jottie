import Foundation
import JottieModels

extension LibraryStore {
    /// Commit before the capture transcript marker, so a failed evidence write preserves audio for retry.
    public func saveVoiceEvidence(_ evidence: VoiceEvidence) throws {
        try locked {
            let settings = try settings()
            guard settings.voiceLearningEnabled, settings.bambooEnabled, evidence.company == settings.bambooCompany,
                  evidence.generation == settings.voiceLearningGeneration else { return } // consent changed during capture
            try VoiceEvidenceStorage(root: root, testKey: voiceStorageKey).save(evidence)
        }
    }

    public func eraseVoiceprints() throws {
        var settings = try settings()
        settings.voiceLearningEnabled = false; settings.voiceAutoAssign = false; settings.voiceLearningGeneration = UUID().uuidString
        try saveSettings(settings)
        try locked { try VoiceEvidenceStorage(root: root, testKey: voiceStorageKey).erase() }
        _ = try applyVoiceMatches(people: [], configuration: try self.settings())
    }

    /// Rebuild profiles from durable evidence + current explicit corrections. No automatic self-enrollment.
    /// Recomputing makes retraction, restart and interrupted batches idempotent, without a second identity authority.
    @discardableResult public func refreshVoiceMatches() async throws -> VoiceprintReport {
        let configuration = try settings()
        var people: [DirectoryPerson] = []
        if configuration.voiceLearningEnabled && configuration.bambooEnabled {
            people = try await PeopleDirectory(root: root).snapshot(company: configuration.bambooCompany).people
        }
        return try applyVoiceMatches(people: people, configuration: configuration)
    }

    private struct Enrollment {
        var person: DirectoryPerson
        var company: String
        var modelID: String
        var vectors: [[Float]]
        var references: [String]
        var profileID: String { Codec.hash(company + "\n" + person.id + "\n" + modelID) }
        var revision: String { Codec.hash(references.sorted().joined(separator: "\n")) }
    }

    private struct WindowScore {
        var sample: VoiceSample
        var profile: Enrollment
        var similarity: Double
        var runnerUpName: String?
        var runnerUpSimilarity: Double?
        var margin: Double
        var supportKey: String { track + ":" + profile.profileID }
        var track: String { String(sample.speaker.split(separator: " ").first ?? "") }
    }

    private func score(_ sample: VoiceSample, profiles: [Enrollment]) -> WindowScore? {
        var ranked: [(Enrollment, Double)] = []
        for profile in profiles {
            let scores = profile.vectors.map { VoiceSimilarity.cosine(sample.embedding, $0) }.sorted()
            guard !scores.isEmpty else { continue }
            ranked.append((profile, scores[scores.count / 2]))
        }
        ranked.sort { $0.1 == $1.1 ? $0.0.profileID < $1.0.profileID : $0.1 > $1.1 }
        guard let best = ranked.first else { return nil }
        let second = ranked.dropFirst().first
        return WindowScore(sample: sample, profile: best.0, similarity: best.1,
            runnerUpName: second?.0.person.name, runnerUpSimilarity: second?.1, margin: best.1 - (second?.1 ?? 0))
    }

    private func matchWindows(meeting: Meeting, record: VoiceEvidence, profiles: [Enrollment], tuning: VoiceTuning)
        -> (matches: [String: SpeakerAttribution], diagnostics: [VoiceDiagnostic]) {
        let independent = Self.independent(record.samples.filter { !record.passages(for: $0).isEmpty })
        let usable = independent.filter { !record.passages(for: $0).isEmpty }
        let compatible = profiles.filter { $0.modelID == record.modelID }
        let scores = usable.compactMap { score($0, profiles: compatible) }
        func protected(_ score: WindowScore) -> Bool {
            if meeting.speakerNames[score.sample.speaker]?.isEmpty == false || meeting.hasNamedSourceLabel(score.sample.speaker) { return true }
            return record.passages(for: score.sample).contains { passage in
                guard let assignment = meeting.speakerAttributions?[passage.id], assignment.method == "manual" else { return false }
                return assignment.name.isEmpty || assignment.employeeID != score.profile.person.id
            }
        }
        let eligible = scores.filter { $0.similarity >= tuning.matchSimilarity && $0.margin >= tuning.matchMargin && !protected($0) }
        // Agreeing windows can support one another across over-split labels on the same track.
        // Window identities are still decided individually; a neighbouring label cannot force a match.
        let support = Dictionary(grouping: eligible, by: \.supportKey)
        var matches: [String: SpeakerAttribution] = [:]
        var matchedLabels = Set<String>()
        for group in support.values where group.count >= tuning.minimumMatchingWindows {
            guard let first = group.first else { continue }
            let covered = record.coveredPassageIDs(by: group.map(\.sample))
            var attribution = SpeakerAttribution(name: first.profile.person.name, jobTitle: first.profile.person.jobTitle,
                employeeID: first.profile.person.id, method: "voice", basis: ["local_voice_match"])
            attribution.voiceMatch = VoiceMatch(profileID: first.profile.profileID, company: first.profile.company,
                modelID: record.modelID, profileRevision: first.profile.revision,
                similarity: group.map(\.similarity).min() ?? 0, margin: group.map(\.margin).min() ?? 0, sampleCount: group.count)
            for segment in meeting.segments {
                let sourceIDs = meeting.transcriptSourceSegmentIDs?[segment.id] ?? [segment.id]
                guard !sourceIDs.isEmpty, sourceIDs.allSatisfy(covered.contains),
                      meeting.speakerAttributions?[segment.id]?.method != "manual",
                      meeting.speakerNames[segment.speaker]?.isEmpty != false, !meeting.hasNamedSourceLabel(segment.speaker) else { continue }
                matches[segment.id] = attribution; matchedLabels.insert(segment.speaker)
            }
        }
        var diagnostics: [VoiceDiagnostic] = []
        for label in Set(meeting.originalTranscript.map(\.speaker)).sorted() {
            let raw = record.samples.filter { $0.speaker == label }
            let own = scores.filter { $0.sample.speaker == label }
            let accepted = eligible.filter { $0.sample.speaker == label }
            var item = VoiceDiagnostic(speaker: label, storedWindows: raw.count,
                usableWindows: usable.filter { $0.speaker == label }.count, reason: "No usable saved windows")
            if let first = own.first {
                let names = Set(own.map { $0.profile.person.name })
                item.bestName = names.count == 1 ? first.profile.person.name : "Different candidates across windows"
                item.similarity = own.map(\.similarity).min()
                let strongestCompetitor = own.max { ($0.runnerUpSimilarity ?? -1) < ($1.runnerUpSimilarity ?? -1) }
                item.runnerUpName = strongestCompetitor?.runnerUpName
                item.runnerUpSimilarity = strongestCompetitor?.runnerUpSimilarity
                item.margin = own.map(\.margin).min()
                item.supportingWindows = accepted.map { support[$0.supportKey]?.count ?? 0 }.max() ?? 0
                if own.allSatisfy(protected) { item.reason = "Manual correction retained" }
                else if accepted.isEmpty {
                    item.reason = own.allSatisfy({ $0.similarity < tuning.matchSimilarity }) ? "Below voice-match similarity" : "Similarity or lead over next person is too small"
                } else if item.supportingWindows < tuning.minimumMatchingWindows {
                    item.reason = "Too few independent supporting windows (need \(tuning.minimumMatchingWindows))"
                } else { item.reason = matchedLabels.contains(label) ? "Matched covered passages" : "Only manual or insufficiently covered passages remain" }
            } else if item.usableWindows > 0 {
                item.reason = profiles.isEmpty ? "No enrolled profile: assign at least two usable windows to a directory person" : "No enrolled profile for this embedding model"
            }
            diagnostics.append(item)
        }
        return (matches, diagnostics)
    }

    private func applyVoiceMatches(people: [DirectoryPerson], configuration: LibrarySettings) throws -> VoiceprintReport {
        try locked {
            let settings = try self.settings()
            guard settings == configuration else { throw JottieError.conflict("Voice learning settings changed. Retry re-evaluation.") }
            let all = try meetings()
            let storage = VoiceEvidenceStorage(root: root, testKey: voiceStorageKey)
            let byID = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })
            var records: [UUID: VoiceEvidence] = [:]
            if settings.voiceLearningEnabled && settings.bambooEnabled {
                for meeting in all {
                    guard let record = try storage.load(meeting.sourceID), record.company == settings.bambooCompany,
                          record.generation == settings.voiceLearningGeneration, record.originalSegments == meeting.originalTranscript else { continue }
                    records[meeting.id] = record
                }
            }
            var profiles: [String: Enrollment] = [:]
            for meeting in all {
                guard let record = records[meeting.id] else { continue }
                for sample in Self.independent(record.samples.filter { !record.passages(for: $0).isEmpty }) {
                    let passages = record.passages(for: sample)
                    guard !passages.isEmpty else { continue }
                    let assignments = passages.compactMap { meeting.speakerAttributions?[$0.id] }
                    guard assignments.count == passages.count, assignments.allSatisfy({ $0.method == "manual" && !$0.name.isEmpty }),
                          let employeeID = assignments.first?.employeeID, assignments.allSatisfy({ $0.employeeID == employeeID }),
                          let person = byID[employeeID] else { continue }
                    let id = Codec.hash(record.company + "\n" + employeeID + "\n" + record.modelID)
                    var profile = profiles[id] ?? Enrollment(person: person, company: record.company, modelID: record.modelID, vectors: [], references: [])
                    guard profile.vectors.count < 32 else { continue }
                    profile.vectors.append(sample.embedding)
                    profile.references.append(meeting.sourceID + ":" + sample.id)
                    profiles[id] = profile
                }
            }
            // Independent windows, not overlapping copies of the same utterance.
            profiles = profiles.filter { $0.value.vectors.count >= 2 }
            var report = VoiceprintReport()
            report.usableWindows = records.mapValues { record in Self.independent(record.samples.filter { !record.passages(for: $0).isEmpty }).count }
            report.recordings = records.count; report.enrolledPeople = Set(profiles.values.map { $0.person.id }).count
            for meeting in all {
                var updated = meeting
                var assignments = (meeting.speakerAttributions ?? [:]).filter { $0.value.method != "voice" }
                var suggestions: [String: SpeakerAttribution] = [:]
                if let record = records[meeting.id] {
                    let result = matchWindows(meeting: meeting, record: record, profiles: Array(profiles.values), tuning: settings.voiceTuning)
                    report.diagnostics[meeting.id] = result.diagnostics
                    report.captureTuning[meeting.id] = record.captureTuning
                    report.matchedPassages += result.matches.count
                    if settings.voiceAutoAssign { assignments.merge(result.matches) { _, voice in voice } }
                    else { suggestions = result.matches }
                } else if settings.voiceLearningEnabled {
                    report.diagnostics[meeting.id] = [VoiceDiagnostic(speaker: "recording", storedWindows: 0, usableWindows: 0,
                        reason: "No compatible saved voice evidence. Deleted audio cannot be separated again.")]
                }
                updated.speakerAttributions = assignments.isEmpty ? nil : assignments
                updated.voiceSuggestions = suggestions.isEmpty ? nil : suggestions
                if updated.speakerAttributions != meeting.speakerAttributions || updated.voiceSuggestions != meeting.voiceSuggestions {
                    try commit(updated); report.changedMeetings += 1
                }
            }
            return report
        }
    }

    /// Deterministic, non-overlapping selection per audio track, retaining source contribution IDs.
    private static func independent(_ samples: [VoiceSample]) -> [VoiceSample] {
        var ends: [String: Int] = [:]
        return samples.sorted { $0.startMS == $1.startMS ? $0.id < $1.id : $0.startMS < $1.startMS }.filter { sample in
            guard sample.isValid, sample.startMS >= ends[String(sample.speaker.split(separator: " ").first ?? ""), default: 0] else { return false }
            ends[String(sample.speaker.split(separator: " ").first ?? "")] = sample.endMS
            return true
        }
    }
}

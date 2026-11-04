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

    private struct ScoredEnrollment {
        var profile: Enrollment
        var scores: [Double]
        var similarity: Double { scores.min() ?? -1 }
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
                for sample in Self.independent(record.samples) {
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
            report.usableWindows = records.mapValues { record in Self.independent(record.samples).filter { !record.passages(for: $0).isEmpty }.count }
            report.recordings = records.count; report.enrolledPeople = Set(profiles.values.map { $0.person.id }).count
            for meeting in all {
                var updated = meeting
                var assignments = (meeting.speakerAttributions ?? [:]).filter { $0.value.method != "voice" }
                var suggestions: [String: SpeakerAttribution] = [:]
                if let record = records[meeting.id] {
                    let groups = Dictionary(grouping: Self.independent(record.samples), by: \.speaker)
                    for (speaker, windows) in groups {
                        guard meeting.speakerNames[speaker]?.isEmpty != false else { continue }
                        let usable = windows.filter { !record.passages(for: $0).isEmpty }
                        guard usable.count >= 2 else { continue }
                        var candidates: [ScoredEnrollment] = []
                        for profile in profiles.values where profile.modelID == record.modelID {
                            var windowScores: [Double] = []
                            for sample in usable {
                                var scores: [Double] = []
                                for vector in profile.vectors { scores.append(VoiceSimilarity.cosine(sample.embedding, vector)) }
                                scores.sort()
                                windowScores.append(scores[scores.count / 2])
                            }
                            candidates.append(ScoredEnrollment(profile: profile, scores: windowScores))
                        }
                        candidates.sort { left, right in
                            if left.similarity == right.similarity { return left.profile.profileID < right.profile.profileID }
                            return left.similarity > right.similarity
                        }
                        guard let best = candidates.first, best.similarity >= 0.80 else { continue }
                        var margin = 2.0
                        for index in usable.indices {
                            let runnerUp = candidates.dropFirst().map { $0.scores[index] }.max() ?? 0
                            margin = min(margin, best.scores[index] - runnerUp)
                        }
                        guard margin >= 0.12 else { continue }
                        // A confirmed different identity on the same acoustic cluster invalidates propagation.
                        let passages = meeting.segments.filter { $0.speaker == speaker }
                        guard !passages.contains(where: {
                            guard let manual = assignments[$0.id], manual.method == "manual" else { return false }
                            return manual.name.isEmpty || manual.employeeID != best.profile.person.id
                        }) else { continue }
                        var attribution = SpeakerAttribution(name: best.profile.person.name, jobTitle: best.profile.person.jobTitle,
                            employeeID: best.profile.person.id, method: "voice", basis: ["local_voice_match"])
                        attribution.voiceMatch = VoiceMatch(profileID: best.profile.profileID, company: best.profile.company,
                            modelID: record.modelID, profileRevision: best.profile.revision, similarity: best.similarity,
                            margin: margin, sampleCount: usable.count)
                        // Only covered original passages; don't spread a name across an entire possibly merged cluster.
                        let covered = record.coveredPassageIDs(by: usable)
                        for segment in meeting.segments {
                            let sourceIDs = meeting.transcriptSourceSegmentIDs?[segment.id] ?? [segment.id]
                            guard segment.speaker == speaker, !sourceIDs.isEmpty, sourceIDs.allSatisfy(covered.contains),
                                  assignments[segment.id]?.method != "manual", !meeting.hasNamedSourceLabel(segment.speaker) else { continue }
                            if settings.voiceAutoAssign { assignments[segment.id] = attribution }
                            else { suggestions[segment.id] = attribution }
                            report.matchedPassages += 1
                        }
                    }
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

    /// Deterministic, non-overlapping selection per track/cluster, retaining source contribution IDs.
    private static func independent(_ samples: [VoiceSample]) -> [VoiceSample] {
        var ends: [String: Int] = [:]
        return samples.sorted { $0.startMS == $1.startMS ? $0.id < $1.id : $0.startMS < $1.startMS }.filter { sample in
            guard sample.isValid, sample.startMS >= ends[sample.speaker, default: 0] else { return false }
            ends[sample.speaker] = sample.endMS
            return true
        }
    }
}

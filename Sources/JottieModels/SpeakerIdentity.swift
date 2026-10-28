import Foundation

/// Locally generated hints, never unique identifiers. Shared nicknames remain shared.
public enum NameAliases {
    public static func normalise(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    public static func generated(for name: String) -> [String] {
        let parts = name.split(separator: " ").map(String.init)
        guard let first = parts.first, parts.count > 1, let last = parts.last else { return [name] }
        let groups = [["David", "Dave", "Davey"], ["Fiona", "Fi"], ["Jonathan", "Jonathon", "Jon", "Johnathan"],
                      ["John", "Johnny"], ["James", "Jim", "Jimmy"], ["Robert", "Rob", "Bob"],
                      ["Elizabeth", "Liz", "Beth"], ["Michael", "Mike"], ["Katherine", "Kate", "Katie"]]
        let given = groups.first { $0.contains { normalise($0) == normalise(first) } } ?? [first]
        let surnames = [["Welch", "Welsh"], ["Barrett", "Barret"]].first { $0.contains { normalise($0) == normalise(last) } } ?? [last]
        return Array(Set([name, first, last] + given + surnames + given.flatMap { f in surnames.map { f + " " + $0 } })).sorted()
    }
    public static func all(name: String, aliases: [String]?) -> [String] {
        Array(Set(generated(for: name) + (aliases ?? []))).sorted()
    }
    public static func mentions(_ alias: String, in text: String) -> Bool {
        let needle = normalise(alias)
        return !needle.isEmpty && (" " + normalise(text) + " ").contains(" " + needle + " ")
    }
}

public struct SpeakerAttribution: Codable, Sendable, Equatable {
    public var name: String
    public var jobTitle: String?
    public var employeeID: String?
    public var method: String // manual or analysis
    public var confidence: Double?
    public var basis: [String]
    public var evidence: [Evidence]
    public var analysisRevision: String?
    public init(name: String, jobTitle: String? = nil, employeeID: String? = nil, method: String,
                confidence: Double? = nil, basis: [String] = [], evidence: [Evidence] = [], analysisRevision: String? = nil) {
        self.name = name; self.jobTitle = jobTitle; self.employeeID = employeeID; self.method = method
        self.confidence = confidence; self.basis = basis; self.evidence = evidence; self.analysisRevision = analysisRevision
    }
}

public struct ReconciledSpeaker: Identifiable, Sendable {
    public var id: String
    public var label: String
    public var name: String
    public var jobTitle: String?
    public var employeeID: String?
    public var segmentIDs: [String]
    public var sources: [String]
    public var evidence: [Evidence]
    public var inferred: Bool
}

public struct InvitedSpeakerStatus: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var role: String?
    public var mentioned: Bool
}

public extension Meeting {
    func attribution(for segment: Segment) -> SpeakerAttribution? {
        if let value = speakerAttributions?[segment.id], value.method == "manual" { return value.name.isEmpty ? nil : value }
        if let name = speakerNames[segment.speaker], !name.isEmpty {
            return SpeakerAttribution(name: name, jobTitle: speakerRoles?[segment.speaker], method: "manual")
        }
        if hasNamedSourceLabel(segment.speaker) { return SpeakerAttribution(name: segment.speaker, method: "transcript") }
        return speakerAttributions?[segment.id].flatMap { $0.name.isEmpty ? nil : $0 }
    }
    func hasNamedSourceLabel(_ label: String) -> Bool {
        let words = NameAliases.normalise(label).split(separator: " ")
        let reserved = ["speaker", "voice", "them", "me", "remote", "system", "unknown", "unidentified", "participant"]
        return words.count >= 2 && !reserved.contains(String(words[0])) && !label.contains(where: \.isNumber)
    }
    func unknownSpeakerName(_ label: String) -> String {
        let labels = Array(Set(segments.map(\.speaker))).sorted()
        return "Speaker \((labels.firstIndex(of: label) ?? 0) + 1)" + (label == "me" ? " (you)" : "")
    }
    func speakerName(for segment: Segment) -> String { attribution(for: segment)?.name ?? unknownSpeakerName(segment.speaker) }
    var displaySpeakerNames: [String: String] {
        let labels = Array(Set(segments.map(\.speaker))).sorted()
        let unknown = Dictionary(uniqueKeysWithValues: labels.enumerated().map { ($0.element, "Speaker \($0.offset + 1)" + ($0.element == "me" ? " (you)" : "")) })
        return Dictionary(uniqueKeysWithValues: segments.map { ($0.id, attribution(for: $0)?.name ?? unknown[$0.speaker] ?? "Unknown speaker") })
    }
    var undetectedInvitees: [InvitedSpeakerStatus] {
        let detected = reconciledSpeakers
        var seen = Set<String>()
        let roster = participants.map { invitee in
            let person = participantContext?.first { $0.invitee == invitee }
            let name = person?.name ?? invitee.split(separator: "<").first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? invitee
            return (invitee: invitee, person: person, name: name, aliases: Set(NameAliases.all(name: name, aliases: person?.aliases).map(NameAliases.normalise)))
        }
        let transcript = segments.map { " " + NameAliases.normalise($0.text) + " " }.joined(separator: " | ")
        return roster.compactMap { entry in
            let key = entry.person.map { $0.company + ":" + $0.employeeID } ?? entry.invitee
            guard !entry.name.isEmpty, seen.insert(key).inserted else { return nil }
            let identified = detected.contains { row in
                if let id = row.employeeID, let person = entry.person { return id == person.employeeID }
                let possible = roster.filter { $0.aliases.contains(NameAliases.normalise(row.name)) }
                return possible.count == 1 && possible[0].invitee == entry.invitee
            }
            guard !identified else { return nil }
            return InvitedSpeakerStatus(id: key, name: entry.name, role: entry.person?.jobTitle,
                mentioned: entry.aliases.contains { transcript.contains(" " + $0 + " ") })
        }
    }
    var reconciledSpeakers: [ReconciledSpeaker] {
        let labels = Array(Set(segments.map(\.speaker))).sorted()
        let unknown = Dictionary(uniqueKeysWithValues: labels.enumerated().map {
            ($0.element, "Speaker \($0.offset + 1)" + ($0.element == "me" ? " (you)" : ""))
        })
        var seen = Set<String>()
        let people = (participantContext ?? []).filter { seen.insert($0.company + ":" + $0.employeeID).inserted }
        var byAlias: [String: [Int]] = [:], byID: [String: [Int]] = [:]
        var aliases: [[String]] = []
        for (index, person) in people.enumerated() {
            let values = Array(Set(NameAliases.all(name: person.name, aliases: person.aliases).map(NameAliases.normalise)))
            aliases.append(values)
            for value in values { byAlias[value, default: []].append(index) }
            byID[person.employeeID, default: []].append(index)
        }
        // A long meeting repeats a handful of identities thousands of times.
        // Prepare directory lookup once; never generate aliases or sort all labels per passage.
        var matchedPeople: [String: Int] = [:]
        func personIndex(_ value: SpeakerAttribution) -> Int? {
            let key = value.employeeID.map { "id:" + $0 } ?? "name:" + value.name
            if let cached = matchedPeople[key] { return cached >= 0 ? cached : nil }
            let matches = value.employeeID.map { byID[$0] ?? [] } ?? byAlias[NameAliases.normalise(value.name)] ?? []
            let index = matches.count == 1 ? matches[0] : -1
            matchedPeople[key] = index
            return index >= 0 ? index : nil
        }
        var normalizedTranscript: String?
        func mentioned(_ values: [String]) -> Bool {
            if normalizedTranscript == nil {
                normalizedTranscript = segments.map { " " + NameAliases.normalise($0.text) + " " }.joined(separator: " | ")
            }
            return values.contains { normalizedTranscript!.contains(" " + $0 + " ") }
        }
        var rows: [ReconciledSpeaker] = [], rowIndex: [String: Int] = [:]
        for segment in segments {
            let attribution = attribution(for: segment)
            let name = attribution?.name ?? unknown[segment.speaker] ?? "Unknown speaker"
            let match = attribution.flatMap(personIndex)
            let person = match.map { people[$0] }
            let role = [attribution?.jobTitle, person?.jobTitle].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            let key = attribution.map { "person:" + ($0.employeeID ?? person?.employeeID ?? NameAliases.normalise($0.name)) } ?? "voice:" + segment.speaker
            if let index = rowIndex[key] {
                rows[index].segmentIDs.append(segment.id)
                if rows[index].jobTitle?.isEmpty != false { rows[index].jobTitle = role }
                if let attribution {
                    let evidence = attribution.evidence.filter { !rows[index].evidence.contains($0) }
                    rows[index].evidence.append(contentsOf: evidence)
                    let source = attribution.method == "manual" ? "User assignment" : attribution.method == "transcript" ? "Transcript label" : "AI inference"
                    if !rows[index].sources.contains(source) { rows[index].sources.append(source) }
                    rows[index].inferred = rows[index].inferred || attribution.method == "analysis"
                }
                continue
            }
            var sources = ["Voice detected"]
            if let attribution {
                if person != nil || participants.contains(where: { NameAliases.mentions(name, in: $0) }) { sources.append("Meeting invite") }
                if person != nil { sources.append("BambooHR") }
                sources.append(attribution.method == "manual" ? "User assignment" : attribution.method == "transcript" ? "Transcript label" : "AI inference")
                if mentioned(match.map { aliases[$0] } ?? [NameAliases.normalise(name)]) { sources.append("Name mentioned") }
            }
            rowIndex[key] = rows.count
            rows.append(ReconciledSpeaker(id: key, label: segment.speaker, name: name,
                jobTitle: role, employeeID: attribution?.employeeID ?? person?.employeeID,
                segmentIDs: [segment.id], sources: sources, evidence: attribution?.evidence ?? [], inferred: attribution?.method == "analysis"))
        }
        return rows
    }
}

/// Applies validated, passage-scoped identity inferences without changing acoustic labels or utterances.
public enum SpeakerReconciliation {
    public static func applying(_ revision: AnalysisRevision, to meeting: Meeting) -> Meeting {
        var result = meeting
        // User corrections survive regeneration; previous AI assignments are replaced, not accumulated.
        var assignments = (meeting.speakerAttributions ?? [:]).filter { $0.value.method == "manual" }
        var seenPeople = Set<String>()
        let people = (meeting.participantContext ?? []).filter { seenPeople.insert($0.company + ":" + $0.employeeID).inserted }
        let segments = Dictionary(uniqueKeysWithValues: meeting.segments.map { ($0.id, $0) })
        var proposed: [String: [SpeakerAttribution]] = [:]
        for candidate in revision.analysis.speakerCandidates ?? [] {
            guard let confidence = candidate.confidence, confidence >= 0.85, confidence <= 1,
                  let ids = candidate.segmentIDs, !ids.isEmpty,
                  let basis = candidate.basis, basis.contains("self_introduction") || basis.contains("direct_address_response") else { continue }
            let matches = people.filter { person in NameAliases.all(name: person.name, aliases: person.aliases).contains { NameAliases.normalise($0) == NameAliases.normalise(candidate.name) } }
            guard matches.count <= 1 else { continue }
            let person = matches.first
            // Without a directory match, only an unambiguous full invited name or a self-introduction is eligible.
            let invited = meeting.participants.map { $0.split(separator: "<").first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? $0 }
                .filter { NameAliases.normalise($0) == NameAliases.normalise(candidate.name) }
            guard person != nil || invited.count == 1 || (basis.contains("self_introduction") && candidate.name.split(separator: " ").count > 1) else { continue }
            let aliases = (person.map { NameAliases.all(name: $0.name, aliases: $0.aliases) } ?? [candidate.name]).filter { alias in
                // Even a canonical candidate cannot make a shared nickname unique evidence.
                people.filter { NameAliases.all(name: $0.name, aliases: $0.aliases).contains { NameAliases.normalise($0) == NameAliases.normalise(alias) } }.count <= 1
            }
            func anchored(_ segment: Segment) -> Bool {
                let selfIntro = basis.contains("self_introduction") && candidate.evidence.contains { evidence in
                    guard evidence.segmentID == segment.id else { return false }
                    let text = NameAliases.normalise(evidence.quote)
                    return aliases.contains { alias in
                        let name = NameAliases.normalise(alias)
                        return ["i m " + name, "i am " + name, "my name is " + name, "this is " + name, name + " here"].contains { (" " + text + " ").contains(" " + $0 + " ") }
                    }
                }
                let index = meeting.segments.firstIndex { $0.id == segment.id }!
                let prior = index > 0 ? meeting.segments[index - 1] : nil
                let addressed = basis.contains("direct_address_response") && prior.map { prior in
                    prior.speaker != segment.speaker && candidate.evidence.contains { evidence in
                        guard evidence.segmentID == prior.id else { return false }
                        let text = NameAliases.normalise(prior.text)
                        let question = prior.text.contains("?") || ["can", "could", "would", "will", "what", "how", "why"].contains { NameAliases.mentions($0, in: prior.text) }
                        let direct = aliases.contains { alias in
                            let name = NameAliases.normalise(alias)
                            return text.hasPrefix(name + " ") || text.hasSuffix(" " + name) || ["can", "could", "would", "will"].contains { text.contains(" " + name + " " + $0 + " ") }
                        }
                        return question && direct && aliases.contains { NameAliases.mentions($0, in: evidence.quote) }
                    } && candidate.evidence.contains { $0.segmentID == segment.id }
                } == true
                return selfIntro || addressed
            }
            let own = meeting.segments.filter { $0.speaker == candidate.label }
            let anchors = Set(own.filter(anchored).map(\.id))
            let separated = candidate.label.hasPrefix("them ") || candidate.label.hasPrefix("speaker ")
            let competing = (revision.analysis.speakerCandidates ?? []).contains { other in
                guard other.label == candidate.label else { return false }
                if let person { return !NameAliases.all(name: person.name, aliases: person.aliases).contains { NameAliases.normalise($0) == NameAliases.normalise(other.name) } }
                return NameAliases.normalise(other.name) != NameAliases.normalise(candidate.name)
            }
            for id in ids {
                guard let segment = segments[id], segment.speaker == candidate.label, assignments[id] == nil,
                      meeting.speakerNames[segment.speaker]?.isEmpty != false, !meeting.hasNamedSourceLabel(segment.speaker) else { continue }
                guard anchors.contains(id) || (separated && !competing && !anchors.isEmpty && basis.contains("voice_consistency")) else { continue }
                proposed[id, default: []].append(SpeakerAttribution(name: person?.name ?? invited.first ?? candidate.name,
                    jobTitle: person?.jobTitle, employeeID: person?.employeeID, method: "analysis", confidence: confidence,
                    basis: basis, evidence: candidate.evidence, analysisRevision: revision.id))
            }
        }
        for (id, values) in proposed {
            let names = Set(values.map { NameAliases.normalise($0.name) })
            if names.count == 1 { assignments[id] = values.max { ($0.confidence ?? 0) < ($1.confidence ?? 0) } }
        }
        result.speakerAttributions = assignments.isEmpty ? nil : assignments
        return result
    }
}

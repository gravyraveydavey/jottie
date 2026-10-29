import Foundation

public struct AudioDeviceContext: Codable, Sendable, Equatable {
    public var name: String?
    public var transport: String
    public var kind: String
    public var source: String
    public init(name: String? = nil, transport: String = "unknown", kind: String = "unknown", source: String = "unknown") {
        self.name = name; self.transport = transport; self.kind = kind; self.source = source
    }
}

public struct AudioRouteContext: Codable, Sendable, Equatable {
    public var at: Date
    public var input: AudioDeviceContext
    public var output: AudioDeviceContext
    public var outputSource: String
    public init(at: Date = Date(), input: AudioDeviceContext, output: AudioDeviceContext, outputSource: String) {
        self.at = at; self.input = input; self.output = output; self.outputSource = outputSource
    }
}

public struct RecordingContext: Codable, Sendable, Equatable {
    public var routes: [AudioRouteContext] = []
    public var echoCancellation: String?
    public var echoSegmentsRemoved: Int?
    public var playbackOverride: String?
    public var userNote: String?
    public init() {}
    public var echoRisk: String {
        if (echoSegmentsRemoved ?? 0) > 0 { return "Matching speech was detected on both audio tracks." }
        if playbackOverride == "speakers" || (playbackOverride == nil && routes.contains { $0.output.kind == "speakers" }) {
            return "Speaker playback can also be captured by the microphone."
        }
        return ""
    }
    public var playbackDescription: String {
        if let playbackOverride { return playbackOverride.capitalized + " (confirmed by you)" }
        let kinds = Set(routes.map { $0.output.kind })
        if kinds.count == 1, let kind = kinds.first, kind != "unknown" { return kind.capitalized + " (detected)" }
        return kinds.count > 1 ? "Playback changed during recording" : "Playback device type unknown"
    }
}

public struct TranscriptCleanupPreferences: Codable, Sendable, Equatable {
    public var instructions = ""
    public var expectedSpeakerCount: Int?
    public var joinFragments = true
    public var stripFillers = true
    public init() {}
    public func validate() throws {
        guard instructions.count <= 4000, expectedSpeakerCount.map({ (1...50).contains($0) }) ?? true else {
            throw JottieError.invalid("Use at most 4,000 instruction characters and a speaker count between 1 and 50.")
        }
    }
}

/// Builds readable turns without changing the saved transcript. Cross-label joins
/// require the same confirmed person; unresolved shared channels stay separate.
public enum TranscriptTurnAssembly {
    public static func speakerKey(_ segment: Segment, meeting: Meeting) -> String {
        if meeting.speakerAttributions?[segment.id]?.method == "manual", meeting.speakerAttributions?[segment.id]?.name.isEmpty == true { return "unknown:" + segment.id }
        if let person = meeting.attribution(for: segment), person.method == "manual" || person.method == "transcript" {
            return "person:" + (person.employeeID ?? NameAliases.normalise(person.name))
        }
        if ["them", "speaker", "unknown", "me unknown"].contains(segment.speaker) { return "unknown:" + segment.id }
        return "voice:" + segment.speaker
    }
    public static func removingFillers(_ text: String) -> String {
        let value = text.replacingOccurrences(of: #"(?i)(?<![\p{L}\p{N}_-])(?:um+|uh+|erm+)(?![\p{L}\p{N}_-]|\s+huh\b)[,;:]?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"^[,;:\s]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.contains(where: { $0.isLetter || $0.isNumber }) ? value : ""
    }
    public static func isOnlyFillers(_ text: String) -> Bool { removingFillers(text).isEmpty }
    public static func groups(in meeting: Meeting, enabled: Bool = true) -> [[Segment]] {
        var groups: [[Segment]] = []
        for segment in meeting.segments {
            if enabled, let last = groups.last?.last, let first = groups.last?.first,
               speakerKey(last, meeting: meeting) == speakerKey(segment, meeting: meeting),
               segment.startMS >= last.startMS, segment.startMS - last.endMS <= 2500,
               segment.startMS - first.startMS <= 45_000,
               groups[groups.count - 1].reduce(0, { $0 + $1.text.split(separator: " ").count }) + segment.text.split(separator: " ").count <= 160 {
                groups[groups.count - 1].append(segment)
            } else { groups.append([segment]) }
        }
        return groups
    }
}

public struct TranscriptTextChange: Codable, Sendable, Equatable, Identifiable {
    public var id: String { segmentID }
    public var segmentID: String
    public var sourceSegmentIDs: [String]?
    public var sourceIDs: [String] { sourceSegmentIDs ?? [segmentID] }
    public var originalText: String
    public var replacementText: String
    public var kind: String
    public var duplicateOf: String?
    public var reason: String
    public var uncertain: Bool
    public init(segmentID: String, originalText: String, replacementText: String, kind: String = "wording", duplicateOf: String? = nil, reason: String, uncertain: Bool = false, sourceSegmentIDs: [String]? = nil) {
        self.sourceSegmentIDs = sourceSegmentIDs
        self.segmentID = segmentID; self.originalText = originalText; self.replacementText = replacementText
        self.kind = kind; self.duplicateOf = duplicateOf; self.reason = reason; self.uncertain = uncertain
    }
}

public struct CleanupSpeakerSuggestion: Codable, Sendable, Equatable, Identifiable {
    public var id: String { Codec.hash(name + segmentIDs.joined(separator: "\n")) }
    public var segmentIDs: [String]
    public var name: String
    public var confidence: Double
    public var reason: String
    public var evidence: [Evidence]
    public init(segmentIDs: [String], name: String, confidence: Double, reason: String, evidence: [Evidence]) {
        self.segmentIDs = segmentIDs; self.name = name; self.confidence = confidence; self.reason = reason; self.evidence = evidence
    }
}

public struct TranscriptCleanupResult: Codable, Sendable, Equatable {
    public var changes: [TranscriptTextChange]
    public var speakerSuggestions: [CleanupSpeakerSuggestion]
    public var notes: [String]
    public init(changes: [TranscriptTextChange] = [], speakerSuggestions: [CleanupSpeakerSuggestion] = [], notes: [String] = []) {
        self.changes = changes; self.speakerSuggestions = speakerSuggestions; self.notes = notes
    }
    public func validate(against meeting: Meeting) throws {
        guard Set(meeting.segments.map(\.id)).count == meeting.segments.count else {
            throw JottieError.invalid("The source transcript has duplicate passage IDs.")
        }
        let source = Dictionary(uniqueKeysWithValues: meeting.segments.map { ($0.id, $0) })
        guard changes.count <= source.count, Set(changes.map(\.segmentID)).count == changes.count,
              speakerSuggestions.count <= source.count,
              notes.count <= 512, notes.allSatisfy({ $0.count <= 4000 }),
              Set(speakerSuggestions.map(\.id)).count == speakerSuggestions.count else {
            throw JottieError.invalid("Cleanup returned duplicate or excessive changes.")
        }
        var covered = Set<String>()
        for change in changes {
            let ids = change.sourceIDs
            guard ids.first == change.segmentID, Set(ids).count == ids.count,
                  let start = meeting.segments.firstIndex(where: { $0.id == change.segmentID }), start + ids.count <= meeting.segments.count,
                  Array(meeting.segments[start..<(start + ids.count)]).map(\.id) == ids,
                  ids.allSatisfy({ covered.insert($0).inserted }) else { throw JottieError.invalid("Cleanup groups must be ordered, contiguous and non-overlapping.") }
            let parts = ids.compactMap { source[$0] }
            guard let segment = parts.first, parts.map(\.text).joined(separator: " ") == change.originalText,
                  change.originalText != change.replacementText || parts.count > 1, !change.reason.isEmpty,
                  change.reason.count <= 4000, change.replacementText.count <= max(1000, change.originalText.count * 2),
                  ["wording", "duplicate", "merge", "filler"].contains(change.kind) else {
                throw JottieError.invalid("Cleanup changed an unknown passage or its original wording.")
            }
            if parts.count > 1 {
                let key = TranscriptTurnAssembly.speakerKey(segment, meeting: meeting)
                guard parts.allSatisfy({ TranscriptTurnAssembly.speakerKey($0, meeting: meeting) == key }),
                      zip(parts, parts.dropFirst()).allSatisfy({ $1.startMS - $0.endMS <= 2500 }) else {
                    throw JottieError.invalid("Fragments belonging to different or uncertain speakers cannot be joined.")
                }
            }
            if change.kind == "duplicate" {
                guard change.replacementText.isEmpty, let otherID = change.duplicateOf, !ids.contains(otherID),
                      let other = source[otherID],
                      max(other.startMS, segment.startMS) <= min(other.endMS, parts.map(\.endMS).max() ?? segment.endMS) + 2000 else {
                    throw JottieError.invalid("A removed duplicate must reference nearby retained speech.")
                }
            } else if change.kind == "filler" {
                guard change.replacementText.isEmpty, change.duplicateOf == nil, TranscriptTurnAssembly.isOnlyFillers(change.originalText) else {
                    throw JottieError.invalid("Only hesitation-only passages can be removed as fillers.")
                }
            } else if change.replacementText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || change.duplicateOf != nil {
                throw JottieError.invalid("Only duplicates or hesitation-only passages may be removed.")
            }
        }
        for suggestion in speakerSuggestions {
            guard !suggestion.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  suggestion.confidence.isFinite, (0...1).contains(suggestion.confidence), !suggestion.reason.isEmpty,
                  !suggestion.segmentIDs.isEmpty, Set(suggestion.segmentIDs).count == suggestion.segmentIDs.count,
                  suggestion.segmentIDs.allSatisfy({ source[$0] != nil }), !suggestion.evidence.isEmpty,
                  suggestion.evidence.allSatisfy({ !$0.quote.isEmpty && source[$0.segmentID]?.text.contains($0.quote) == true }) else {
                throw JottieError.invalid("Cleanup returned an unsupported speaker suggestion.")
            }
        }
    }
    public func projectedSegments(against meeting: Meeting, selecting ids: Set<String>) throws -> [Segment] {
        try validate(against: meeting)
        guard ids.isSubset(of: Set(changes.map(\.id))) else { throw JottieError.invalid("Unknown cleanup selection.") }
        let selected = changes.filter { ids.contains($0.id) }
        let deleted = Set(selected.filter { $0.replacementText.isEmpty }.flatMap(\.sourceIDs))
        guard selected.allSatisfy({ $0.duplicateOf.map { !deleted.contains($0) } ?? true }) else {
            throw JottieError.invalid("Keep at least one source copy of each duplicate passage.")
        }
        let consumed = Set(selected.flatMap { Array($0.sourceIDs.dropFirst()) })
        let anchors = Dictionary(uniqueKeysWithValues: selected.map { ($0.segmentID, $0) })
        let source = Dictionary(uniqueKeysWithValues: meeting.segments.map { ($0.id, $0) })
        return meeting.segments.compactMap { original in
            if consumed.contains(original.id) { return nil }
            guard let change = anchors[original.id] else { return original }
            if change.replacementText.isEmpty { return nil }
            var segment = original; segment.text = change.replacementText
            segment.endMS = change.sourceIDs.compactMap { source[$0]?.endMS }.max() ?? original.endMS
            return segment
        }
    }
}

public struct TranscriptCleanupRevision: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var createdAt: Date
    public var baseRevision: String
    public var contextRevision: String
    public var promptRevision: String
    public var model: String
    public var effort: String
    public var result: TranscriptCleanupResult
    public var selectedChangeIDs: [String]?
    public var selectedSpeakerIDs: [String]?
    public init(meeting: Meeting, promptRevision: String, model: String, effort: String, result: TranscriptCleanupResult) {
        id = UUID().uuidString; createdAt = Date(); baseRevision = meeting.transcriptRevision
        contextRevision = meeting.cleanupContextRevision; self.promptRevision = promptRevision
        self.model = model; self.effort = effort; self.result = result
    }
}

public extension Meeting {
    var cleanupContextRevision: String {
        struct Context: Encodable {
            var speakerRevision: String; var participants: [String]; var calendar: CalendarEventContext?
            var people: [ParticipantIdentity]?; var recording: RecordingContext?; var preferences: TranscriptCleanupPreferences?
        }
        return Codec.hash((try? Codec.encode(Context(speakerRevision: speakerRevision, participants: participants,
            calendar: calendarContext, people: participantContext, recording: recordingContext, preferences: cleanupPreferences))) ?? Data())
    }
    var originalTranscript: [Segment] { cleanupOriginalSegments ?? segments }
    var originalTranscriptRevision: String {
        cleanupOriginalSegments.map { Codec.hash((try? Codec.encode($0)) ?? Data()) } ?? transcriptRevision
    }
    var cleanupRecommendation: String { recordingContext?.echoRisk ?? "" }
}

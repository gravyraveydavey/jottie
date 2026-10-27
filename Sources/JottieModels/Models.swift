import Foundation
import CryptoKit

public enum JottieError: Error, LocalizedError, Sendable {
    case invalid(String), unavailable(String), conflict(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let message), .unavailable(let message), .conflict(let message): message
        }
    }
}

public enum Codec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func hash(_ text: String) -> String { hash(Data(text.utf8)) }
}

public struct Segment: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var speaker: String
    public var startMS: Int
    public var endMS: Int
    public var text: String
    public init(id: String, speaker: String, startMS: Int = 0, endMS: Int = 0, text: String) {
        self.id = id; self.speaker = speaker; self.startMS = startMS; self.endMS = endMS; self.text = text
    }
}

public struct Evidence: Codable, Sendable, Equatable, Hashable {
    public var segmentID: String
    public var quote: String
    public init(segmentID: String, quote: String) { self.segmentID = segmentID; self.quote = quote }
}

public struct Finding: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var text: String
    public var status: String
    public var owner: String?
    public var dueDate: String?
    public var evidence: [Evidence]
    public init(id: String = UUID().uuidString, text: String, status: String = "unclear",
                owner: String? = nil, dueDate: String? = nil, evidence: [Evidence] = []) {
        self.id = id; self.text = text; self.status = status
        self.owner = owner; self.dueDate = dueDate; self.evidence = evidence
    }
}
public struct SpeakerCandidate: Codable, Sendable, Equatable {
    public var label: String
    public var name: String
    public var evidence: [Evidence]
    public init(label: String, name: String, evidence: [Evidence]) {
        self.label = label; self.name = name; self.evidence = evidence
    }
}

public struct Analysis: Codable, Sendable, Equatable {
    public var schemaVersion = 1
    public var title: String
    public var summary: String
    public var summaryEvidence: [Evidence]
    public var topics: [String]
    public var tags: [String]
    public var primaryTag: String?
    public var decisions: [Finding]
    public var actions: [Finding]
    public var questions: [Finding]
    public var uncertainties: [String]
    public var sensitivity: String
    public var speakerCandidates: [SpeakerCandidate]?
    public init(title: String, summary: String, summaryEvidence: [Evidence] = [],
                topics: [String] = [], tags: [String] = [], primaryTag: String? = nil,
                decisions: [Finding] = [], actions: [Finding] = [], questions: [Finding] = [],
                uncertainties: [String] = [], sensitivity: String = "normal") {
        self.title = title; self.summary = summary; self.summaryEvidence = summaryEvidence
        self.topics = topics; self.tags = tags; self.primaryTag = primaryTag; self.decisions = decisions
        self.actions = actions; self.questions = questions; self.uncertainties = uncertainties
        self.sensitivity = sensitivity
    }
    public func validate(segments: [Segment]) throws {
        guard schemaVersion == 1, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ["normal", "sensitive", "uncertain"].contains(sensitivity),
              !summaryEvidence.isEmpty else { throw JottieError.invalid("Incomplete analysis.") }
        guard Set(segments.map(\.id)).count == segments.count else { throw JottieError.invalid("Duplicate transcript segment IDs.") }
        let source = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0.text) })
        let findings = decisions + actions + questions
        guard findings.allSatisfy({ !$0.evidence.isEmpty }),
              decisions.allSatisfy({ ["proposed", "confirmed", "rejected", "superseded", "unclear"].contains($0.status) }),
              actions.allSatisfy({ ["proposed", "committed", "in_progress", "blocked", "completed", "unclear"].contains($0.status) }),
              questions.allSatisfy({ ["open", "resolved", "unclear"].contains($0.status) })
        else { throw JottieError.invalid("Unsupported finding status or missing evidence.") }
        let candidates = speakerCandidates ?? []
        guard candidates.allSatisfy({ !$0.name.isEmpty && !$0.evidence.isEmpty }) else {
            throw JottieError.invalid("Invalid speaker candidate.")
        }
        for candidate in candidates where !segments.contains(where: { $0.speaker == candidate.label }) {
            throw JottieError.invalid("Speaker candidate refers to an unknown channel.")
        }
        for evidence in summaryEvidence + findings.flatMap(\.evidence) + candidates.flatMap(\.evidence) {
            guard !evidence.quote.isEmpty, source[evidence.segmentID]?.contains(evidence.quote) == true
            else { throw JottieError.invalid("Analysis cites text absent from the transcript.") }
        }
    }
}

public struct AnalysisRevision: Codable, Sendable, Equatable {
    public var id: String
    public var transcriptRevision: String
    public var promptRevision: String
    public var createdAt: Date
    public var analysis: Analysis
    public init(transcriptRevision: String, promptRevision: String, analysis: Analysis) {
        self.transcriptRevision = transcriptRevision; self.promptRevision = promptRevision
        self.analysis = analysis; createdAt = Date()
        id = Codec.hash(transcriptRevision + promptRevision + ((try? String(decoding: Codec.encode(analysis), as: UTF8.self)) ?? ""))
    }
}

public struct Meeting: Codable, Sendable, Equatable, Identifiable {
    public var schemaVersion = 1
    public var id: UUID
    public var sourceID: String
    public var title: String
    public var startedAt: Date
    public var segments: [Segment]
    public var participants: [String]
    public var speakerNames: [String: String]
    public var folderID: UUID?
    public var manuallyFiled: Bool
    public var filingReason: String?
    public var transcriptRevision: String
    public var analysis: AnalysisRevision?
    public var importedSummary: String?
    public var sourceMetadata: [String: String]?
    public var starred: Bool?
    public var speakerRoles: [String: String]?
    public init(id: UUID = UUID(), sourceID: String, title: String, startedAt: Date = Date(),
                segments: [Segment], participants: [String] = [], speakerNames: [String: String] = [:]) {
        self.id = id; self.sourceID = sourceID; self.title = title; self.startedAt = startedAt
        self.segments = segments; self.participants = participants; self.speakerNames = speakerNames
        manuallyFiled = false
        transcriptRevision = Codec.hash((try? Codec.encode(segments)) ?? Data())
    }
    public var displayTitle: String { analysis?.analysis.title ?? title }
    public var transcript: String {
        segments.map { "[\($0.startMS / 60000):\(String(format: "%02d", $0.startMS / 1000 % 60))] \(speakerNames[$0.speaker] ?? $0.speaker): \($0.text)" }
            .joined(separator: "\n\n")
    }
    public var markdown: String {
        var text = "# \(displayTitle)\n\nMeeting: \(id)\nDate: \(ISO8601DateFormatter().string(from: startedAt))\n"
        if let analysis = analysis?.analysis {
            text += "\n## Summary\n\n\(analysis.summary)\n\nTags: \(analysis.tags.joined(separator: ", "))\n"
            if !analysis.topics.isEmpty { text += "\n## Topics\n\n" + analysis.topics.map { "- \($0)" }.joined(separator: "\n") + "\n" }
            for (title, items) in [("Decisions", analysis.decisions), ("Actions", analysis.actions), ("Follow-up questions", analysis.questions)] where !items.isEmpty {
                text += "\n## \(title)\n\n" + items.map {
                    "- [\($0.status)] \($0.text)" + ($0.owner.map { " — \($0)" } ?? "")
                        + ($0.dueDate.map { " (due: \($0))" } ?? "")
                        + " [sources: \($0.evidence.map(\.segmentID).joined(separator: ", "))]"
                }.joined(separator: "\n") + "\n"
            }
        } else if let importedSummary {
            text += "\n## Imported summary\n\n\(importedSummary)\n"
        }
        return text + "\n## Transcript\n\n" + transcript + "\n"
    }
}

public struct PublishDestination: Codable, Sendable, Equatable {
    public var tenantID: String
    public var accountID: String
    public var driveID: String
    public var itemID: String
    public var webURL: String
    public init(tenantID: String, accountID: String, driveID: String, itemID: String, webURL: String) {
        self.tenantID = tenantID; self.accountID = accountID; self.driveID = driveID
        self.itemID = itemID; self.webURL = webURL
    }
}

public struct Folder: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var parentID: UUID?
    public var aliases: [String]
    public var destination: PublishDestination?
    public init(id: UUID = UUID(), name: String, parentID: UUID? = nil, aliases: [String] = []) {
        self.id = id; self.name = name; self.parentID = parentID; self.aliases = aliases
    }
}

public struct ContextSource: Codable, Sendable, Equatable, Hashable {
    public var meetingID: UUID
    public var revision: String
    public var segmentID: String
    public init(meetingID: UUID, revision: String, segmentID: String) {
        self.meetingID = meetingID; self.revision = revision; self.segmentID = segmentID
    }
}

public struct ContextEntry: Codable, Sendable, Equatable {
    public var id: String
    public var text: String
    public var status: String
    public var owner: String?
    public var dueDate: String?
    public var sources: [ContextSource]
    public init(id: String, text: String, status: String, owner: String? = nil, dueDate: String? = nil, sources: [ContextSource]) {
        self.id = id; self.text = text; self.status = status; self.owner = owner; self.dueDate = dueDate; self.sources = sources
    }
}

public struct FolderContext: Codable, Sendable, Equatable {
    public var schemaVersion = 1
    public var folderID: UUID
    public var inputRevision: String
    public var configurationRevision: String?
    public var generatedAt: Date
    public var overview: String
    public var decisions: [ContextEntry]
    public var actions: [ContextEntry]
    public var questions: [ContextEntry]
    public var recentChanges: [ContextEntry]
    public var sources: [ContextSource]
    public init(folderID: UUID, inputRevision: String, overview: String,
                decisions: [ContextEntry] = [], actions: [ContextEntry] = [], questions: [ContextEntry] = [],
                recentChanges: [ContextEntry] = [], sources: [ContextSource] = []) {
        self.folderID = folderID; self.inputRevision = inputRevision; generatedAt = Date()
        self.overview = overview; self.decisions = decisions; self.actions = actions
        self.questions = questions; self.recentChanges = recentChanges; self.sources = sources
    }
    public var markdown: String {
        var result = "# Current context\n\n\(overview)\n"
        for (title, items) in [("Decision log", decisions), ("Open actions", actions.filter { $0.status != "completed" }),
                               ("Open questions", questions.filter { $0.status != "resolved" }), ("Recent changes", recentChanges)] {
            result += "\n## \(title)\n\n" + (items.isEmpty ? "None recorded." : items.map {
                "- [\($0.status)] \($0.text)" + ($0.owner.map { " — \($0)" } ?? "")
                + ($0.dueDate.map { " (due: \($0))" } ?? "")
                + " [\($0.sources.map { "\($0.meetingID.uuidString)#\($0.segmentID)" }.joined(separator: ", "))]"
            }.joined(separator: "\n")) + "\n"
        }
        return result
    }
}

public enum Prompts {
    public static let summary = """
    Write a concise, outcome-focused meeting record. Lead with the current position, material changes,
    practical next steps and caveats. Scale the detail to the substance of the meeting; do not omit
    distinct material outcomes just to meet a word count. Drop repetition, greetings and routine chatter.
    Include topics, decisions, actions, follow-up questions and descriptive tags. Choose one primary tag
    suitable for filing into an existing folder name or alias. Use exact evidence quotes and segment IDs.
    Distinguish proposals from approval, requests from commitments, and discussion from completion.
    Unknown owners and deadlines are null. Calendar participants are invitees, not verified speakers.
    """
    public static let folderContext = """
    Write a concise, outcome-focused overview of this folder using its meeting summaries.
    Lead with the current position, durable objectives, material changes and caveats.
    Maintain decisions, open actions and follow-up questions. Distinguish proposals from
    commitments and completed work. Preserve unresolved contradictions as open questions.
    Scale detail to the evidence and avoid repeating the same point across meetings.
    """
}

public struct LibrarySettings: Codable, Sendable, Equatable {
    public var schemaVersion = 2
    public var summaryPrompt = Prompts.summary
    public var folderContextPrompt = Prompts.folderContext
    public var refreshMinutes = 60
    public var analysisEnabled = false
    public var codexPath = ""
    public var codexModel = ""
    public var codexEffort = ""
    public var selectedCalendarIDs: [String] = []
    public var microsoftClientID = ""
    public var microsoftTenantID = ""
    public init() {}
    public static let efforts = ["", "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
    public var analysisRevision: String { Codec.hash(summaryPrompt + "\n" + codexModel + "\n" + codexEffort + "\ntag-policy-v1") }
    public var contextRevision: String { Codec.hash(folderContextPrompt + "\n" + codexModel + "\n" + codexEffort + "\nsummary-only-v2") }
    enum CodingKeys: String, CodingKey {
        case schemaVersion, summaryPrompt, folderContextPrompt, refreshMinutes, analysisEnabled, codexPath,
             codexModel, codexEffort, selectedCalendarIDs, microsoftClientID, microsoftTenantID
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard (1...2).contains(version) else { throw JottieError.invalid("Unsupported library settings version.") }
        summaryPrompt = try values.decodeIfPresent(String.self, forKey: .summaryPrompt) ?? summaryPrompt
        folderContextPrompt = try values.decodeIfPresent(String.self, forKey: .folderContextPrompt) ?? folderContextPrompt
        refreshMinutes = try values.decodeIfPresent(Int.self, forKey: .refreshMinutes) ?? refreshMinutes
        analysisEnabled = try values.decodeIfPresent(Bool.self, forKey: .analysisEnabled) ?? analysisEnabled
        codexPath = try values.decodeIfPresent(String.self, forKey: .codexPath) ?? codexPath
        codexModel = try values.decodeIfPresent(String.self, forKey: .codexModel) ?? codexModel
        codexEffort = try values.decodeIfPresent(String.self, forKey: .codexEffort) ?? codexEffort
        selectedCalendarIDs = try values.decodeIfPresent([String].self, forKey: .selectedCalendarIDs) ?? []
        microsoftClientID = try values.decodeIfPresent(String.self, forKey: .microsoftClientID) ?? ""
        microsoftTenantID = try values.decodeIfPresent(String.self, forKey: .microsoftTenantID) ?? ""
    }
}

/// The context reducer's input cannot contain a meeting's transcript or capture metadata.
public struct MeetingSummary: Codable, Sendable {
    public let id: UUID
    public let title: String
    public let startedAt: Date
    public let analysis: AnalysisRevision
    public init?(_ meeting: Meeting) {
        guard let analysis = meeting.analysis else { return nil }
        id = meeting.id; title = meeting.title; startedAt = meeting.startedAt; self.analysis = analysis
    }
    public var sources: Set<ContextSource> {
        let evidence = analysis.analysis.summaryEvidence + (analysis.analysis.decisions + analysis.analysis.actions + analysis.analysis.questions).flatMap(\.evidence)
        return Set(evidence.map { ContextSource(meetingID: id, revision: analysis.id, segmentID: $0.segmentID) })
    }
}

public struct SearchQuery: Sendable {
    public var text = ""
    public var folderID: UUID?
    public var inbox = false
    public var includeDescendants = true
    public var starredOnly = false
    public var oldestFirst = false
    public var tag: String?
    public var after: Date?
    public var before: Date?
    public var offset = 0
    public var limit = 50
    public init() {}
}
public struct SearchHit: Sendable, Identifiable {
    public var id: UUID { meeting.id }
    public var meeting: Meeting
    public var snippet: String
    public init(meeting: Meeting, snippet: String) { self.meeting = meeting; self.snippet = snippet }
}
public protocol MeetingRepository: Sendable {
    func meetings() async throws -> [Meeting]
    func folders() async throws -> [Folder]
    func search(_ query: SearchQuery) async throws -> [SearchHit]
    func save(_ meeting: Meeting) async throws
}
public protocol MeetingAnalyzer: Sendable {
    func analyze(_ meeting: Meeting, prompt: String, folders: [Folder]) async throws -> Analysis
}
public struct CalendarChoice: Sendable, Identifiable {
    public var id: String
    public var title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}
@MainActor public protocol CalendarProvider {
    func choices() async throws -> [CalendarChoice]
}
public protocol FolderContextService: Sendable {
    func update(folder: Folder, summaries: [MeetingSummary], previous: FolderContext?) async throws -> FolderContext
}
public protocol MeetingPublisher: Sendable {
    func publish(meeting: Meeting, to destination: PublishDestination) async throws
}

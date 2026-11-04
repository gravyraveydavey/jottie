import Foundation

/// Private acoustic evidence. Never put these records inside Meeting or an analysis prompt.
public struct VoiceSample: Codable, Sendable, Equatable {
    public var id: String
    public var speaker: String
    public var startMS: Int
    public var endMS: Int
    public var embedding: [Float]
    public init(id: String, speaker: String, startMS: Int, endMS: Int, embedding: [Float]) {
        self.id = id; self.speaker = speaker; self.startMS = startMS; self.endMS = endMS; self.embedding = embedding
    }
    public var isValid: Bool {
        startMS >= 0 && endMS > startMS && endMS - startMS >= 2000 && embedding.count == 256
            && embedding.allSatisfy(\.isFinite) && abs(embedding.reduce(0) { $0 + $1 * $1 } - 1) < 0.02
    }
}

public struct VoiceEvidence: Codable, Sendable, Equatable {
    public var schemaVersion = 1
    public var sourceID: String
    public var company: String
    public var generation: String
    public var modelID: String
    /// Binds evidence to the exact original transcript, including timing, track and text.
    public var originalSegments: [Segment]
    public var samples: [VoiceSample]
    public var captureTuning: VoiceTuning?
    public init(sourceID: String, company: String, generation: String, modelID: String,
                originalSegments: [Segment], samples: [VoiceSample], captureTuning: VoiceTuning? = nil) {
        self.sourceID = sourceID; self.company = company; self.generation = generation; self.modelID = modelID
        self.originalSegments = originalSegments; self.samples = samples; self.captureTuning = captureTuning
    }
    /// A window is usable only if all its speech belongs to selected, unambiguous original passages.
    public func passages(for sample: VoiceSample) -> [Segment] {
        guard sample.isValid else { return [] }
        let overlaps = originalSegments.filter { $0.speaker.split(separator: " ").first == sample.speaker.split(separator: " ").first && $0.startMS < sample.endMS && $0.endMS > sample.startMS }
        guard !overlaps.isEmpty, overlaps.allSatisfy({ $0.speaker == sample.speaker }) else { return [] }
        let spans = overlaps.map { (max($0.startMS, sample.startMS), min($0.endMS, sample.endMS)) }.sorted { $0.0 < $1.0 }
        var end = sample.startMS, covered = 0
        for span in spans { covered += max(0, span.1 - max(end, span.0)); end = max(end, span.1) }
        return Double(covered) >= Double(sample.endMS - sample.startMS) * 0.8 ? overlaps : []
    }
    public func coveredPassageIDs(by samples: [VoiceSample]) -> Set<String> {
        var result = Set<String>()
        for passage in originalSegments where passage.endMS > passage.startMS {
            let spans = samples.filter { $0.speaker == passage.speaker && $0.startMS < passage.endMS && $0.endMS > passage.startMS }
                .map { (max($0.startMS, passage.startMS), min($0.endMS, passage.endMS)) }.sorted { $0.0 < $1.0 }
            var end = passage.startMS, covered = 0
            for span in spans { covered += max(0, span.1 - max(end, span.0)); end = max(end, span.1) }
            if Double(covered) >= Double(passage.endMS - passage.startMS) * 0.8 { result.insert(passage.id) }
        }
        return result
    }

}

/// Explainable match provenance; contains no acoustic vectors.
public struct VoiceMatch: Codable, Sendable, Equatable {
    public var profileID: String
    public var company: String
    public var modelID: String
    public var profileRevision: String
    public var similarity: Double
    public var margin: Double
    public var sampleCount: Int
    public init(profileID: String, company: String, modelID: String, profileRevision: String,
                similarity: Double, margin: Double, sampleCount: Int) {
        self.profileID = profileID; self.company = company; self.modelID = modelID; self.profileRevision = profileRevision
        self.similarity = similarity; self.margin = margin; self.sampleCount = sampleCount
    }
}

public struct VoiceprintReport: Sendable {
    public var usableWindows: [UUID: Int] = [:]
    public var diagnostics: [UUID: [VoiceDiagnostic]] = [:]
    public var captureTuning: [UUID: VoiceTuning] = [:]
    public var recordings = 0
    public var enrolledPeople = 0
    public var matchedPassages = 0
    public var changedMeetings = 0
    public init() {}
    public var message: String {
        "\(recordings) recordings with voice evidence · \(enrolledPeople) enrolled people · \(matchedPassages) matched passages"
    }
}

public enum VoiceSimilarity {
    public static func normalized(_ vector: [Float]) -> [Float]? {
        guard vector.count == 256, vector.allSatisfy(\.isFinite) else { return nil }
        let squared = vector.reduce(0.0) { $0 + Double($1) * Double($1) }
        guard squared.isFinite, squared > 1e-12 else { return nil }
        let magnitude = sqrt(squared)
        return vector.map { Float(Double($0) / magnitude) }
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == 256, b.count == 256 else { return -1 }
        var dot = 0.0, aa = 0.0, bb = 0.0
        for (x, y) in zip(a, b) { dot += Double(x) * Double(y); aa += Double(x) * Double(x); bb += Double(y) * Double(y) }
        guard dot.isFinite, aa > 0, bb > 0 else { return -1 }
        return max(-1, min(1, dot / sqrt(aa * bb)))
    }
}

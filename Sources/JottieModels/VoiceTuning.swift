import Foundation

/// Scores, not probabilities. Capture controls affect future diarization; identity controls can replay saved vectors.
public struct VoiceTuning: Codable, Sendable, Equatable {
    public var matchSimilarity = 0.70
    public var matchMargin = 0.12
    public var minimumMatchingWindows = 2
    public var clusteringSimilarity = 0.60
    public var knownSpeakersPerTrack = 0
    public var maximumSpeakersPerTrack = 0
    public var minimumEmbeddingSpeechSeconds = 1.0
    public init() {}
    public var isValid: Bool {
        matchSimilarity.isFinite && (0.4...0.95).contains(matchSimilarity)
            && matchMargin.isFinite && (0...0.5).contains(matchMargin)
            && (1...8).contains(minimumMatchingWindows)
            && clusteringSimilarity.isFinite && (0.2...0.95).contains(clusteringSimilarity)
            && (0...12).contains(knownSpeakersPerTrack) && (0...12).contains(maximumSpeakersPerTrack)
            && minimumEmbeddingSpeechSeconds.isFinite && (1...5).contains(minimumEmbeddingSpeechSeconds)
    }
    enum CodingKeys: String, CodingKey {
        case matchSimilarity, matchMargin, minimumMatchingWindows, clusteringSimilarity, knownSpeakersPerTrack,
             maximumSpeakersPerTrack, minimumEmbeddingSpeechSeconds
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        matchSimilarity = try c.decodeIfPresent(Double.self, forKey: .matchSimilarity) ?? matchSimilarity
        matchMargin = try c.decodeIfPresent(Double.self, forKey: .matchMargin) ?? matchMargin
        minimumMatchingWindows = try c.decodeIfPresent(Int.self, forKey: .minimumMatchingWindows) ?? minimumMatchingWindows
        clusteringSimilarity = try c.decodeIfPresent(Double.self, forKey: .clusteringSimilarity) ?? clusteringSimilarity
        knownSpeakersPerTrack = try c.decodeIfPresent(Int.self, forKey: .knownSpeakersPerTrack) ?? knownSpeakersPerTrack
        maximumSpeakersPerTrack = try c.decodeIfPresent(Int.self, forKey: .maximumSpeakersPerTrack) ?? maximumSpeakersPerTrack
        minimumEmbeddingSpeechSeconds = try c.decodeIfPresent(Double.self, forKey: .minimumEmbeddingSpeechSeconds) ?? minimumEmbeddingSpeechSeconds
    }
}

/// Local replay diagnostics contain scores and counts, never vectors or voice samples.
public struct VoiceDiagnostic: Sendable, Identifiable {
    public var id: String { speaker }
    public var speaker: String
    public var storedWindows: Int
    public var usableWindows: Int
    public var supportingWindows = 0
    public var bestName: String?
    public var similarity: Double?
    public var runnerUpName: String?
    public var runnerUpSimilarity: Double?
    public var margin: Double?
    public var reason: String
    public init(speaker: String, storedWindows: Int, usableWindows: Int, reason: String) {
        self.speaker = speaker; self.storedWindows = storedWindows; self.usableWindows = usableWindows; self.reason = reason
    }
}

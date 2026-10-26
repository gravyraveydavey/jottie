import Foundation

public enum MeetingTags {
    public static func key(_ tag: String) -> String {
        tag.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    public static func applying(to analysis: Analysis, existing: [String]) -> Analysis {
        var result = analysis
        var catalog: [String: String] = [:]
        for tag in existing where !key(tag).isEmpty { if catalog[key(tag)] == nil { catalog[key(tag)] = tag } }
        func canonical(_ tag: String) -> String {
            let cleaned = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            return catalog[key(cleaned)] ?? cleaned
        }
        let primary = analysis.primaryTag.map(canonical).flatMap { key($0).isEmpty ? nil : $0 }
        var seen = Set<String>()
        result.tags = Array(((primary.map { [$0] } ?? []) + analysis.tags.map(canonical))
            .filter { !key($0).isEmpty && seen.insert(key($0)).inserted }.prefix(10))
        result.primaryTag = primary
        return result
    }
}

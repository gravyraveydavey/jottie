import Foundation
import JottieModels

/// Parses explicit Teams-style speaker headings. This never infers an identity
/// from prose, invitations or an AI response. Unrecognised documents stay whole.
enum DocumentSpeakerTurns {
    static let revision = "teams-speaker-turns-v1"
    struct Parsed {
        var segments: [Segment]
        var preamble: String
        var startedAt: Date?
    }
    private static let heading = try! NSRegularExpression(pattern: #"^([\p{L}][\p{L}\p{M}0-9 .,'’()@_\-]{0,119}?)\s{2,}(\d{1,4}:\d{2}(?::\d{2})?)\s*$"#)
    private static let duration = try! NSRegularExpression(pattern: #"^(?:(\d+)h\s*)?(?:(\d+)m\s*)?(\d+)s$"#)

    static func parse(_ text: String) -> Parsed? {
        // Word's soft line breaks are U+2028, not necessarily LF. Swift's
        // newline property also handles paragraph separators and CRLF exports.
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        struct Heading { var line: Int; var name: String; var start: Int }
        let headings: [Heading] = lines.enumerated().compactMap { index, line in
            let value = line.trimmingCharacters(in: .whitespaces)
            guard let match = heading.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                  let nameRange = Range(match.range(at: 1), in: value), let timeRange = Range(match.range(at: 2), in: value),
                  let start = milliseconds(String(value[timeRange])) else { return nil }
            return Heading(line: index, name: String(value[nameRange]).trimmingCharacters(in: .whitespaces), start: start)
        }
        guard let first = headings.first else { return nil }
        let preamble = lines[..<first.line].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // A lone "Lunch break   1:00" buried in ordinary notes is not proof
        // of a transcript. Teams metadata or repeated headings is stronger.
        guard headings.count > 1 || preamble.isEmpty || preamble.lowercased().contains(" started transcription") else { return nil }
        let noticeSuffix = " started transcription"
        let operators = lines[..<first.line].compactMap { line -> String? in
            let value = line.trimmingCharacters(in: .whitespaces)
            return value.hasSuffix(noticeSuffix) ? String(value.dropLast(noticeSuffix.count)) : nil
        }
        let noticeNames = Set(headings.map(\.name) + operators)
        let lastContent = lines.lastIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var segments: [Segment] = []
        for (index, item) in headings.enumerated() {
            let limit = index + 1 < headings.count ? headings[index + 1].line : lines.count
            let body = lines[(item.line + 1)..<limit].enumerated().compactMap { offset, line -> String? in
                let value = line.trimmingCharacters(in: .whitespaces)
                if item.line + 1 + offset == lastContent,
                   noticeNames.contains(where: { value == $0 + " stopped transcription" }) { return nil }
                return line
            }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            // A heading without speech is retained in source history, not
            // counted as a person who spoke or attached to the next person's turn.
            guard !body.isEmpty else { continue }
            // Teams supplies starts, not word/end times. Keep end equal to
            // start rather than invent exact turn boundaries from overlaps.
            segments.append(Segment(id: "document-turn-\(index + 1)", speaker: item.name,
                startMS: item.start, endMS: item.start, text: body))
        }
        guard !segments.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM d, yyyy, h:mma"
        formatter.isLenient = false
        let started = lines[..<first.line].compactMap { formatter.date(from: $0.trimmingCharacters(in: .whitespaces)) }.first
        if let last = segments.indices.last {
            for line in lines[..<first.line] {
                let value = line.trimmingCharacters(in: .whitespaces)
                guard let match = duration.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { continue }
                let numbers = (1...3).map { number -> Int in
                    guard let range = Range(match.range(at: number), in: value) else { return 0 }
                    return Int(value[range]) ?? 0
                }
                guard numbers.allSatisfy({ (0...604800).contains($0) }) else { continue }
                let end = (numbers[0] * 3600 + numbers[1] * 60 + numbers[2]) * 1000
                if end >= segments[last].startMS && end <= 604800000 { segments[last].endMS = end }
            }
        }
        return Parsed(segments: segments, preamble: preamble, startedAt: started)
    }
    private static func milliseconds(_ value: String) -> Int? {
        let parts = value.split(separator: ":").compactMap { Int($0) }
        guard (2...3).contains(parts.count), parts.last! < 60,
              parts.count == 2 || parts[1] < 60 else { return nil }
        let seconds = parts.reduce(0) { $0 * 60 + $1 }
        guard seconds <= 604800 else { return nil }
        return seconds * 1000
    }
}

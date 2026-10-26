import Foundation

enum LiveTranscriptionLanguage {
    /// Nemotron prompt names are BCP-47 locales, while jottie's existing
    /// setting intentionally asks for a short language code. Keep the mapping
    /// explicit: inventing a region can silently select the wrong prompt.
    private static let prompts: [String: String] = [
        "ar": "ar-AR", "bg": "bg-BG", "cs": "cs-CZ", "da": "da-DK",
        "de": "de-DE", "en": "en-US", "es": "es-ES", "et": "et-EE",
        "fi": "fi-FI", "fr": "fr-FR", "hi": "hi-IN", "hr": "hr-HR",
        "hu": "hu-HU", "it": "it-IT", "ja": "ja-JP", "ko": "ko-KR",
        "lv": "lv-LV", "nl": "nl-NL", "no": "nb-NO", "pl": "pl-PL",
        "pt": "pt-PT", "ro": "ro-RO", "ru": "ru-RU", "sk": "sk-SK",
        "sv": "sv-SE", "tr": "tr-TR", "uk": "uk-UA", "vi": "vi-VN",
        "zh": "zh-CN",
    ]

    static func prompt(for configured: String?) -> String {
        guard let configured else { return "auto" }
        let raw = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "auto" }
        if let exact = prompts.values.first(where: {
            $0.caseInsensitiveCompare(raw) == .orderedSame
        }) {
            return exact
        }
        return prompts[raw.lowercased()] ?? "auto"
    }
}

struct LiveTranscriptState: Sendable {
    enum Speaker: String, Sendable, Hashable {
        case you
        case them

        /// Who said it, in the window's language rather than the meeting's:
        /// this names the two microphones, not the two languages.
        var label: String {
            self == .you ? localised("You", "Вы") : localised("Them", "Они")
        }
    }

    struct Block: Sendable, Equatable {
        let speaker: Speaker
        var text: String
        let startMilliseconds: Int
        var isProvisional: Bool
    }

    enum Entry: Sendable, Equatable {
        case speech(Block)
        case resumed
    }

    private(set) var entries: [Entry] = []
    private(set) var epoch = 0
    private(set) var isEnabled = false
    private var provisionalIndex: [Speaker: Int] = [:]

    @discardableResult
    mutating func beginRecording(enabled: Bool) -> Int {
        entries.removeAll(keepingCapacity: true)
        provisionalIndex.removeAll(keepingCapacity: true)
        epoch += 1
        isEnabled = enabled
        return epoch
    }

    @discardableResult
    mutating func setEnabled(_ enabled: Bool) -> Int {
        guard enabled != isEnabled else { return epoch }
        freezeProvisionalBlocks()
        epoch += 1
        isEnabled = enabled
        if enabled, entries.contains(where: {
            if case .speech = $0 { return true }
            return false
        }) {
            entries.append(.resumed)
        }
        return epoch
    }

    mutating func applyPartial(
        speaker: Speaker,
        text: String,
        startMilliseconds: Int,
        epoch resultEpoch: Int
    ) {
        guard isEnabled, resultEpoch == epoch else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if let index = provisionalIndex[speaker], entries.indices.contains(index),
           case .speech(var block) = entries[index] {
            block.text = text
            entries[index] = .speech(block)
            return
        }

        entries.append(.speech(Block(
            speaker: speaker,
            text: text,
            startMilliseconds: max(0, startMilliseconds),
            isProvisional: true
        )))
        provisionalIndex[speaker] = entries.index(before: entries.endIndex)
        orderCurrentEpochSpeech()
    }

    /// Ends a speaker's block, so the next words from that side open a new
    /// one. Nothing else closes a block while the recording runs: the engine
    /// reports one ever-growing transcript per speaker and never says where
    /// an utterance ended, which is why the pause has to be noticed here.
    @discardableResult
    mutating func endSegment(speaker: Speaker, epoch resultEpoch: Int) -> Bool {
        guard isEnabled, resultEpoch == epoch else { return false }
        guard let index = provisionalIndex.removeValue(forKey: speaker),
              entries.indices.contains(index),
              case .speech(var block) = entries[index], block.isProvisional
        else { return false }
        block.isProvisional = false
        entries[index] = .speech(block)
        return true
    }

    mutating func finishRecording() {
        freezeProvisionalBlocks()
        isEnabled = false
        epoch += 1
    }

    /// A runtime failure stops this pipeline but does not alter the person's
    /// persistent checkbox choice. Advancing the epoch rejects callbacks that
    /// were already in flight while leaving the UI checked with an error.
    mutating func invalidateActiveEpoch() {
        guard isEnabled else { return }
        freezeProvisionalBlocks()
        epoch += 1
    }

    private mutating func freezeProvisionalBlocks() {
        for index in entries.indices {
            guard case .speech(var block) = entries[index], block.isProvisional else { continue }
            block.isProvisional = false
            entries[index] = .speech(block)
        }
        provisionalIndex.removeAll(keepingCapacity: true)
    }

    /// Mic and system callbacks finish independently. Reorder only the live
    /// tail after the latest resume marker; earlier epochs are immutable.
    private mutating func orderCurrentEpochSpeech() {
        let boundary = entries.lastIndex(where: { if case .resumed = $0 { true } else { false } })
            .map { $0 + 1 } ?? 0
        let prefix = Array(entries[..<boundary])
        var tail = Array(entries[boundary...])
        tail.sort { lhs, rhs in
            guard case .speech(let a) = lhs, case .speech(let b) = rhs else { return false }
            return a.startMilliseconds < b.startMilliseconds
        }
        entries = prefix + tail
        provisionalIndex.removeAll(keepingCapacity: true)
        for index in entries.indices {
            if case .speech(let block) = entries[index], block.isProvisional {
                provisionalIndex[block.speaker] = index
            }
        }
    }
}

/// Removes only the microphone text that is almost certainly speaker playback
/// heard through open speakers. The underlying `LiveTranscriptState` remains
/// untouched: a provisional decode that later diverges from the system side
/// appears again on the next snapshot instead of being lost.
enum LiveEchoFilter {
    private static let maximumStartDelta = 4_000
    /// Nemotron may cut the clean system stream at pauses that the echoed mic
    /// stream does not hear as silence. Compare a bounded minute around an
    /// anchored match: enough for one long spoken block, without making every
    /// live refresh compare against an ever-growing meeting transcript.
    private static let maximumCombinedStartDelta = 60_000
    private static let minimumWords = 5
    private static let minimumAnchorWords = 3
    private static let minimumCoverage = 0.90

    static func visibleEntries(
        _ entries: [LiveTranscriptState.Entry]
    ) -> [LiveTranscriptState.Entry] {
        var visible: [LiveTranscriptState.Entry] = []
        var epoch: [LiveTranscriptState.Entry] = []

        func flush() {
            let remote = epoch.compactMap { entry -> LiveTranscriptState.Block? in
                guard case .speech(let block) = entry, block.speaker == .them else { return nil }
                return block
            }
            visible.append(contentsOf: epoch.filter { entry in
                guard case .speech(let block) = entry, block.speaker == .you else { return true }
                return !isEcho(block, of: remote)
            })
            epoch.removeAll(keepingCapacity: true)
        }

        for entry in entries {
            if case .resumed = entry {
                flush()
                visible.append(.resumed)
            } else {
                epoch.append(entry)
            }
        }
        flush()
        return visible
    }

    private static func isEcho(
        _ microphone: LiveTranscriptState.Block,
        of system: [LiveTranscriptState.Block]
    ) -> Bool {
        let heard = words(microphone.text)
        guard heard.count >= minimumWords else { return false }

        let anchors = system.filter { block in
            let timely = abs(microphone.startMilliseconds - block.startMilliseconds)
                <= maximumStartDelta
            let bothActive = microphone.isProvisional && block.isProvisional
            guard timely || bothActive else { return false }
            return longestCommonSubsequence(heard, words(block.text)) >= minimumAnchorWords
        }
        let heardCharacters = Array(heard.joined())

        return anchors.contains { anchor in
            let played = system.filter {
                abs($0.startMilliseconds - anchor.startMilliseconds)
                    <= maximumCombinedStartDelta
            }.flatMap { words($0.text) }
            let wordCoverage = Double(longestCommonSubsequence(heard, played))
                / Double(heard.count)
            let playedCharacters = Array(played.joined())
            let characterCoverage = Double(longestCommonSubsequence(
                heardCharacters, playedCharacters
            )) / Double(heardCharacters.count)
            return max(wordCoverage, characterCoverage) >= minimumCoverage
        }
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func longestCommonSubsequence<Element: Equatable>(
        _ lhs: [Element], _ rhs: [Element]
    ) -> Int {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        var previous = Array(repeating: 0, count: rhs.count + 1)
        for left in lhs {
            var current = Array(repeating: 0, count: rhs.count + 1)
            for (index, right) in rhs.enumerated() {
                current[index + 1] = left == right
                    ? previous[index] + 1
                    : max(previous[index + 1], current[index])
            }
            previous = current
        }
        return previous[rhs.count]
    }
}

/// The streaming engine reports the whole session's transcript on every
/// chunk, so a block that has already been closed keeps arriving as the head
/// of the next report. This subtracts what is already on screen and hands
/// back only what belongs to the block being written now.
struct CumulativePartials: Sendable {
    private var latest: [LiveTranscriptState.Speaker: String] = [:]
    private var closed: [LiveTranscriptState.Speaker: String] = [:]

    /// What the current block should say, or nil when the report carries
    /// nothing beyond the blocks already closed.
    mutating func text(
        from report: String,
        for speaker: LiveTranscriptState.Speaker
    ) -> String? {
        latest[speaker] = report
        var rest = Substring(report)
        if let shown = closed[speaker], report.hasPrefix(shown) {
            rest = rest.dropFirst(shown.count)
        }
        // Punctuation belongs to the sentence that has already been closed —
        // the full stop it ended on often arrives a beat after the pause did.
        // No block opens on one, and a report that adds nothing but a comma
        // adds nothing at all.
        while let first = rest.first,
              first.isWhitespace || Self.trailingMarks.contains(first) {
            rest = rest.dropFirst()
        }
        return rest.isEmpty ? nil : String(rest)
    }

    private static let trailingMarks: Set<Character> = [
        ",", ".", "!", "?", ";", ":", "…", "。", "、", "—", "–", "-",
    ]

    /// Remembers everything seen from this speaker so far as spoken for.
    ///
    /// Asking the engine to commit clears its own accumulation, but reports
    /// decoded before that landed are still on their way, and they carry the
    /// closed text with them. Holding the whole report rather than the block's
    /// text is also what keeps the split working when the engine did not clear
    /// anything at all.
    mutating func close(_ speaker: LiveTranscriptState.Speaker) {
        guard let full = latest[speaker] else { return }
        closed[speaker] = full
    }

    mutating func reset() {
        latest.removeAll(keepingCapacity: true)
        closed.removeAll(keepingCapacity: true)
    }
}

import Foundation
import SwiftUI

/// Foundation parses CommonMark; each presentation block gets native layout so
/// nested lists keep their structure instead of flattening into one Text view.
struct SummaryMarkdownBlock: Identifiable {
    let id: Int
    var text: AttributedString
    let depth: Int
    var marker: String?
    let heading: Int?
    let code: Bool
    let quote: Bool

    static func parse(_ source: String) -> [Self] {
        guard let parsed = try? AttributedString(markdown: source) else {
            return [Self(id: 0, text: AttributedString(source), depth: 0, heading: nil, code: false, quote: false)]
        }
        var blocks: [Self] = []
        var markedItems = Set<Int>()
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let id = components.first?.identity ?? 0
            var content = AttributedString(parsed[run.range]); content.presentationIntent = nil
            if blocks.last?.id == id { blocks[blocks.count - 1].text += content; continue }
            let items = components.filter { if case .listItem = $0.kind { return true }; return false }
            let list = components.first { $0.kind == .orderedList || $0.kind == .unorderedList }
            var marker: String?
            if let item = items.first, markedItems.insert(item.identity).inserted, case .listItem(let ordinal) = item.kind {
                marker = list?.kind == .orderedList ? "\(ordinal)." : items.count == 1 ? "•" : items.count == 2 ? "◦" : "▪"
            }
            let heading: Int? = components.compactMap { if case .header(let level) = $0.kind { return level }; return nil }.first
            let code = components.contains { if case .codeBlock = $0.kind { return true }; return false }
            blocks.append(Self(id: id, text: content, depth: items.count, marker: marker, heading: heading,
                code: code, quote: components.contains { $0.kind == .blockQuote }))
        }
        return blocks
    }
}

struct SummaryMarkdown: View {
    private let blocks: [SummaryMarkdownBlock]
    init(_ source: String) { blocks = SummaryMarkdownBlock.parse(source) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if block.depth > 0 {
                        Text(block.marker ?? "").frame(width: 20, alignment: .trailing)
                            .accessibilityHidden(true)
                    }
                    Text(block.text)
                        .font(block.code ? JottieStyle.mono(12) : JottieStyle.font(block.heading.map { $0 <= 2 ? 18 : 15 } ?? 14,
                            block.heading == nil ? .regular : .semibold))
                        .lineSpacing(6).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, CGFloat(max(0, block.depth - 1)) * 22 + (block.quote ? 12 : 0))
                .padding(.vertical, block.code ? 10 : 0)
                .background(block.code ? JottieStyle.surface : .clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .leading) { if block.quote { Rectangle().fill(JottieStyle.border).frame(width: 2) } }
                .padding(.top, index == 0 ? 0 : block.depth > 0 ? 7 : 14)
            }
        }.font(JottieStyle.font(14)).foregroundStyle(JottieStyle.muted).textSelection(.enabled)
    }
}

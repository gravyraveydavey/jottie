import SwiftUI
import JottieModels

struct SidebarFolderEntry: Identifiable {
    let folder: Folder
    let depth: Int
    let isLastSibling: Bool
    let ancestorContinues: [Bool]
    let expanded: Bool
    var id: UUID { folder.id }

    static func visible(_ folders: [Folder], collapsed: Set<UUID>) -> [Self] {
        let children = Dictionary(grouping: folders, by: \.parentID)
        var result: [Self] = [], visited = Set<UUID>()
        func appendChildren(of parent: UUID?, depth: Int, ancestors: [Bool]) {
            let siblings = (children[parent] ?? []).sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
            }
            for (index, folder) in siblings.enumerated() where visited.insert(folder.id).inserted {
                let last = index == siblings.count - 1
                let expanded = children[folder.id]?.isEmpty == false && !collapsed.contains(folder.id)
                result.append(Self(folder: folder, depth: depth, isLastSibling: last, ancestorContinues: ancestors, expanded: expanded))
                if expanded {
                    appendChildren(of: folder.id, depth: depth + 1, ancestors: depth == 0 ? [] : ancestors + [!last])
                }
            }
        }
        appendChildren(of: nil, depth: 0, ancestors: [])
        return result
    }
}

struct FolderTreeBranches: Shape {
    let entry: SidebarFolderEntry
    static let indent: CGFloat = 18
    static let iconCenter: CGFloat = 17
    func path(in rect: CGRect) -> Path {
        var path = Path()
        func vertical(_ level: Int, from start: CGFloat, to end: CGFloat) {
            let x = Self.iconCenter + CGFloat(level) * Self.indent
            path.move(to: CGPoint(x: x, y: start)); path.addLine(to: CGPoint(x: x, y: end))
        }
        for (level, continues) in entry.ancestorContinues.enumerated() where continues {
            vertical(level, from: 0, to: rect.height)
        }
        if entry.depth > 0 {
            vertical(entry.depth - 1, from: 0, to: entry.isLastSibling ? rect.midY : rect.height)
            path.move(to: CGPoint(x: Self.iconCenter + CGFloat(entry.depth - 1) * Self.indent, y: rect.midY))
            path.addLine(to: CGPoint(x: Self.iconCenter + CGFloat(entry.depth) * Self.indent - 8, y: rect.midY))
        }
        if entry.expanded { vertical(entry.depth, from: rect.midY + 7, to: rect.height) }
        return path
    }
}

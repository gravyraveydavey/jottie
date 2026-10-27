import SwiftUI
import AppKit
import JottieModels
import JottieLibrary

@MainActor struct MeetingListPane: View {
    @ObservedObject var model: LibraryViewModel
    var editFolder: (Folder) -> Void
    @FocusState private var listFocused: Bool
    @FocusState private var searchFocused: Bool
    private struct DayGroup: Identifiable { var id: Date; var hits: [SearchHit] }
    private var groups: [DayGroup] {
        var result: [DayGroup] = []
        for hit in model.hits {
            let date = Calendar.current.startOfDay(for: hit.meeting.startedAt)
            if result.last?.id == date { result[result.count - 1].hits.append(hit) }
            else { result.append(DayGroup(id: date, hits: [hit])) }
        }
        return result
    }
    var body: some View {
        VStack(spacing: 0) {
            listHeader
            JottieRule()
            ScrollViewReader { proxy in
                ScrollView {
                    if model.hits.isEmpty {
                        JottieEmpty(title: "No meetings found", message: "Try another search or tag, or choose a different folder.", icon: "magnifyingglass")
                    } else {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(groups) { group in
                                Text(dayLabel(group.id)).font(JottieStyle.font(11, .medium)).foregroundStyle(JottieStyle.muted)
                                    .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 6)
                                ForEach(group.hits) { hit in
                                    MeetingCard(hit: hit, selected: model.selection.contains(hit.id), searching: !model.query.isEmpty) {
                                        listFocused = true
                                        let modifiers = NSEvent.modifierFlags
                                        model.select(hit.id, extending: modifiers.contains(.command), range: modifiers.contains(.shift))
                                    }
                                    .id(hit.id).draggable(dragValue(hit.id))
                                    .contextMenu {
                                        Button(hit.meeting.starred == true ? "Unstar meeting" : "Star meeting") { Task { await model.toggleStar(hit.meeting) } }
                                        Button("Export Markdown…") { if !model.selection.contains(hit.id) { model.select(hit.id) }; model.export() }
                                        Button("Regenerate summary") { Task { await model.regenerate(hit.meeting) } }
                                        Menu("Move to folder") {
                                            Button("Import (unfiled)") { Task { await model.move([hit.id], to: nil) } }
                                            ForEach(model.flatFolders, id: \.folder.id) { item in
                                                Button(String(repeating: "  ", count: item.depth) + item.folder.name) { Task { await model.move([hit.id], to: item.folder.id) } }
                                            }
                                        }
                                        Button("Move to Trash", role: .destructive) { if !model.selection.contains(hit.id) { model.select(hit.id) }; model.trashSelection() }
                                    }
                                }
                            }
                            if model.hasMore {
                                Button("Load more meetings") { Task { await model.loadMore() } }.buttonStyle(JottieButtonStyle(kind: .outline)).padding()
                            }
                        }.padding(8)
                    }
                }
                .focusable().focused($listFocused).focusEffectDisabled()
                .onMoveCommand { direction in
                    if direction == .up { model.selectAdjacent(-1) }
                    if direction == .down { model.selectAdjacent(1) }
                    if let id = model.focusedMeetingID { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) } }
                }
                .onKeyPress("a", phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    model.selection = Set(model.hits.map(\.id)); return .handled
                }
            }
            JottieRule()
            HStack {
                Text("\(model.hits.count)\(model.hasMore ? "+" : "") \(model.hits.count == 1 ? "meeting" : "meetings") · Local library")
                Spacer()
                if model.selection.count > 1 {
                    Button { model.export() } label: { Label("\(model.selection.count)", systemImage: "square.and.arrow.up") }
                        .buttonStyle(JottieButtonStyle(compact: true)).help("Export selected meetings as Markdown")
                    Button { model.trashSelection() } label: { Image(systemName: "trash") }.buttonStyle(JottieButtonStyle(compact: true)).help("Move selected meetings to Trash")
                }
            }.font(JottieStyle.font(11)).foregroundStyle(JottieStyle.muted).padding(.horizontal, 20).frame(minHeight: 42)
        }.background(JottieStyle.background).accessibilityElement(children: .contain).accessibilityLabel("Meeting list")
    }
    private var listHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text(model.locationTitle).font(JottieStyle.font(18, .semibold)).tracking(-0.3)
                JottieBadge(text: String(model.hits.count))
                Spacer(minLength: 0)
                if let folder = model.selectedFolder {
                    Menu {
                        Button("Folder overview") { model.selection = []; model.focusedMeetingID = nil }
                        Button("Edit folder…") { editFolder(folder) }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().help("Folder overview and settings")
                }
            }
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(JottieStyle.muted)
                TextField("", text: $model.query, prompt: Text("Search meetings…").foregroundStyle(JottieStyle.muted)).textFieldStyle(.plain).focused($searchFocused).accessibilityLabel("Search meetings")
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Clear search")
                }
            }.font(JottieStyle.font(14)).padding(.horizontal, 10).frame(height: 34)
                .background(JottieStyle.background, in: RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).stroke(searchFocused ? JottieStyle.accent.opacity(0.6) : JottieStyle.border, lineWidth: searchFocused ? 1.5 : 1) }
            HStack {
                TagMenu(model: model)
                Spacer(minLength: 2)
                Button { model.oldestFirst.toggle() } label: {
                    Label(model.oldestFirst ? "Oldest first" : "Newest first", systemImage: "line.3.horizontal.decrease")
                }.buttonStyle(JottieButtonStyle(compact: true)).help("Change meeting date order")
                Button { model.filterDates.toggle() } label: { Image(systemName: "calendar") }
                    .buttonStyle(JottieButtonStyle(compact: true)).foregroundStyle(model.filterDates ? JottieStyle.accent : JottieStyle.muted).help("Filter meetings by date")
            }
            if model.filterDates {
                DatePicker("From", selection: $model.after, displayedComponents: .date)
                DatePicker("To", selection: $model.before, displayedComponents: .date)
            }
        }.padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 16)
    }
    private func dayLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
    private func dragValue(_ id: UUID) -> String {
        let ids = model.selection.contains(id) ? Array(model.selection) : [id]
        return "meeting:" + ids.map(\.uuidString).sorted().joined(separator: ",")
    }
}

@MainActor private struct TagMenu: View {
    @ObservedObject var model: LibraryViewModel
    @ViewState private var open = false
    @ViewState private var highlighted = ""
    @FocusState private var menuFocused: Bool
    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 8) { Text(model.tag.isEmpty ? "All tags" : model.tag).lineLimit(1); Image(systemName: "chevron.down").font(.system(size: 9)) }
        }.buttonStyle(JottieButtonStyle(kind: .outline, compact: true)).help("Filter by tag")
            .accessibilityLabel("Filter by tag")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            tagRow("All tags", value: "").id("")
                            ForEach(model.tags, id: \.self) { tagRow($0, value: $0).id($0) }
                        }.padding(5)
                    }
                    .focusable().focused($menuFocused).focusEffectDisabled()
                    .onAppear { highlighted = model.tag; menuFocused = true }
                    .onMoveCommand { direction in
                        let values = [""] + model.tags
                        let index = values.firstIndex(of: highlighted) ?? 0
                        if direction == .down { highlighted = values[min(values.count - 1, index + 1)] }
                        if direction == .up { highlighted = values[max(0, index - 1)] }
                        proxy.scrollTo(highlighted)
                    }
                    .onKeyPress(.return) { model.tag = highlighted; open = false; return .handled }
                    .onKeyPress(.escape) { open = false; return .handled }
                }.frame(width: 190, height: min(360, CGFloat(model.tags.count + 1) * 34 + 10))
                    .background(JottieStyle.background).preferredColorScheme(model.colorScheme)
            }
    }
    private func tagRow(_ title: String, value: String) -> some View {
        Button { model.tag = value; open = false } label: {
            HStack { Text(title); Spacer(); if model.tag == value { Image(systemName: "checkmark") } }.frame(maxWidth: .infinity)
        }.buttonStyle(JottieButtonStyle()).background(highlighted == value ? JottieStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
            .onHover { if $0 { highlighted = value } }.accessibilityAddTraits(model.tag == value ? .isSelected : [])
    }
}

private struct MeetingCard: View {
    let hit: SearchHit
    let selected: Bool
    let searching: Bool
    let action: () -> Void
    @ViewState private var hovering = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top, spacing: 8) {
                    Text(hit.meeting.displayTitle).font(JottieStyle.font(13, .semibold)).lineLimit(2).lineSpacing(3)
                    Spacer(minLength: 0)
                    if hit.meeting.starred == true { Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(JottieStyle.accent.opacity(0.75)) }
                }
                Text(searching ? hit.snippet : hit.meeting.analysis?.analysis.summary ?? hit.meeting.importedSummary ?? hit.snippet)
                    .font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted).lineLimit(2).lineSpacing(6)
                HStack(spacing: 6) {
                    Text(hit.meeting.startedAt.formatted(.dateTime.hour().minute()))
                    if let duration = hit.meeting.durationLabel { Text("·"); Text(duration) }
                    Spacer(minLength: 0)
                    ForEach(Array((hit.meeting.analysis?.analysis.tags ?? []).prefix(2)), id: \.self) { JottieBadge(text: $0, outlined: true) }
                }.font(JottieStyle.font(11)).foregroundStyle(JottieStyle.muted)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .foregroundStyle(selected ? JottieStyle.selectedText : JottieStyle.foreground)
                .background(selected ? JottieStyle.selection : hovering ? JottieStyle.surface.opacity(0.7) : .clear, in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).stroke(selected ? JottieStyle.accent.opacity(0.15) : .clear, lineWidth: 1) }
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).onHover { hovering = $0 }.animation(.easeOut(duration: 0.12), value: hovering)
            .accessibilityLabel(hit.meeting.displayTitle).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension Meeting {
    var durationLabel: String? {
        let milliseconds = segments.map(\.endMS).max() ?? 0
        guard milliseconds > 0 else { return nil }
        return "\(max(1, Int(ceil(Double(milliseconds) / 60000)))) min"
    }
    var speakerLabels: [String] { Array(Set(segments.map(\.speaker))).sorted() }
}

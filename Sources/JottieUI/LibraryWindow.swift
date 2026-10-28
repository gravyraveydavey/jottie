import SwiftUI
import AppKit
import JottieModels
import JottieLibrary
import JottieKnowledge

typealias ViewState<Value> = SwiftUI.State<Value>

@MainActor public final class LibraryWindow {
    public let model: LibraryViewModel
    private let window: NSWindow
    public init(model: LibraryViewModel) {
        self.model = model
        let controller = NSHostingController(rootView: LibraryView(model: model))
        window = NSWindow(contentViewController: controller)
        window.title = "Jottie"; window.setContentSize(NSSize(width: 1440, height: 900))
        window.minSize = NSSize(width: 1040, height: 640)
        window.styleMask.insert([.resizable, .miniaturizable])
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        if model.store.root.standardizedFileURL == LibraryStore.defaultRoot.standardizedFileURL {
            window.setFrameAutosaveName("jottie.library")
        }
        window.isReleasedWhenClosed = false
    }
    public func show() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    public func showSettings() { show(); Task { await model.openSettings() } }
    func renderedPreview() throws -> Data {
        guard let view = window.contentView else { throw JottieError.unavailable("Missing library view.") }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw JottieError.unavailable("Could not prepare the library preview.") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw JottieError.unavailable("Could not render the library preview.") }
        return data
    }
    func closePreview() { window.close() }
}

@MainActor struct LibraryView: View {
    @ObservedObject var model: LibraryViewModel
    @ViewState private var editingFolder: Folder?
    @ViewState private var collapsed = Set<UUID>()
    @ViewState private var sidebarWidth: CGFloat = 248
    @ViewState private var listWidth: CGFloat = 360
    @ViewState private var liveExpanded = false
    @Environment(\.colorScheme) private var systemScheme
    private var isDark: Bool { model.appearance == "dark" || (model.appearance == "system" && systemScheme == .dark) }
    var body: some View {
        GeometryReader { geometry in
            let sidebarSize = min(sidebarWidth, max(205, geometry.size.width - 640))
            let listSize = min(listWidth, max(280, geometry.size.width - sidebarSize - 360))
            HStack(spacing: 0) {
                sidebar.frame(width: sidebarSize)
                JottieDivider(width: $sidebarWidth, limits: 205...min(310, max(205, geometry.size.width - 640)), defaultWidth: 248, label: "Resize sidebar")
                VStack(spacing: 0) {
                    header
                    if let message = model.message { announcement(message) }
                    if model.capture.isRecording || model.capture.configProblem != nil || model.capture.transcription != nil || model.capture.mediaImport != nil { captureBar }
                    if model.location == "settings" { LibrarySettingsView(model: model) }
                    else if model.location == "queue" { QueuePane(model: model) }
                    else if model.location == "trash" { TrashPane(model: model) }
                    else {
                        HStack(spacing: 0) {
                            MeetingListPane(model: model, editFolder: { editingFolder = $0 }).frame(width: listSize)
                            JottieDivider(width: $listWidth, limits: 280...min(480, max(280, geometry.size.width - sidebarSize - 360)), defaultWidth: 360, label: "Resize meeting list")
                            detail.frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(JottieStyle.background).foregroundStyle(JottieStyle.foreground)
        .font(JottieStyle.font()).tint(JottieStyle.accent)
        .preferredColorScheme(model.colorScheme)
        .sheet(item: $editingFolder) { FolderEditor(model: model, folder: $0).preferredColorScheme(model.colorScheme) }
        .task(id: model.query) {
            do { try await Task.sleep(for: .milliseconds(150)); await model.search() }
            catch { /* A new keystroke supersedes this search. */ }
        }
        .onChange(of: model.tag) { _, _ in Task { await model.search() } }
        .onChange(of: model.oldestFirst) { _, _ in Task { await model.search() } }
        .onChange(of: model.filterDates) { _, _ in Task { await model.search() } }
        .onChange(of: model.after) { _, _ in Task { await model.search() } }
        .onChange(of: model.before) { _, _ in Task { await model.search() } }
        .task {
            while !Task.isCancelled {
                await model.reload()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "waveform").font(.system(size: 22, weight: .medium)).foregroundStyle(.white)
                    .frame(width: 36, height: 36).background(JottieStyle.accent, in: RoundedRectangle(cornerRadius: 12))
                (Text("jottie").foregroundStyle(JottieStyle.foreground) + Text(".").foregroundStyle(JottieStyle.accent))
                    .font(JottieStyle.font(22, .semibold)).tracking(-0.8)
            }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 32)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    sidebarHeading("Library")
                    navigationRow("All meetings", icon: "books.vertical", location: "all", count: model.meetings.count)
                        .dropDestination(for: String.self) { values, _ in model.drop(values, into: nil) }
                    navigationRow("Starred", icon: "star", location: "starred", count: model.meetings.filter { $0.starred == true }.count)
                    navigationRow("Queue", icon: "checklist", location: "queue", count: model.jobs.count + model.capture.transcriptionItems.count)
                    navigationRow("Trash", icon: "trash", location: "trash", count: model.trash.count)
                    sidebarHeading("Folders").padding(.top, 28)
                    ForEach(visibleFolders, id: \.folder.id) { item in folderRow(item.folder, depth: item.depth) }
                }.padding(.horizontal, 12)
            }
            VStack(spacing: 16) {
                Button { editingFolder = Folder(name: "") } label: {
                    Label("New folder", systemImage: "folder.badge.plus").frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(JottieButtonStyle()).help("Create a new folder")
                JottieRule()
                HStack {
                    Button { Task { await model.openSettings() } } label: {
                        Label("Settings", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(JottieButtonStyle())
                    Button { model.appearance = isDark ? "light" : "dark" } label: {
                        Image(systemName: isDark ? "sun.max" : "moon")
                    }.buttonStyle(JottieButtonStyle()).help("Toggle colour theme").accessibilityLabel("Toggle colour theme")
                }
            }.padding(12)
        }.frame(maxHeight: .infinity).background(JottieStyle.sidebar)
    }
    private func sidebarHeading(_ title: String) -> some View {
        Text(title).font(JottieStyle.font(11, .medium)).foregroundStyle(JottieStyle.muted).padding(.horizontal, 8).padding(.vertical, 7)
    }
    private func navigationRow(_ title: String, icon: String, location: String, count: Int) -> some View {
        Button { model.navigate(location) } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).frame(width: 16)
                Text(title).lineLimit(1); Spacer(minLength: 2)
                Text(String(count)).font(JottieStyle.font(11, .medium))
            }.padding(.horizontal, 9).frame(height: 32).contentShape(Rectangle())
        }.buttonStyle(SidebarRowStyle(selected: model.location == location))
            .accessibilityAddTraits(model.location == location ? .isSelected : [])
    }
    private var visibleFolders: [(folder: Folder, depth: Int)] {
        model.flatFolders.filter { item in
            var parent = item.folder.parentID
            var visited = Set<UUID>()
            while let id = parent, visited.insert(id).inserted {
                if collapsed.contains(id) { return false }
                parent = model.folders.first { $0.id == id }?.parentID
            }
            return true
        }
    }
    private func folderRow(_ folder: Folder, depth: Int) -> some View {
        HStack(spacing: 0) {
            if depth > 0 {
                Rectangle().fill(JottieStyle.border).frame(width: 1).padding(.leading, CGFloat(depth * 20 - 2))
                    .overlay(alignment: .trailing) { Rectangle().fill(JottieStyle.border).frame(width: 10, height: 1).offset(x: 9) }
            }
            Button { model.navigate(folder.id.uuidString) } label: {
                HStack(spacing: 9) {
                    Image(systemName: model.location == folder.id.uuidString ? "folder.fill" : "folder").frame(width: 16)
                    Text(folder.name).lineLimit(1); Spacer(minLength: 0)
                    if !model.folders.contains(where: { $0.parentID == folder.id }) {
                        Text(String(model.folderMeetings(folder).count)).font(JottieStyle.font(11, .medium))
                    }
                }.padding(.horizontal, 9).frame(height: 34).contentShape(Rectangle())
            }.buttonStyle(SidebarRowStyle(selected: model.location == folder.id.uuidString))
            if model.folders.contains(where: { $0.parentID == folder.id }) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        if collapsed.contains(folder.id) { collapsed.remove(folder.id) } else { collapsed.insert(folder.id) }
                    }
                } label: { Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium)).rotationEffect(.degrees(collapsed.contains(folder.id) ? 0 : 90)) }
                .buttonStyle(JottieButtonStyle(compact: true)).help("Toggle \(folder.name) subfolders")
                .accessibilityLabel("Toggle \(folder.name) subfolders")
            }
        }
        .draggable("folder:\(folder.id.uuidString)")
        .dropDestination(for: String.self) { values, _ in model.drop(values, into: folder.id) }
        .contextMenu {
            Button("Edit folder…") { editingFolder = folder }
            Button("New subfolder…") { editingFolder = Folder(name: "", parentID: folder.id) }
            Button("Move to root") { var f = folder; f.parentID = nil; Task { await model.saveFolder(f) } }
        }
    }
    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button("Your library") { model.navigate("all") }.buttonStyle(.plain).foregroundStyle(JottieStyle.muted)
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(JottieStyle.muted)
                Text(model.locationTitle).lineLimit(1)
                Spacer(minLength: 8)
                Button { Task { await model.updateSummaries() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text(model.working ? "Updating…" : "Update summaries")
                        if model.updateCount > 0 { JottieBadge(text: String(model.updateCount)) }
                    }
                }.buttonStyle(JottieButtonStyle()).disabled(model.working || model.settingsDirty)
                    .help("Update missing summaries and summaries using an earlier prompt")
                Button { model.importTranscripts() } label: { HStack(spacing: 6) { JottieImportIcon(); Text("Import") } }
                    .buttonStyle(JottieButtonStyle(kind: .outline)).help("Import audio, video, transcript folders, Markdown, text or Word documents")
                Button { model.onRecord?() } label: { Label(model.capture.isRecording ? "Stop recording" : "New recording", systemImage: model.capture.isRecording ? "stop.circle" : "mic") }
                    .buttonStyle(JottieButtonStyle(kind: .primary)).disabled(model.onRecord == nil)
                    .help(model.capture.isRecording ? "Stop and transcribe this recording" : "Start a local meeting recording")
            }.font(JottieStyle.font(12)).padding(.horizontal, 24).frame(height: 64)
            JottieRule()
        }
    }
    private func announcement(_ text: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(text).font(JottieStyle.font(12)).textSelection(.enabled).lineLimit(3)
                Spacer()
                Button { model.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(JottieButtonStyle(compact: true)).help("Dismiss message")
            }.padding(.horizontal, 20).padding(.vertical, 6).background(JottieStyle.surface)
            JottieRule()
        }
    }
    private var captureBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(model.capture.label, systemImage: "record.circle.fill").foregroundStyle(model.capture.isRecording ? Color.red : JottieStyle.muted).monospacedDigit()
                if model.capture.isRecording {
                    Button(model.capture.state == .paused ? "Resume" : "Pause") { model.onPause?() }.buttonStyle(JottieButtonStyle(kind: .outline, compact: true))
                }
                Spacer()
                Toggle("Live transcript", isOn: Binding(get: { model.capture.liveEnabled }, set: { model.onLive?($0) })).toggleStyle(.switch).controlSize(.small)
            }
            if let problem = model.capture.configProblem { Text(problem).foregroundStyle(.red) }
            if let text = model.capture.transcription { Text(text).foregroundStyle(JottieStyle.muted) }
            if let text = model.capture.mediaImport { Text(text).foregroundStyle(JottieStyle.muted) }
            if model.capture.liveEnabled && (model.capture.isRecording || !model.capture.liveText.isEmpty) {
                DisclosureGroup(model.capture.liveStatus, isExpanded: $liveExpanded) {
                    ScrollView { Text(model.capture.liveText.isEmpty ? "Waiting for speech…" : model.capture.liveText).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(maxHeight: 160)
                }
            }
        }.font(JottieStyle.font(12)).padding(12).background(JottieStyle.selection)
    }
    @ViewBuilder private var detail: some View {
        if let meeting = model.selectedMeeting { MeetingDetailPane(model: model, meeting: meeting).id(meeting.id) }
        else if let folder = model.selectedFolder { FolderDetailPane(folder: folder, model: model) }
        else { JottieEmpty(title: "Your meetings, connected", message: "Choose a meeting, import transcript folders, or start a recording.") }
    }
}

struct SidebarRowStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        SidebarRow(configuration: configuration, selected: selected)
    }
    private struct SidebarRow: View {
        let configuration: ButtonStyle.Configuration
        let selected: Bool
        @ViewState private var hover = false
        var body: some View {
            configuration.label.font(JottieStyle.font(14, selected ? .medium : .regular))
                .foregroundStyle(selected ? JottieStyle.selectedText : JottieStyle.foreground)
                .background(selected ? JottieStyle.navigationSelection : hover ? JottieStyle.surface : .clear, in: RoundedRectangle(cornerRadius: 8))
                .onHover { hover = $0 }.animation(.easeOut(duration: 0.12), value: hover)
        }
    }
}

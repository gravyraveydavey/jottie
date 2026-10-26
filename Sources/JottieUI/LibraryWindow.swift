import SwiftUI
import AppKit
import JottieModels
import JottieLibrary
import JottieKnowledge

// Select the property-wrapper type explicitly: SDK 27 also exports a State macro,
// whose plugin is absent from standalone Command Line Tools installations.
typealias ViewState<Value> = SwiftUI.State<Value>

@MainActor public final class LibraryWindow {
    public let model: LibraryViewModel
    private let window: NSWindow
    public init(model: LibraryViewModel) {
        self.model = model
        let controller = NSHostingController(rootView: LibraryView(model: model))
        window = NSWindow(contentViewController: controller)
        window.title = "Jottie"; window.setContentSize(NSSize(width: 1240, height: 800))
        window.styleMask.insert([.resizable, .miniaturizable])
        window.setFrameAutosaveName("jottie.library")
        window.isReleasedWhenClosed = false
    }
    public func show() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    public func showSettings() { show(); Task { await model.openSettings() } }
    /// Renders this view hierarchy in memory for synthetic-data layout checks.
    func renderedPreview() throws -> Data {
        guard let view = window.contentView else { throw JottieError.unavailable("Missing library view.") }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw JottieError.unavailable("Could not prepare the library preview.")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw JottieError.unavailable("Could not render the library preview.")
        }
        return data
    }
    func closePreview() { window.close() }
}

@MainActor struct LibraryView: View {
    @ObservedObject var model: LibraryViewModel
    @ViewState private var editingFolder: Folder?
    @ViewState private var speakerSheet = false
    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView { sidebar } content: { contentPane } detail: { detailPane }
            if let message = model.message {
                HStack { Text(message).font(.callout); Spacer(); Button { model.message = nil } label: { Image(systemName: "xmark") }.help("Dismiss this message") }
                    .padding(10).background(.quaternary)
            }
            if model.progress.total > 0 || !model.jobs.isEmpty {
                DisclosureGroup(model.progress.label) {
                    ProgressView(value: Double(model.progress.completed), total: Double(max(1, model.progress.total)))
                    ScrollView {
                        ForEach(model.jobs) { job in
                            HStack {
                                Text("\(job.stage) · \(job.state)").font(.caption).frame(width: 210, alignment: .leading)
                                Text(job.message ?? "Waiting for processing").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Retry") { Task { await model.retry(job) } }.disabled(job.state == "running")
                            }.padding(.vertical, 3)
                        }
                    }.frame(maxHeight: 100)
                }.padding(10)
            }
        }
        .searchable(text: $model.query, prompt: "Search all meeting text")
        .toolbar {
            ToolbarItemGroup {
                Button { model.onRecord?() } label: { Label("Record", systemImage: "record.circle") }
                    .help("Start or stop a meeting recording")
                Button { model.importTranscripts() } label: { Label("Import", systemImage: "square.and.arrow.down") }.help("Import transcript folders, Markdown, text or Word documents")
                Button { model.export() } label: { Label("Export Markdown", systemImage: "square.and.arrow.up") }.disabled(model.selection.isEmpty).help("Export selected meetings as Markdown")
                Button { Task { await model.regenerate() } } label: { Label("Regenerate analysis", systemImage: "sparkles") }.disabled(model.selection.isEmpty || model.working).help("Regenerate summaries and tags for selected meetings using current settings")
                Button { speakerSheet = true } label: { Label("Speakers", systemImage: "person.2") }.disabled(model.selection.count != 1).help("Correct speaker names for the selected meeting")
                Button { model.trashSelection() } label: { Label("Trash", systemImage: "trash") }.disabled(model.selection.isEmpty).help("Move selected meetings to local Trash")
                Button { Task { await model.openSettings() } } label: { Label("Settings", systemImage: "gearshape") }.help("Open Jottie settings, Codex, prompts and MCP setup")
            }
        }
        .sheet(isPresented: $model.settingsOpen) { LibrarySettingsView(model: model) }
        .sheet(item: $editingFolder) { FolderEditor(model: model, folder: $0) }
        .sheet(isPresented: $speakerSheet) {
            if let meeting = model.selectedMeeting { SpeakerEditor(model: model, meeting: meeting) }
        }
        .onChange(of: model.location) { _, _ in model.selection = []; Task { await model.search() } }
        .onChange(of: model.query) { _, _ in Task { await model.search() } }
        .onChange(of: model.tag) { _, _ in Task { await model.search() } }
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

                List(selection: $model.location) {
                    Label("All Meetings", systemImage: "rectangle.stack").tag("all")
                        .dropDestination(for: String.self) { values, _ in model.drop(values, into: nil) }
                    Label("Import", systemImage: "tray").tag("inbox")
                        .help("Unfiled recordings and imported transcripts; drag meetings into folders to file them")
                        .dropDestination(for: String.self) { values, _ in model.drop(values, into: nil) }
                    Section("Folders") {
                        ForEach(model.flatFolders, id: \.folder.id) { item in
                            Label(item.folder.name, systemImage: item.folder.destination == nil ? "folder" : "folder.badge.gearshape")
                                .padding(.leading, CGFloat(item.depth * 12))
                                .tag(item.folder.id.uuidString)
                                .draggable("folder:\(item.folder.id.uuidString)")
                                .dropDestination(for: String.self) { values, _ in model.drop(values, into: item.folder.id) }
                                .contextMenu {
                                    Button("Edit folder…") { editingFolder = item.folder }
                                    Button("New subfolder…") { editingFolder = Folder(name: "", parentID: item.folder.id) }
                                    Button("Move to root") { var f = item.folder; f.parentID = nil; Task { await model.saveFolder(f) } }
                                }
                        }
                    }
                }
                .navigationTitle("Jottie")
                .safeAreaInset(edge: .bottom) {
                    Button { editingFolder = Folder(name: "") } label: { Label("New folder", systemImage: "folder.badge.plus") }.help("Create a folder for meetings and shared context").padding()
                }
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)

    }
    private var contentPane: some View {

                VStack(spacing: 0) {
                    HStack {
                        Picker("Tag", selection: $model.tag) {
                            Text("All tags").tag("")
                            ForEach(model.tags, id: \.self) { Text($0).tag($0) }
                        }.labelsHidden()
                        Toggle("Dates", isOn: $model.filterDates).toggleStyle(.checkbox)
                    }.padding(10)
                    if model.filterDates {
                        HStack {
                            DatePicker("From", selection: $model.after, displayedComponents: .date)
                            DatePicker("To", selection: $model.before, displayedComponents: .date)
                        }.padding(.horizontal, 10).font(.caption)
                    }
                    if let folder = model.selectedFolder {
                        HStack {
                            Text(folder.name).font(.headline)
                            Spacer()
                            Button("Context") { model.selection = [] }
                            Button { editingFolder = folder } label: { Image(systemName: "ellipsis") }.help("Edit folder name, aliases, parent and publication destination")
                        }.padding(10)
                    }
                    MeetingListPane(model: model)
                }
                .navigationTitle(model.selectedFolder?.name ?? (model.location == "inbox" ? "Import" : "Meetings"))
                .navigationSplitViewColumnWidth(min: 280, ideal: 360)

    }
    @ViewBuilder private var detailPane: some View {

                if let meeting = model.selectedMeeting {
                    MeetingDetail(meeting: meeting)
                } else if let folder = model.selectedFolder {
                    FolderDetail(folder: folder, model: model)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "waveform.bubble").font(.system(size: 48)).foregroundStyle(.secondary)
                        Text("Your meetings, connected").font(.title2)
                        Text("Select a meeting, import transcript folders, or start recording.").foregroundStyle(.secondary)
                        Button("Import transcripts…") { model.importTranscripts() }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }

    }

}

@MainActor private struct MeetingListPane: View {
    @ObservedObject var model: LibraryViewModel
    var body: some View {
        List(model.hits, selection: $model.selection) { hit in
            MeetingListRow(hit: hit).draggable(dragValue(hit.id))
        }
        .safeAreaInset(edge: .bottom) {
            if model.hasMore { Button("Load more meetings") { Task { await model.loadMore() } }.padding(8) }
        }
    }
    private func dragValue(_ id: UUID) -> String {
        let ids: [String] = model.selection.contains(id) ? model.selection.map { $0.uuidString }.sorted() : [id.uuidString]
        return "meeting:" + ids.joined(separator: ",")
    }
}

private struct MeetingListRow: View {
    let hit: SearchHit
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(hit.meeting.displayTitle).font(.headline).lineLimit(2)
                Spacer()
                if hit.meeting.analysis == nil { Image(systemName: "clock").foregroundStyle(.secondary) }
            }
            Text(hit.meeting.startedAt, style: .date).font(.caption).foregroundStyle(.secondary)
            Text(hit.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            if let tags = hit.meeting.analysis?.analysis.tags, !tags.isEmpty {
                Text(tags.map { "#\($0)" }.joined(separator: " ")).font(.caption).foregroundStyle(.tint).lineLimit(1)
            }
        }.padding(.vertical, 7)
    }
}

private struct MeetingDetail: View {
    let meeting: Meeting
    @ViewState private var tab = "summary"
    var body: some View {
        VStack(alignment: .leading) {
            Text(meeting.displayTitle).font(.largeTitle).padding([.horizontal, .top], 24)
            HStack {
                Text(meeting.startedAt, style: .date)
                if let reason = meeting.filingReason { Text("· \(reason)") }
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24)
            Picker("View", selection: $tab) { Text("Summary").tag("summary"); Text("Transcript").tag("transcript") }
                .pickerStyle(.segmented).padding(.horizontal, 24)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if tab == "transcript" {
                        Text(meeting.transcript).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    } else if let a = meeting.analysis?.analysis {
                        Text(a.summary).font(.body).textSelection(.enabled)
                        if !a.topics.isEmpty { Text(a.topics.joined(separator: " · ")).foregroundStyle(.secondary) }
                        ForEach([("Decisions", a.decisions), ("Actions", a.actions), ("Follow-up questions", a.questions)], id: \.0) { title, items in
                            if !items.isEmpty {
                                Text(title).font(.title3.bold())
                                ForEach(items) { item in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.text).textSelection(.enabled)
                                        Text(([item.status, item.owner, item.dueDate].compactMap { $0 }).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                        DisclosureGroup("Evidence") {
                                            ForEach(Array(item.evidence.enumerated()), id: \.offset) { _, e in Text("\(e.segmentID): “\(e.quote)”").font(.caption).textSelection(.enabled) }
                                        }.font(.caption)
                                    }
                                }
                            }
                        }
                        if !a.uncertainties.isEmpty { Text("Uncertainties").font(.headline); Text(a.uncertainties.joined(separator: "\n")) }
                    } else if let imported = meeting.importedSummary {
                        Text("Imported Amanu summary").font(.headline)
                        Text(imported).textSelection(.enabled)
                    } else {
                        Text("The full transcript is ready. Enable Codex analysis in Library Settings to generate a summary and tags.")
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct FolderDetail: View {
    let folder: Folder
    @ObservedObject var model: LibraryViewModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(folder.name).font(.largeTitle); Spacer()
                    Button("Update now") { Task { await model.updateNow() } }.disabled(model.working)
                }
                Text("Includes meetings in all subfolders. Checks every \(model.settings.refreshMinutes) minutes.").font(.caption).foregroundStyle(.secondary)
                if let context = model.contexts[folder.id] {
                    let expected = LibraryStore.contextFingerprint(folder: folder, folders: model.folders, meetings: model.meetings, settings: model.settings)
                    Text(context.inputRevision == expected ? "Up to date" : "Changes pending · showing last successful context").foregroundStyle(context.inputRevision == expected ? Color.secondary : Color.orange)
                    Text(context.overview).textSelection(.enabled)
                    ContextSections(context: context)
                    Text("Updated \(context.generatedAt.formatted())").font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Source meetings") {
                        ForEach(Array(Set(context.sources.map(\.meetingID))).sorted { $0.uuidString < $1.uuidString }, id: \.self) { id in
                            Button(model.meetings.first { $0.id == id }?.displayTitle ?? id.uuidString) { model.selection = [id] }
                        }
                    }
                } else { Text("Context will be generated after meetings in this folder have been analysed.") }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ContextSections: View {
    let context: FolderContext
    private var sections: [(String, [ContextEntry])] {
        [("Decision log", context.decisions),
         ("Open actions", context.actions.filter { $0.status != "completed" }),
         ("Follow-up questions", context.questions.filter { $0.status != "resolved" }),
         ("Recent changes", context.recentChanges)]
    }
    var body: some View {
        ForEach(sections, id: \.0) { title, entries in
            Text(title).font(.title3.bold())
            if entries.isEmpty { Text("None recorded.").foregroundStyle(.secondary) }
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.text).textSelection(.enabled)
                    Text(([entry.status, entry.owner, entry.dueDate].compactMap { $0 }).joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

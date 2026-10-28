import AppKit
import SwiftUI
import EventKit
import UniformTypeIdentifiers
import JottieModels
import JottieLibrary
import JottieKnowledge

@MainActor public final class EventKitCalendars: CalendarProvider {
    private let store = EKEventStore()
    public static var grantedDuringProcess = false
    public init() {}
    public func choices() async throws -> [CalendarChoice] {
        let granted = EKEventStore.authorizationStatus(for: .event) == .fullAccess || Self.grantedDuringProcess
            ? true : try await store.requestFullAccessToEvents()
        guard granted else { throw JottieError.unavailable("Calendar access was denied. Enable it in System Settings.") }
        Self.grantedDuringProcess = true
        store.reset()
        return store.calendars(for: .event).map {
            CalendarChoice(id: $0.calendarIdentifier, title: "\($0.source.title) — \($0.title)")
        }.sorted { $0.title < $1.title }
    }
}

/// Capture presentation stays in the manager; the recording engine remains in its adapter.
public struct CapturePresentation: Equatable {
    public enum State { case idle, recording, paused }
    public var state: State = .idle
    public var elapsed: String?
    public var autoRecord = false
    public var autoDecision: String?
    public var liveEnabled = false
    public var liveStatus = ""
    public var liveText = ""
    public var transcription: String?
    public var configProblem: String?
    public var mediaImport: String?
    public var importResult: String?
    public var transcriptionItems: [CaptureQueueItem] = []
    public init() {}
    public var isRecording: Bool { state != .idle }
    public var label: String {
        let name = state == .idle ? "Ready to record" : state == .paused ? "Recording paused" : "Recording"
        return elapsed.map { "\(name) · \($0)" } ?? name
    }
}

public struct CaptureQueueItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let state: String
    public let detail: String
    public init(id: String, title: String, state: String, detail: String) {
        self.id = id; self.title = title; self.state = state; self.detail = detail
    }
}

@MainActor public final class LibraryViewModel: ObservableObject {
    public let store: LibraryStore
    public let coordinator: KnowledgeCoordinator
    public let account: MicrosoftAccount
    public let publisher: GraphPublisher
    @Published public var capture = CapturePresentation()
    @Published public var meetings: [Meeting] = []
    @Published public var trash: [TrashEntry] = []
    @Published public var bambooStatus = "Not connected"
    @Published public var syncingBamboo = false
    @Published public var bambooKey = ""
    @Published public var directoryPeople: [DirectoryPerson] = []
    public var captureSettings: CaptureSettingsController?
    @Published public var hits: [SearchHit] = []
    @Published public var folders: [Folder] = []
    @Published public var contexts: [UUID: FolderContext] = [:]
    @Published public var jobs: [WorkStatus] = []
    @Published public var progress = ProcessingProgress()
    @Published public var selection = Set<UUID>()
    @Published public var focusedMeetingID: UUID?
    @Published public var oldestFirst = false
    @Published public var appearance = UserDefaults.standard.string(forKey: "jottie.appearance") ?? "system" {
        didSet { if persistPresentation { UserDefaults.standard.set(appearance, forKey: "jottie.appearance") } }
    }
    @Published public var savedSettings = LibrarySettings()
    @Published public var location = "all"
    @Published public var settingsTab = "General"
    @Published public var query = ""
    @Published public var tag = ""
    @Published public var filterDates = false
    @Published public var after = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
    @Published public var before = Date()
    @Published public var settings = LibrarySettings()
    @Published public var calendars: [CalendarChoice] = []
    @Published public var message: String?
    @Published public var working = false
    @Published public var hasMore = false
    @Published public var accountID = ""
    @Published public var codexStatus: CodexInstallation.Status?
    @Published public var codexModels: [CodexInstallation.ModelChoice] = []
    @Published public var checkingCodex = false
    @Published public var testingCodex = false
    @Published public var codexTestMessage: String?
    private let persistPresentation: Bool
    private var loadedSettings = false
    private var requestedPages = 1
    private var searchKey = ""
    private var autoSelectNextSearch = true
    public var onCaptureSettings: (() -> Void)?
    public var onRecord: (() -> Void)?
    public var onPause: (() -> Void)?
    public var onAutoRecord: (() -> Void)?
    public var onLive: ((Bool) -> Void)?
    public var onImportMedia: (([URL]) -> Void)?
    public var onRetryTranscription: (() -> Void)?
    public init(store: LibraryStore, coordinator: KnowledgeCoordinator, account: MicrosoftAccount, publisher: GraphPublisher) {
        self.store = store; self.coordinator = coordinator; self.account = account; self.publisher = publisher
        persistPresentation = store.root.standardizedFileURL == LibraryStore.defaultRoot.standardizedFileURL
    }
    public var selectedFolder: Folder? { folders.first { $0.id.uuidString == location } }
    public var selectedMeeting: Meeting? {
        if let focusedMeetingID, selection.contains(focusedMeetingID) { return meetings.first { $0.id == focusedMeetingID } }
        return hits.first { selection.contains($0.id) }?.meeting ?? meetings.first { selection.contains($0.id) }
    }
    public var locationTitle: String {
        selectedFolder?.name ?? ["all": "All meetings", "inbox": "Import", "starred": "Starred", "queue": "Queue", "trash": "Trash", "settings": "Settings"][location] ?? "Meetings"
    }
    public var colorScheme: ColorScheme? { appearance == "system" ? nil : appearance == "dark" ? .dark : .light }
    public var settingsDirty: Bool { settings != savedSettings }
    public var outdatedMeetings: [Meeting] { meetings.filter { $0.analysis?.promptRevision != savedSettings.analysisRevision } }
    public var staleFolders: [Folder] {
        folders.filter { folder in
            let ids = LibraryStore.descendants(folder.id, in: folders)
            return meetings.contains { $0.folderID.map(ids.contains) == true } && contexts[folder.id]?.inputRevision != LibraryStore.contextFingerprint(folder: folder, folders: folders, meetings: meetings, settings: savedSettings)
        }
    }
    public var updateCount: Int { outdatedMeetings.count + staleFolders.count }
    public func folderMeetings(_ folder: Folder) -> [Meeting] {
        let ids = LibraryStore.descendants(folder.id, in: folders)
        return meetings.filter { $0.folderID.map(ids.contains) == true }
    }
    public func navigate(_ destination: String) {
        location = destination; query = ""; tag = ""; selection = []; focusedMeetingID = nil
        autoSelectNextSearch = ["all", "inbox", "starred"].contains(destination)
        Task { await search() }
    }
    public func select(_ id: UUID, extending: Bool = false, range: Bool = false) {
        if range, let anchor = focusedMeetingID, let a = hits.firstIndex(where: { $0.id == anchor }), let b = hits.firstIndex(where: { $0.id == id }) {
            selection.formUnion(hits[min(a,b)...max(a,b)].map(\.id))
        } else if extending {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else { selection = [id] }
        focusedMeetingID = id
    }
    public func selectAdjacent(_ delta: Int) {
        guard !hits.isEmpty else { return }
        let current = focusedMeetingID.flatMap { id in hits.firstIndex { $0.id == id } } ?? (delta > 0 ? -1 : hits.count)
        select(hits[min(max(0, current + delta), hits.count - 1)].id)
    }
    public func openMeeting(_ id: UUID) {
        query = ""; tag = ""; filterDates = false; autoSelectNextSearch = false
        selection = [id]; focusedMeetingID = id
    }
    public func toggleStar(_ meeting: Meeting) async {
        do { try await store.setStarred(meeting.starred != true, meetingID: meeting.id); await reload() }
        catch { message = error.localizedDescription }
    }
    public func updateSummaries() async {
        guard !working else { return }
        guard savedSettings.analysisEnabled else { message = "Enable Codex analysis in Settings first."; return }
        working = true; defer { working = false }
        do {
            for meeting in outdatedMeetings where meeting.analysis != nil { try await coordinator.regenerate(meeting.id) }
            await coordinator.run(updateNow: true); await reload()
        } catch { message = error.localizedDescription }
    }
    public func regenerate(_ meeting: Meeting) async {
        guard !working else { return }
        working = true; defer { working = false }
        do { try await coordinator.regenerate(meeting.id); await reload() }
        catch { message = error.localizedDescription }
    }
    public var tags: [String] { Array(Set(meetings.flatMap { $0.analysis?.analysis.tags ?? [] })).sorted() }
    public var flatFolders: [(folder: Folder, depth: Int)] {
        func walk(_ parent: UUID?, depth: Int) -> [(Folder, Int)] {
            guard depth <= folders.count else { return [] }
            return folders.filter { $0.parentID == parent }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .flatMap { [($0, depth)] + walk($0.id, depth: depth + 1) }
        }
        return walk(nil, depth: 0)
    }
    public func reload() async {
        do {
            try await store.purgeTrash()
            trash = try await store.trashEntries()
            meetings = try await store.meetings(); folders = try await store.folders()
            if !loadedSettings {
                settings = try await store.settings(); savedSettings = settings
                loadedSettings = true
            }
            var loaded: [UUID: FolderContext] = [:]
            for folder in folders { loaded[folder.id] = try await store.context(folder.id) }
            contexts = loaded; jobs = try await coordinator.ledger.statuses()
            progress = try await coordinator.processingProgress()
            await search()
        } catch { message = error.localizedDescription }
    }
    public func search() async {
        do {
            guard !["trash", "settings", "queue"].contains(location) else { hits = []; hasMore = false; return }
            var search = SearchQuery()
            search.text = query; search.folderID = selectedFolder?.id; search.inbox = location == "inbox"
            search.starredOnly = location == "starred"; search.oldestFirst = oldestFirst
            search.tag = tag.isEmpty ? nil : tag
            if filterDates { search.after = after; search.before = before }
            let key = "\(location)|\(oldestFirst)|\(query)|\(tag)|\(filterDates)|\(search.after?.timeIntervalSince1970 ?? 0)|\(search.before?.timeIntervalSince1970 ?? 0)"
            if key != searchKey { searchKey = key; requestedPages = 1 }
            search.limit = 100
            var loaded: [SearchHit] = []
            var more = false
            for page in 0..<requestedPages {
                search.offset = page * 100
                let next = try await store.search(search)
                loaded += next
                more = next.count == 100
                if !more { break }
            }
            if searchKey == key {
                hits = loaded; hasMore = more
                let filtered = !query.isEmpty || !tag.isEmpty || filterDates || location == "starred"
                if filtered { selection.formIntersection(loaded.map(\.id)) }
                if selection.isEmpty && (autoSelectNextSearch || filtered), let first = loaded.first { select(first.id) }
                autoSelectNextSearch = false
            }
        } catch { message = error.localizedDescription }
    }
    public func loadMore() async { requestedPages += 1; await search() }
    @discardableResult public func saveSettings(processPending: Bool = true) async -> Bool {
        do {
            settings.codexModel = settings.codexModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if settings.bambooEnabled { settings.bambooCompany = try BambooHR.company(settings.bambooCompany) }
            try await store.saveSettings(settings); savedSettings = settings
            message = "Settings saved. Existing analyses are unchanged."
            if processPending { Task { await coordinator.run(); await reload() } }
            return true
        }
        catch { message = error.localizedDescription; return false }
    }
    public func openSettings() async {
        do { settings = try await store.settings(); savedSettings = settings; loadedSettings = true; navigate("settings") }
        catch { message = error.localizedDescription }
    }
    public func checkCodex() async {
        guard !checkingCodex else { return }
        checkingCodex = true; defer { checkingCodex = false }
        let path = settings.codexPath
        let result = await CodexInstallation.probe(path: path)
        if settings.codexPath == path {
            codexStatus = result
            let choices = result.version == nil ? [] : await CodexInstallation.models(path: result.executable)
            if settings.codexPath == path { codexModels = choices }
        }
    }
    public var codexEfforts: [String] {
        [""] + (codexModels.first { $0.id == settings.codexModel }?.efforts ?? Array(LibrarySettings.efforts.dropFirst()))
    }
    public func testCodex() async {
        guard !testingCodex else { return }
        testingCodex = true; codexTestMessage = nil
        defer { testingCodex = false }
        await checkCodex()
        guard let status = codexStatus, status.ready else { return }
        do {
            try await CodexRunner(executable: status.executable, timeout: 120, model: settings.codexModel, effort: settings.codexEffort).testConnection()
            codexTestMessage = "Connection successful. Codex returned a valid structured response."
        } catch { codexTestMessage = error.localizedDescription }
    }
    @discardableResult public func saveFolder(_ folder: Folder) async -> Bool {
        do { try await store.saveFolder(folder); await reload(); return true }
        catch { message = error.localizedDescription; return false }
    }
    public func move(_ ids: [UUID], to folder: UUID?) async {
        do { try await store.file(ids, into: folder); await reload() }
        catch { message = error.localizedDescription }
    }
    public func drop(_ strings: [String], into folder: UUID?) -> Bool {
        guard let text = strings.first else { return false }
        if text.hasPrefix("meeting:") {
            let ids = text.dropFirst(8).split(separator: ",").compactMap { UUID(uuidString: String($0)) }
            guard !ids.isEmpty else { return false }
            Task { await move(ids, to: folder) }; return true
        }
        if text.hasPrefix("folder:"), let id = UUID(uuidString: String(text.dropFirst(7))),
           var value = folders.first(where: { $0.id == id }) {
            value.parentID = folder
            Task { await saveFolder(value) }; return true
        }
        return false
    }
    public func importTranscripts() {
        let panel = NSOpenPanel()
        panel.title = "Import into Jottie"; panel.prompt = "Import"
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .movie, .plainText, .text] + ["md", "markdown", "doc", "docx"].compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose audio or video files, transcript documents, or folders containing Markdown, text or Word transcripts. Transcript subfolders are included. Originals are preserved."
        guard panel.runModal() == .OK else { return }
        importURLs(panel.urls)
    }
    /// One selection can contain documents and media. Only explicitly selected
    /// media files enter capture; folder traversal remains text-only.
    public func importURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        navigate("queue")
        let media = urls.filter { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true,
                  let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return type.conforms(to: .audio) || type.conforms(to: .movie)
        }
        let documents = urls.filter { !media.contains($0) }
        if !media.isEmpty {
            if let onImportMedia { onImportMedia(media) }
            else { message = "Audio and video import is available in the full Jottie app. Open Jottie without the library-only command to transcribe these files." }
        }
        guard !documents.isEmpty else { return }
        Task {
            working = true; defer { working = false }
            do {
                let report = try await store.importTranscripts(from: documents)
                message = "Imported/updated \(report.imported) transcripts; \(report.unchanged) unchanged, \(report.failures.count) could not be read. Originals preserved."
                    + report.failures.prefix(3).map { "\n" + $0 }.joined()
                await coordinator.run(); await reload()
            } catch { message = error.localizedDescription }
        }
    }
    public func export() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ids = Array(selection)
        Task {
            do { try await store.export(ids, to: url); message = "Exported \(ids.count) Markdown files." }
            catch { message = error.localizedDescription }
        }
    }
    public func updateNow() async {
        working = true; defer { working = false }
        await coordinator.run(updateNow: true); await reload()
    }
    public func regenerate() async {
        working = true; defer { working = false }
        do { for id in selection { try await coordinator.regenerate(id) }; await reload() }
        catch { message = error.localizedDescription }
    }
    public func retry(_ job: WorkStatus) async {
        do { try await coordinator.ledger.retry(job.id); await coordinator.run(updateNow: true); await reload() }
        catch { message = error.localizedDescription }
    }
    public func trashSelection() {
        let alert = NSAlert()
        alert.messageText = "Move \(selection.count) meeting(s) to Jottie Trash?"
        alert.informativeText = "Records can be restored for 48 hours, then are deleted when Jottie is running. Published copies are retained."
        alert.addButton(withTitle: "Move to Trash"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do { try await store.trash(Array(selection)); selection = []; await reload() }
            catch { message = error.localizedDescription }
        }
    }
    public func restoreTrash(_ item: TrashEntry) async {
        do { try await store.restoreTrash(item.id); await reload(); message = "Meeting restored." }
        catch { message = error.localizedDescription }
    }
    public func emptyTrash() async {
        do { let count = try await store.purgeTrash(emptyAll: true); await reload(); message = "Deleted \(count) meetings from Trash." }
        catch { message = error.localizedDescription }
    }
    public func refreshPeople(for meeting: Meeting) async {
        do {
            let current = try await store.meeting(meeting.id)
            let saved = try await store.settings()
            guard saved.bambooEnabled else { message = "Connect BambooHR in Settings → Integrations first."; return }
            let company = try BambooHR.company(saved.bambooCompany)
            let directory = try PeopleDirectory(root: store.root)
            let matches = try await directory.matching(current.directoryIdentityCandidates, company: company)
            _ = try await store.setParticipantContext(matches, meetingID: current.id)
            await reload()
            message = "Matched \(matches.count) of \(current.directoryIdentityCandidates.count) invitation/transcript identities against the local directory. Summary revisions are unchanged."
        } catch { message = error.localizedDescription }
    }
    public func attachCalendar(_ event: CalendarEventContext, to meeting: Meeting) async {
        do {
            try await store.setCalendarContext(event, meetingID: meeting.id)
            await reload()
            if savedSettings.bambooEnabled { await refreshPeople(for: meeting) }
            else { message = "Calendar context attached. Regenerate explicitly to update the summary." }
        } catch { message = error.localizedDescription }
    }
    public func loadDirectoryPeople() async {
        guard savedSettings.bambooEnabled, let company = try? BambooHR.company(savedSettings.bambooCompany) else { directoryPeople = []; return }
        do { directoryPeople = try await PeopleDirectory(root: store.root).snapshot(company: company).people }
        catch { message = error.localizedDescription }
    }
    public func saveAliases(_ text: String, for person: DirectoryPerson) async {
        do {
            let company = try BambooHR.company(savedSettings.bambooCompany)
            let directory = try PeopleDirectory(root: store.root)
            try await directory.setAliases(text.components(separatedBy: ","), employeeID: person.id, company: company)
            await loadDirectoryPeople()
            message = "Aliases saved locally. Regenerate a meeting to use them in new analysis."
        } catch { message = error.localizedDescription }
    }
    public func refreshBambooStatus() async {
        guard let company = try? BambooHR.company(settings.bambooCompany) else { bambooStatus = "Enter a company address to connect."; return }
        do {
            let directory = try PeopleDirectory(root: store.root)
            let snapshot = try await directory.snapshot(company: company)
            guard (try? BambooHR.company(settings.bambooCompany)) == company else { return }
            directoryPeople = snapshot.people
            bambooStatus = snapshot.syncedAt.map { "\(snapshot.people.count) people · Last synced \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Not synced yet"
        } catch { bambooStatus = error.localizedDescription }
    }
    public func syncBamboo() async {
        guard !syncingBamboo else { return }
        syncingBamboo = true; defer { syncingBamboo = false }
        do {
            let company = try BambooHR.company(settings.bambooCompany)
            let key = bambooKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let secret = try key.isEmpty ? BambooKeychain.read(company: company) : key
            guard let secret, !secret.isEmpty else { throw JottieError.invalid("Enter a BambooHR API key first.") }
            let people = try await BambooHR.fetch(company: company, key: secret)
            guard (try? BambooHR.company(settings.bambooCompany)) == company else { throw JottieError.conflict("Company changed during sync. Retry for the selected company.") }
            // Commit only after a complete successful fetch. A failure keeps the previous cache intact.
            try BambooKeychain.save(secret, company: company)
            bambooKey = ""
            let directory = try PeopleDirectory(root: store.root)
            try await directory.replace(people, company: company)
            settings.bambooCompany = company; settings.bambooEnabled = true
            guard await saveSettings(processPending: false) else { return }
            await refreshBambooStatus()
            message = "BambooHR directory synced. Names and job titles will enrich new analysis and explicit regenerations."
        } catch { bambooStatus = error is JottieError ? error.localizedDescription : "Could not connect to BambooHR. Check your connection and try again." }
    }
    public func disconnectBamboo() async {
        do {
            if let company = try? BambooHR.company(settings.bambooCompany) { try BambooKeychain.remove(company: company) }
            let directory = try PeopleDirectory(root: store.root); try await directory.clear()
            settings.bambooEnabled = false; bambooKey = ""
            _ = await saveSettings(processPending: false); await refreshBambooStatus()
        } catch { message = error.localizedDescription }
    }
    public func signIn() async {
        do {
            try account.configure(clientID: settings.microsoftClientID, tenantID: settings.microsoftTenantID)
            guard let controller = NSApp.keyWindow?.contentViewController else { throw JottieError.unavailable("Open Jottie's library window first.") }
            accountID = try await account.signIn(presenting: controller)
            message = "Microsoft account connected. Choose a destination for a folder to enable publishing."
        } catch { message = error.localizedDescription }
    }
    public func configurePublisher() {
        try? account.configure(clientID: settings.microsoftClientID, tenantID: settings.microsoftTenantID)
    }
    public func connect(_ folder: Folder, url: String) async {
        do {
            guard !accountID.isEmpty else { throw JottieError.invalid("Sign into Microsoft first in Library Settings.") }
            let destination = try await publisher.resolve(folderURL: url, accountID: accountID, tenantID: settings.microsoftTenantID)
            var value = folder; value.destination = destination
            try await store.saveFolder(value); await reload()
            message = "Publishing enabled for \(folder.name) and its subfolders."
        } catch { message = error.localizedDescription }
    }
    public func copyMCPConfig() {
        let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? "jottie"
        let config = """
        [mcp_servers.jottie]
        command = "\(executable.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))"
        args = ["mcp", "serve", "--library", "\(store.root.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))"]
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(config, forType: .string)
        message = "Codex MCP configuration copied."
    }
}

import AppKit
import SwiftUI
import EventKit
import JottieModels
import JottieLibrary
import JottieKnowledge

@MainActor public final class EventKitCalendars: CalendarProvider {
    private let store = EKEventStore()
    public init() {}
    public func choices() async throws -> [CalendarChoice] {
        let granted = EKEventStore.authorizationStatus(for: .event) == .fullAccess
            ? true : try await store.requestFullAccessToEvents()
        guard granted else { throw JottieError.unavailable("Calendar access was denied. Enable it in System Settings.") }
        return store.calendars(for: .event).map {
            CalendarChoice(id: $0.calendarIdentifier, title: "\($0.source.title) — \($0.title)")
        }.sorted { $0.title < $1.title }
    }
}

@MainActor public final class LibraryViewModel: ObservableObject {
    public let store: LibraryStore
    public let coordinator: KnowledgeCoordinator
    public let account: MicrosoftAccount
    public let publisher: GraphPublisher
    @Published public var meetings: [Meeting] = []
    @Published public var hits: [SearchHit] = []
    @Published public var folders: [Folder] = []
    @Published public var contexts: [UUID: FolderContext] = [:]
    @Published public var jobs: [WorkStatus] = []
    @Published public var progress = ProcessingProgress()
    @Published public var selection = Set<UUID>()
    @Published public var location = "all"
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
    @Published public var settingsOpen = false
    @Published public var codexStatus: CodexInstallation.Status?
    @Published public var codexModels: [CodexInstallation.ModelChoice] = []
    @Published public var checkingCodex = false
    @Published public var testingCodex = false
    @Published public var codexTestMessage: String?
    private var loadedSettings = false
    private var requestedPages = 1
    private var searchKey = ""
    public var onCaptureSettings: (() -> Void)?
    public var onRecord: (() -> Void)?
    public init(store: LibraryStore, coordinator: KnowledgeCoordinator, account: MicrosoftAccount, publisher: GraphPublisher) {
        self.store = store; self.coordinator = coordinator; self.account = account; self.publisher = publisher
    }
    public var selectedFolder: Folder? { folders.first { $0.id.uuidString == location } }
    public var selectedMeeting: Meeting? { meetings.first { selection.contains($0.id) } }
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
            meetings = try await store.meetings(); folders = try await store.folders()
            if !loadedSettings {
                settings = try await store.settings()
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
            var search = SearchQuery()
            search.text = query; search.folderID = selectedFolder?.id; search.inbox = location == "inbox"
            search.tag = tag.isEmpty ? nil : tag
            if filterDates { search.after = after; search.before = before }
            let key = "\(location)|\(query)|\(tag)|\(filterDates)|\(search.after?.timeIntervalSince1970 ?? 0)|\(search.before?.timeIntervalSince1970 ?? 0)"
            if key != searchKey { searchKey = key; requestedPages = 1 }
            search.limit = 100
            var loaded: [SearchHit] = []
            hasMore = false
            for page in 0..<requestedPages {
                search.offset = page * 100
                let next = try await store.search(search)
                loaded += next
                hasMore = next.count == 100
                if !hasMore { break }
            }
            hits = loaded
        } catch { message = error.localizedDescription }
    }
    public func loadMore() async { requestedPages += 1; await search() }
    @discardableResult public func saveSettings(processPending: Bool = true) async -> Bool {
        do {
            settings.codexModel = settings.codexModel.trimmingCharacters(in: .whitespacesAndNewlines)
            try await store.saveSettings(settings)
            message = "Settings saved. Existing analyses are unchanged."
            if processPending { Task { await coordinator.run(); await reload() } }
            return true
        }
        catch { message = error.localizedDescription; return false }
    }
    public func openSettings() async {
        do { settings = try await store.settings(); loadedSettings = true; settingsOpen = true }
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
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.message = "Choose folders containing transcripts, or individual Markdown, text or Word documents (.md, .txt, .doc, .docx). Subfolders are included. Originals are preserved."
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            working = true; defer { working = false }
            do {
                let report = try await store.importTranscripts(from: urls)
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
        alert.informativeText = "Records remain in Jottie's local Trash. Published copies are retained."
        alert.addButton(withTitle: "Move to Trash"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do { try await store.trash(Array(selection)); selection = []; await reload() }
            catch { message = error.localizedDescription }
        }
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

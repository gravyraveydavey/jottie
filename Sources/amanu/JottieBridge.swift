import AppKit
import Darwin
import ArgumentParser
import JottieModels
import JottieLibrary
import JottieKnowledge
import JottieUI
import JottieMCP

/// The capture executable is an adapter, not a second owner of library content.
@MainActor final class JottieBridge {
    static let shared = JottieBridge()
    private var library: LibraryStore?
    private var nativeSettings: NativeCaptureSettings?
    private var lastBambooAttempt = Date.distantPast
    private var coordinator: KnowledgeCoordinator?
    private var window: LibraryWindow?
    private var ticker: Timer?
    private var processing: Task<Void, Never>?
    private var captureRoot: URL?
    private var errorMessage: String?
    private var capture = CapturePresentation()
    private init() {}
    func start(root: URL, onCaptureSettings: @escaping () -> Void, onRecord: @escaping () -> Void,
               onPause: @escaping () -> Void, onAutoRecord: @escaping () -> Void, onLive: @escaping (Bool) -> Void) {
        guard !Home.runsInsideTests, library == nil else { return }
        do {
            let libraryRoot = Home.current.url.appendingPathComponent("Library/Application Support/Jottie")
            let store = try LibraryStore(root: libraryRoot)
            let account = MicrosoftAccount()
            let publisher = try GraphPublisher(tokens: account, root: libraryRoot)
            let coordinator = try KnowledgeCoordinator(store: store, publisher: publisher)
            let model = LibraryViewModel(store: store, coordinator: coordinator, account: account, publisher: publisher)
            model.onCaptureSettings = onCaptureSettings; model.onRecord = onRecord
            model.onPause = onPause; model.onAutoRecord = onAutoRecord; model.onLive = onLive
            let nativeSettings = NativeCaptureSettings(isBusy: { [weak model] in
                model?.capture.isRecording == true || model?.capture.transcription != nil
            })
            self.nativeSettings = nativeSettings; model.captureSettings = nativeSettings.controller
            capture.liveEnabled = Config.liveTranscriptionEnabled()
            model.capture = capture
            library = store; self.coordinator = coordinator; window = LibraryWindow(model: model); captureRoot = root
            let legacySummary = Config.raw()["summary"] as? [String: Any]
            let backend = legacySummary?["backend"] as? String
            let enabled = legacySummary?["enabled"] as? Bool
            Task {
                do { try await store.migrateLegacyCodexPreference(backend: backend, enabled: enabled) }
                catch { model.message = error.localizedDescription }
                await model.reload(); model.configurePublisher()
                if !SetupState.isPending { window?.show() }
                schedule()
            }
            ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            }
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            }
        } catch { errorMessage = error.localizedDescription }
    }
    private func publishCapture() { window?.model.capture = capture }
    func updateRecording(_ state: MenuBarController.State, elapsed: String?) {
        capture.state = state == .idle ? .idle : state == .paused ? .paused : .recording
        capture.elapsed = elapsed; publishCapture()
    }
    func updateAutoRecord(enabled: Bool, decision: String?) {
        capture.autoRecord = enabled; capture.autoDecision = decision; publishCapture()
    }
    func updateLivePreference(enabled: Bool) { capture.liveEnabled = enabled; publishCapture() }
    func updateConfigProblem(_ problem: String?) { capture.configProblem = problem; publishCapture() }
    func updateTranscription(_ text: String?) { capture.transcription = text; publishCapture() }
    func updateImport(_ update: MediaImportCoordinator.Update) {
        capture.mediaImport = "Importing \(update.index) of \(update.total): \(update.source.lastPathComponent)"
        publishCapture()
    }
    func finishImport(_ result: MediaImportCoordinator.Result) {
        capture.mediaImport = nil; publishCapture()
        window?.model.message = "Imported \(result.imported.count) recordings; \(result.duplicates.count) duplicates; \(result.failures.count) failed."
    }
    func updateLive(_ snapshot: LiveTranscriptionCoordinator.Snapshot) {
        capture.liveEnabled = snapshot.isEnabled
        switch snapshot.status {
        case .idle: capture.liveStatus = "Live transcript"
        case .paused: capture.liveStatus = "Live transcript paused"
        case .loading: capture.liveStatus = "Loading live transcription"
        case .live: capture.liveStatus = "Live transcript"
        case .modelMissing: capture.liveStatus = "Live transcription model is missing"
        case .overloaded: capture.liveStatus = "Live transcription stopped: Mac could not keep up"
        case .error(let message): capture.liveStatus = "Live transcription stopped: " + message
        }
        capture.liveText = snapshot.entries.map { entry in
            switch entry {
            case .resumed: return "— Live transcript resumed —"
            case .speech(let block): return "\(block.speaker.label): \(block.text)"
            }
        }.joined(separator: "\n\n")
        publishCapture()
    }
    func schedule() {
        guard processing == nil, let store = library, let coordinator else { return }
        processing = Task {
            defer { processing = nil }
            do {
                // Adopt legacy Trash/deletion records before scanning capture sources.
                try await store.purgeTrash()
                if let root = captureRoot {
                    for dir in SessionInventory.sessionFolders(in: root) {
                        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path),
                              !TranscriptVersions.isRequested(dir) else { continue }
                        guard try await store.shouldImportAmanu(dir) else { continue }
                        _ = try await store.importAmanu(dir)
                    }
                }
                await refreshBambooIfDue(store: store)
                try await store.reconcile()
                await coordinator.run()
                await window?.model.reload()
            } catch { window?.model.message = error.localizedDescription }
        }
    }
    private func refreshBambooIfDue(store: LibraryStore) async {
        guard Date().timeIntervalSince(lastBambooAttempt) >= 3600 else { return }
        do {
            let settings = try await store.settings()
            guard settings.bambooEnabled, let company = try? BambooHR.company(settings.bambooCompany) else { return }
            let directory = try PeopleDirectory(root: store.root)
            let snapshot = try await directory.snapshot(company: company)
            // Background networking starts only after an explicit successful directory connection.
            guard let synced = snapshot.syncedAt, Date().timeIntervalSince(synced) >= 86400 else { return }
            lastBambooAttempt = Date()
            guard let key = try BambooKeychain.read(company: company) else { return }
            let people = try await BambooHR.fetch(company: company, key: key)
            // Re-check opt-in/company after the network request; settings may have changed meanwhile.
            let current = try await store.settings()
            guard current.bambooEnabled, (try? BambooHR.company(current.bambooCompany)) == company else { return }
            try await directory.replace(people, company: company)
            await window?.model.refreshBambooStatus()
        } catch { window?.model.bambooStatus = "Automatic BambooHR refresh failed. The last successful directory is retained; use Sync directory to retry." }
    }
    func ingest(_ dir: URL) async {
        guard !Home.runsInsideTests else { return }
        do {
            let store: LibraryStore
            if let library { store = library } else {
                store = try LibraryStore(root: Home.current.url.appendingPathComponent("Library/Application Support/Jottie"))
            }
            _ = try await store.importAmanu(dir)
            schedule()
        } catch { errorMessage = error.localizedDescription }
    }
    func show() {
        if let window { window.show() }
        else {
            let alert = NSAlert()
            alert.messageText = "Jottie library could not open"
            alert.informativeText = errorMessage ?? "Relaunch Jottie to initialise the library."
            alert.runModal()
        }
    }
    func showSettings() {
        if let window { window.showSettings() } else { show() }
    }
    func showRecordingSettings() {
        showSettings(); window?.model.settingsTab = "Recording"
    }
    func stop() { ticker?.invalidate(); processing?.cancel() }
}

struct CodexCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "codex", abstract: "Check Codex discovery, sign-in and the summary connection.")
    @Option(name: .long, help: "Executable path (automatic if omitted).") var executable = ""
    @Option(name: .long, help: "Library settings directory (default: Application Support/Jottie).") var library: String?
    @Option(name: .long, help: "Model ID override (otherwise use Jottie settings).") var model: String?
    @Option(name: .long, help: "Reasoning effort override (otherwise use Jottie settings).") var effort: String?
    @Flag(name: .long, help: "Also submit a small invented prompt using your Codex allowance.") var test = false
    func run() throws {
        let path = executable, shouldTest = test, modelOverride = model, effortOverride = effort
        let root = library.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? LibraryStore.defaultRoot
        Task {
            let settings: LibrarySettings
            do { settings = try await LibraryStore(root: root, readOnly: true).settings() }
            catch {
                FileHandle.standardError.write(Data("Jottie settings could not be read. Check the library directory.\n".utf8)); Darwin.exit(1)
            }
            let status = await CodexInstallation.probe(path: path.isEmpty ? settings.codexPath : path)
            print(status.message)
            if let version = status.version { print(version) }
            if !status.executable.isEmpty { print(status.executable) }
            guard status.ready else { Darwin.exit(1) }
            if shouldTest {
                do {
                    try await CodexRunner(executable: status.executable, timeout: 120, model: modelOverride ?? settings.codexModel, effort: effortOverride ?? settings.codexEffort).testConnection()
                    print("Connection successful: valid structured response.")
                } catch {
                    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); Darwin.exit(1)
                }
            }
            Darwin.exit(0)
        }
        dispatchMain()
    }
}

struct MCPCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mcp", abstract: "Read-only local meeting memory.", subcommands: [MCPServe.self])
}
struct MCPServe: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "serve", abstract: "Serve Jottie MCP over stdio without starting the GUI.")
    @Option(name: .long, help: "Library directory, defaulting to Application Support/Jottie.")
    var library: String?
    func run() throws {
        let root = library.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? LibraryStore.defaultRoot
        let server = try JottieServer(root: root)
        Task {
            do { try await server.serve(); Darwin.exit(0) }
            catch {
                FileHandle.standardError.write(Data("Jottie MCP could not start. Check the library path.\n".utf8))
                Darwin.exit(1)
            }
        }
        dispatchMain()
    }
}

struct LibraryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "library", abstract: "Open the meeting library without starting capture.")
    @Option(name: .long, help: "Library directory, defaulting to Application Support/Jottie.")
    var library: String?
    func run() throws {
        try MainActor.assumeIsolated {
            let root = library.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? LibraryStore.defaultRoot
            let store = try LibraryStore(root: root)
            let account = MicrosoftAccount()
            let publisher = try GraphPublisher(tokens: account, root: root)
            let coordinator = try KnowledgeCoordinator(store: store, publisher: publisher)
            let model = LibraryViewModel(store: store, coordinator: coordinator, account: account, publisher: publisher)
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let window = LibraryWindow(model: model)
            Task { try? await store.reconcile(); await model.reload(); model.configurePublisher() }
            let menu = NSMenu()
            let appMenu = NSMenu()
            appMenu.addItem(withTitle: "Quit Jottie", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            let item = NSMenuItem(); item.submenu = appMenu; menu.addItem(item); app.mainMenu = menu
            window.show()
            app.run()
            withExtendedLifetime(window) {}
        }
    }
}

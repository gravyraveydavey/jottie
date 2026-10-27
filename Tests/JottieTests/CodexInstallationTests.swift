import Foundation
import Testing
import JottieModels
import JottieLibrary
import JottieKnowledge
@testable import JottieUI

private func codexFixture(_ contents: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("jottie-codex-fixture-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let file = root.appendingPathComponent("codex")
    try Data(("#!/bin/sh\n" + contents).utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    return file
}

@Test func codexDiscoveryCoversFinderAndBothDesktopBundleLayouts() {
    let paths = CodexInstallation.candidates(environment: ["PATH": "/test/bin:relative:/test/bin"], home: "/test/home")
    #expect(paths.first == "/test/bin/codex")
    #expect(paths.filter { $0 == "/test/bin/codex" }.count == 1)
    #expect(!paths.contains("relative/codex"))
    for root in ["/Applications", "/test/home/Applications"] {
        #expect(paths.contains(root + "/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"))
        #expect(paths.contains(root + "/ChatGPT.app/Contents/Resources/codex"))
        #expect(paths.contains(root + "/Codex.app/Contents/Resources/codex"))
    }
}

@Test func codexProbeDistinguishesSubscriptionSignInFromMissingOrAPIKey() async throws {
    for (login, exit, ready) in [("Logged in using ChatGPT", 0, true), ("Not logged in", 1, false), ("Logged in using an API key", 0, false)] {
        let path = try codexFixture("""
        if [ "$1" = "--version" ]; then echo 'codex-cli 1.2.3'; exit 0; fi
        if [ "$1" != "--no-daemon" ] || [ "$2" != "login" ] || [ "$3" != "status" ]; then exit 12; fi
        echo '\(login)' >&2
        exit \(exit)
        """)
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let status = await CodexInstallation.probe(path: path.path)
        #expect(status.ready == ready)
        #expect(status.executable == path.path)
        #expect(status.version == "codex-cli 1.2.3")
    }
    let missing = await CodexInstallation.probe(path: "/missing/jottie-test-codex")
    #expect(!missing.ready)
    #expect(missing.version == nil)
}

@Test func codexProbeDoesNotExposeRawAuthenticationErrors() async throws {
    let path = try codexFixture("""
    if [ "$1" = "--version" ]; then echo 'codex-cli 1.2.3'; exit 0; fi
    echo 'secret-token-fixture authentication error' >&2
    exit 1
    """)
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    let status = await CodexInstallation.probe(path: path.path)
    #expect(!status.ready)
    #expect(!status.message.contains("secret-token-fixture"))
}

@Test func codexProcessesKeepSubscriptionLocationWithoutInheritingAPIKeys() {
    let environment = CodexRunner.environment(["PATH": "/custom/bin", "HOME": "/test/home", "CODEX_HOME": "/test/codex",
                                             "OPENAI_API_KEY": "secret", "CODEX_API_KEY": "secret", "DYLD_LIBRARY_PATH": "/test"])
    #expect(environment["HOME"] == "/test/home")
    #expect(environment["CODEX_HOME"] == "/test/codex")
    #expect(environment["OPENAI_API_KEY"] == nil)
    #expect(environment["CODEX_API_KEY"] == nil)
    #expect(environment["DYLD_LIBRARY_PATH"] == nil)
    #expect(environment["PATH"]?.contains("/opt/homebrew/bin") == true)
    #expect(CodexRunner(executable: " ~/bin/codex \n").executable == FileManager.default.homeDirectoryForCurrentUser.path + "/bin/codex")
}

@Test func codexRunnerReportsQuotaWithoutExposingRawDiagnostics() async throws {
    let path = try codexFixture("echo 'usage limit reached private-input-fixture' >&2\nexit 1\n")
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    do {
        try await CodexRunner(executable: path.path, timeout: 5).testConnection()
        Issue.record("Expected the failed CLI to defer analysis")
    } catch {
        #expect(error.localizedDescription.contains("allowance resets"))
        #expect(!error.localizedDescription.contains("private-input-fixture"))
    }
}

@Test func codexConnectionTestUsesStructuredRunnerWithInventedInput() async throws {
    let path = try codexFixture("""
    output=''
    while [ "$#" -gt 0 ]; do
        if [ "$1" = '-o' ]; then shift; output="$1"; fi
        shift
    done
    input=$(/bin/cat)
    case "$input" in *'invented data only'*) ;; *) exit 7 ;; esac
    printf '{"ready":true}' > "$output"
    """)
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    try await CodexRunner(executable: path.path, timeout: 5).testConnection()
}

@Test func explicitLegacyCodexChoiceMigratesOnceAndPreservesSavedOptOut() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("jottie-codex-migration-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root)
    #expect(try await !store.migrateLegacyCodexPreference(backend: nil, enabled: nil))
    #expect(try await !store.migrateLegacyCodexPreference(backend: "auto", enabled: true))
    #expect(try await !store.migrateLegacyCodexPreference(backend: "codex-cli", enabled: false))
    #expect(try await store.migrateLegacyCodexPreference(backend: "codex-cli", enabled: nil))
    #expect(try await store.settings().analysisEnabled)
    var settings = try await store.settings()
    settings.analysisEnabled = false; settings.summaryPrompt = "Keep my edited prompt."
    try await store.saveSettings(settings)
    #expect(try await !store.migrateLegacyCodexPreference(backend: "codex-cli", enabled: true))
    let reopened = try LibraryStore(root: root)
    #expect(try await !reopened.settings().analysisEnabled)
    #expect(try await reopened.settings().summaryPrompt == "Keep my edited prompt.")
}

@Test @MainActor func openingSettingsLoadsCanonicalSummaryPreferences() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("jottie-codex-settings-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root)
    var settings = LibrarySettings()
    settings.codexPath = "/chosen/codex"; settings.analysisEnabled = true
    try await store.saveSettings(settings)
    let account = MicrosoftAccount(), publisher = try GraphPublisher(tokens: account, root: root)
    let model = LibraryViewModel(store: store, coordinator: try KnowledgeCoordinator(store: store), account: account, publisher: publisher)
    await model.openSettings()
    #expect(model.location == "settings")
    #expect(model.settings.analysisEnabled)
    #expect(model.settings.codexPath == "/chosen/codex")
    model.settings.analysisEnabled = false
    #expect(await model.saveSettings())
    #expect(try await !store.settings().analysisEnabled)
}

private struct SettingsAnalyzer: MeetingAnalyzer {
    func analyze(_ meeting: Meeting, prompt: String, folders: [Folder]) async throws -> Analysis {
        Analysis(title: "Synthetic summary", summary: "The plan was approved.",
                 summaryEvidence: [Evidence(segmentID: "s1", quote: "The plan was approved.")])
    }
}

@Test @MainActor func enablingSummariesImmediatelyProcessesWaitingMeetings() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("jottie-codex-enabling-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root)
    let meeting = Meeting(sourceID: "synthetic-settings", title: "Test", segments: [Segment(id: "s1", speaker: "me", text: "The plan was approved.")])
    try await store.save(meeting)
    let account = MicrosoftAccount(), publisher = try GraphPublisher(tokens: account, root: root)
    let coordinator = try KnowledgeCoordinator(store: store, analyzer: SettingsAnalyzer())
    let model = LibraryViewModel(store: store, coordinator: coordinator, account: account, publisher: publisher)
    await model.openSettings()
    #expect(!model.settings.analysisEnabled)
    #expect(try await store.meeting(meeting.id).analysis == nil)
    model.settings.analysisEnabled = true
    #expect(await model.saveSettings())
    for _ in 0..<100 {
        if try await store.meeting(meeting.id).analysis != nil { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(try await store.meeting(meeting.id).analysis?.analysis.summary == "The plan was approved.")
}

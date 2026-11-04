import Foundation
import Testing
import JottieModels
import JottieLibrary
import AppKit
import SwiftUI
import JottieKnowledge
@testable import JottieUI

private func voiceVector(_ angle: Double = 0) -> [Float] {
    var result = [Float](repeating: 0, count: 256)
    result[0] = Float(cos(angle)); result[1] = Float(sin(angle)); return result
}

private struct VoiceFixture {
    let root: URL
    let store: LibraryStore
    static let key = Data(repeating: 37, count: 32)
    static func create(automatic: Bool = true) async throws -> VoiceFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("jottie-voices-" + UUID().uuidString)
        let store = try LibraryStore(root: root, voiceStorageKey: key)
        var settings = LibrarySettings(); settings.bambooCompany = "example"; settings.bambooEnabled = true
        try await store.saveSettings(settings)
        settings = try await store.settings(); settings.voiceLearningEnabled = true; settings.voiceAutoAssign = automatic
        try await store.saveSettings(settings)
        try await PeopleDirectory(root: root).replace([
            DirectoryPerson(id: "alice", name: "Alice Example"), DirectoryPerson(id: "bob", name: "Bob Example")
        ], company: "example")
        return VoiceFixture(root: root, store: store)
    }
    func recording(_ name: String, vector: [Float] = voiceVector(), model: String = "synthetic-model") async throws -> Meeting {
        let meeting = Meeting(sourceID: Codec.hash(name), title: name, segments: [
            Segment(id: "s1", speaker: "them 1", startMS: 0, endMS: 10000, text: "An invented project update."),
            Segment(id: "s2", speaker: "them 1", startMS: 10000, endMS: 20000, text: "Different invented words.")
        ])
        try await store.save(meeting)
        let settings = try await store.settings()
        try await store.saveVoiceEvidence(VoiceEvidence(sourceID: meeting.sourceID, company: settings.bambooCompany,
            generation: settings.voiceLearningGeneration, modelID: model, originalSegments: meeting.segments,
            samples: meeting.segments.map { VoiceSample(id: $0.id, speaker: $0.speaker, startMS: $0.startMS, endMS: $0.endMS, embedding: vector) }))
        return meeting
    }
    func assign(_ meeting: Meeting, employee: String?) async throws {
        try await store.setSpeakerAssignment(segmentIDs: meeting.segments.map(\.id),
            name: employee.map { $0 == "alice" ? "Alice Example" : "Bob Example" } ?? "", role: nil,
            employeeID: employee, meetingID: meeting.id)
    }
}

@Test func voiceEnrollmentUpdatesEarlierRecordingsAndSurvivesRestartWithoutAudio() async throws {
    let f = try await VoiceFixture.create(); defer { try? FileManager.default.removeItem(at: f.root) }
    let donor = try await f.recording("donor"), earlier = try await f.recording("earlier"), later = try await f.recording("later")
    #expect(try await f.store.refreshVoiceMatches().matchedPassages == 0)
    try await f.assign(donor, employee: "alice")
    let restarted = try LibraryStore(root: f.root, voiceStorageKey: VoiceFixture.key)
    let report = try await restarted.refreshVoiceMatches()
    #expect(report.recordings == 3 && report.enrolledPeople == 1 && report.matchedPassages == 4)
    for meeting in [earlier, later] {
        let updated = try await restarted.meeting(meeting.id)
        #expect(updated.segments == meeting.segments && updated.transcriptRevision == meeting.transcriptRevision)
        #expect(updated.speakerAttributions?["s1"]?.method == "voice")
        #expect(updated.speakerAttributions?["s1"]?.employeeID == "alice")
        #expect(updated.speakerAttributions?["s1"]?.voiceMatch?.sampleCount == 2)
    }
    #expect(try await restarted.refreshVoiceMatches().changedMeetings == 0)
}

@Test func voiceEnrollmentCorrectionAndUnknownRetractDependentAssignments() async throws {
    let f = try await VoiceFixture.create(); defer { try? FileManager.default.removeItem(at: f.root) }
    let donor = try await f.recording("donor"), other = try await f.recording("other")
    try await f.assign(donor, employee: "alice"); _ = try await f.store.refreshVoiceMatches()
    try await f.assign(donor, employee: "bob"); _ = try await f.store.refreshVoiceMatches()
    #expect(try await f.store.meeting(other.id).speakerAttributions?["s1"]?.employeeID == "bob")
    try await f.assign(donor, employee: nil); _ = try await f.store.refreshVoiceMatches()
    #expect(try await f.store.meeting(other.id).speakerAttributions == nil)
    #expect(try await f.store.meeting(donor.id).speakerAttributions?["s1"]?.method == "manual")
}

@Test func voiceMatchingRejectsGuestsAmbiguityAndIncompatibleModels() async throws {
    let f = try await VoiceFixture.create(); defer { try? FileManager.default.removeItem(at: f.root) }
    let donor = try await f.recording("donor"), guest = try await f.recording("guest", vector: voiceVector(.pi / 2))
    let differentModel = try await f.recording("different", model: "another-model")
    try await f.assign(donor, employee: "alice"); _ = try await f.store.refreshVoiceMatches()
    #expect(try await f.store.meeting(guest.id).speakerAttributions == nil)
    #expect(try await f.store.meeting(differentModel.id).speakerAttributions == nil)
    let otherDonor = try await f.recording("other-donor", vector: voiceVector(0.1))
    let query = try await f.recording("query")
    try await f.assign(otherDonor, employee: "bob"); _ = try await f.store.refreshVoiceMatches()
    #expect(try await f.store.meeting(query.id).speakerAttributions == nil)
}

@Test func voiceSuggestionsAreDefaultAndManualUnknownAlwaysWins() async throws {
    let f = try await VoiceFixture.create(automatic: false); defer { try? FileManager.default.removeItem(at: f.root) }
    let donor = try await f.recording("donor"), query = try await f.recording("query")
    try await f.assign(donor, employee: "alice"); _ = try await f.store.refreshVoiceMatches()
    let suggestion = try await f.store.meeting(query.id)
    #expect(suggestion.speakerAttributions == nil && suggestion.voiceSuggestions?["s1"]?.employeeID == "alice")
    try await f.assign(query, employee: nil)
    var settings = try await f.store.settings(); settings.voiceAutoAssign = true; try await f.store.saveSettings(settings)
    _ = try await f.store.refreshVoiceMatches()
    #expect(try await f.store.meeting(query.id).speakerAttributions?["s1"]?.name == "")
    #expect(try await f.store.meeting(query.id).voiceSuggestions == nil)
}

@Test func voiceEvidenceIsEncryptedAndNeverIncludedInMeetingExports() async throws {
    let f = try await VoiceFixture.create(); defer { try? FileManager.default.removeItem(at: f.root) }
    let donor = try await f.recording("donor"), query = try await f.recording("query")
    try await f.assign(donor, employee: "alice"); _ = try await f.store.refreshVoiceMatches()
    let bytes = try Data(contentsOf: f.root.appendingPathComponent("Voiceprints/\(donor.sourceID).aes"))
    #expect(!String(decoding: bytes, as: UTF8.self).contains("embedding"))
    let wrongKey = try LibraryStore(root: f.root, voiceStorageKey: Data(repeating: 38, count: 32))
    await #expect(throws: (any Error).self) { try await wrongKey.refreshVoiceMatches() }
    let encoded = String(decoding: try Codec.encode(await f.store.meeting(query.id)), as: UTF8.self)
    #expect(!encoded.contains("embedding") && !encoded.contains("originalSegments"))
    let output = f.root.appendingPathComponent("export")
    try await f.store.export([query.id], to: output)
    #expect(try FileManager.default.contentsOfDirectory(atPath: output.path) == [query.id.uuidString + ".md"])
}

@Test func voiceErasureInvalidatesInFlightCaptureAndDirectoryChangesClearEvidence() async throws {
    let f = try await VoiceFixture.create(); defer { try? FileManager.default.removeItem(at: f.root) }
    let donor = try await f.recording("donor"), query = try await f.recording("query")
    try await f.assign(donor, employee: "alice"); _ = try await f.store.refreshVoiceMatches()
    let old = try await f.store.settings()
    try await f.store.eraseVoiceprints()
    #expect(try await f.store.meeting(query.id).speakerAttributions == nil)
    #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Voiceprints").path))
    var settings = try await f.store.settings(); settings.voiceLearningEnabled = true; try await f.store.saveSettings(settings)
    try await f.store.saveVoiceEvidence(VoiceEvidence(sourceID: donor.sourceID, company: "example", generation: old.voiceLearningGeneration,
        modelID: "synthetic-model", originalSegments: donor.segments, samples: []))
    #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Voiceprints").path))
    _ = try await f.recording("new")
    settings = try await f.store.settings(); settings.bambooCompany = "other-company"; try await f.store.saveSettings(settings)
    #expect(try await f.store.settings().voiceLearningEnabled == false)
    #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Voiceprints").path))
}

@Test func voiceProfilesExcludeTrashedDonorsAndPurgeTheirEvidence() async throws {
    let f = try await VoiceFixture.create(); defer { try? FileManager.default.removeItem(at: f.root) }
    let donor = try await f.recording("donor"), query = try await f.recording("query")
    try await f.assign(donor, employee: "alice"); _ = try await f.store.refreshVoiceMatches()
    try await f.store.trash([donor.id]); _ = try await f.store.refreshVoiceMatches()
    #expect(try await f.store.meeting(query.id).speakerAttributions == nil)
    _ = try await f.store.purgeTrash(emptyAll: true)
    #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Voiceprints/\(donor.sourceID).aes").path))
}

@Test func voiceEvidenceRejectsMixedWindowsAndOverlappingCopiesCannotEnroll() async throws {
    let f = try await VoiceFixture.create(); defer { try? FileManager.default.removeItem(at: f.root) }
    let donor = try await f.recording("donor")
    let settings = try await f.store.settings()
    let samples = (0..<5).map { VoiceSample(id: "duplicate-\($0)", speaker: "them 1", startMS: $0 * 100, endMS: 10000 + $0 * 100, embedding: voiceVector()) }
    let record = VoiceEvidence(sourceID: donor.sourceID, company: "example", generation: settings.voiceLearningGeneration,
        modelID: "synthetic-model", originalSegments: donor.segments, samples: samples)
    try await f.store.saveVoiceEvidence(record); try await f.assign(donor, employee: "alice")
    #expect(try await f.store.refreshVoiceMatches().enrolledPeople == 0)
    var mixed = record; mixed.originalSegments[1].speaker = "them 2"
    let spanning = VoiceSample(id: "mixed", speaker: "them 1", startMS: 5000, endMS: 15000, embedding: voiceVector())
    #expect(mixed.passages(for: spanning).isEmpty)
    #expect(!VoiceSample(id: "short", speaker: "them 1", startMS: 0, endMS: 100, embedding: voiceVector()).isValid)
}

@Test func explicitLabelNamesOverrideExistingVoiceMatchesImmediately() {
    var meeting = Meeting(sourceID: "synthetic", title: "Manual priority", segments: [Segment(id: "a", speaker: "them 1", text: "Invented words.")])
    meeting.speakerAttributions = ["a": SpeakerAttribution(name: "Alice Example", method: "voice")]
    meeting.speakerNames = ["them 1": "Corrected Name"]
    #expect(meeting.speakerName(for: meeting.segments[0]) == "Corrected Name")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["JOTTIE_VOICE_UI_QA"] == "1"))
@MainActor func interactiveVoiceEnrollmentFixture() async throws {
    let f = try await VoiceFixture.create()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let donor = try await f.recording("Enroll this recording")
    let query = try await f.recording("Independent test recording")
    _ = try await f.recording("Unregistered guest", vector: voiceVector(.pi / 2))
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let model = LibraryViewModel(store: f.store, coordinator: try KnowledgeCoordinator(store: f.store),
        account: MicrosoftAccount(), publisher: try GraphPublisher(tokens: MicrosoftAccount(), root: f.root))
    await model.reload(); model.selection = [donor.id]
    let window = LibraryWindow(model: model)
    defer { window.closePreview() }
    window.show(); app.activate(ignoringOtherApps: true); app.finishLaunching()
    var matched = false
    for tick in 0..<(300 * 60) {
        while let event = app.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true) { app.sendEvent(event) }
        app.updateWindows()
        try await Task.sleep(for: .milliseconds(16))
        guard tick.isMultiple(of: 60) else { continue }
        let value = try await f.store.meeting(query.id)
        matched = value.speakerAttributions?["s1"]?.employeeID == "alice"
        if FileManager.default.fileExists(atPath: "/tmp/jottie-voice-ui-finish") { break }
    }
    #expect(matched)
}

@Test func voiceAssignmentsSurviveTextAnalysisAndRequestExplicitSummaryRefresh() async throws {
    let f = try await VoiceFixture.create(); defer { try? FileManager.default.removeItem(at: f.root) }
    let donor = try await f.recording("donor"), query = try await f.recording("query")
    var summarized = query
    summarized.importedSummary = "An earlier summary."
    summarized.sourceMetadata = ["summaryIdentityRevision": summarized.summaryIdentityRevision]
    try await f.store.save(summarized)
    try await f.assign(donor, employee: "alice"); _ = try await f.store.refreshVoiceMatches()
    let matched = try await f.store.meeting(query.id)
    #expect(matched.summaryNeedsIdentityRefresh)
    let revision = AnalysisRevision(transcriptRevision: query.transcriptRevision, promptRevision: "synthetic",
        analysis: Analysis(title: "Invented meeting", summary: "An invented summary."))
    let reconciled = SpeakerReconciliation.applying(revision, to: matched)
    #expect(reconciled.speakerAttributions?["s1"]?.method == "voice")
    #expect(matched.importedSummary == "An earlier summary.")
    var raw = [Float](repeating: 0, count: 256); raw[0] = 3; raw[1] = 4
    let normalized = try #require(VoiceSimilarity.normalized(raw))
    #expect(abs(normalized[0] - 0.6) < 0.0001 && abs(normalized[1] - 0.8) < 0.0001)
    #expect(VoiceSimilarity.normalized([Float](repeating: 0, count: 256)) == nil)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["JOTTIE_VOICE_RENDER_QA"] == "1"))
@MainActor func voiceNativeViewsRenderWithSyntheticEnrollment() async throws {
    let f = try await VoiceFixture.create()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let donor = try await f.recording("Enrollment recording"), query = try await f.recording("Independent test recording")
    let model = LibraryViewModel(store: f.store, coordinator: try KnowledgeCoordinator(store: f.store),
        account: MicrosoftAccount(), publisher: try GraphPublisher(tokens: MicrosoftAccount(), root: f.root))
    await model.reload(); await model.loadDirectoryPeople()
    try await f.assign(donor, employee: "alice")
    await model.reload()
    let matched = try #require(model.meetings.first { $0.id == query.id })
    #expect(matched.speakerAttributions?["s1"]?.employeeID == "alice")
    let output = URL(fileURLWithPath: "/tmp/jottie-voice-qa")
    try LibraryStore.directory(output)
    _ = NSApplication.shared
    func render<Content: View>(_ content: Content, name: String, height: CGFloat) throws {
        let host = NSHostingView(rootView: content.frame(width: 1050, height: height).padding(24).background(JottieStyle.background))
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1098, height: height + 48), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.contentView = host
        defer { panel.close() }
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(data.count > 10000)
        try data.write(to: output.appendingPathComponent(name + ".png"))
    }
    model.settingsTab = "Integrations"
    try render(LibrarySettingsView(model: model), name: "settings", height: 1600)
    try render(InlineSpeakers(model: model, meeting: matched), name: "matched-speaker", height: 850)
    var settings = try await f.store.settings(); settings.voiceAutoAssign = false; try await f.store.saveSettings(settings)
    await model.reload()
    let suggested = try #require(model.meetings.first { $0.id == query.id })
    #expect(suggested.voiceSuggestions?["s1"]?.employeeID == "alice")
    try render(InlineSpeakers(model: model, meeting: suggested), name: "suggested-speaker", height: 850)
}

private struct VoiceFixtureAnalyzer: MeetingAnalyzer {
    func analyze(_ meeting: Meeting, prompt: String, folders: [Folder]) async throws -> Analysis {
        Analysis(title: "Invented analysis", summary: "Invented microphone speech.",
            summaryEvidence: [Evidence(segmentID: meeting.segments[0].id, quote: meeting.segments[0].text)])
    }
}

@Test func voiceLearningDoesNotAdoptTheConfiguredOwnerDuringSummaryRegeneration() async throws {
    let f = try await VoiceFixture.create(); defer { try? FileManager.default.removeItem(at: f.root) }
    let mic = Meeting(sourceID: Codec.hash("mic"), title: "Invented microphone recording", segments: [
        Segment(id: "s1", speaker: "me", startMS: 0, endMS: 10000, text: "Invented microphone speech.")])
    try await f.store.save(mic)
    var settings = try await f.store.settings(); settings.analysisEnabled = true; try await f.store.saveSettings(settings)
    let coordinator = try KnowledgeCoordinator(store: f.store, analyzer: VoiceFixtureAnalyzer(), defaultSpeakerName: { "Configured Owner" })
    try await coordinator.regenerate(mic.id)
    #expect(try await f.store.meeting(mic.id).speakerNames["me"] == nil)
}

@Test func everyVoiceWindowMustBeatTheRunnerUpAndCoverTheAssignedPassage() async throws {
    let f = try await VoiceFixture.create(); defer { try? FileManager.default.removeItem(at: f.root) }
    let alice = try await f.recording("alice"), bob = try await f.recording("bob", vector: voiceVector(1))
    let query = try await f.recording("conflicting-query")
    try await f.assign(alice, employee: "alice"); try await f.assign(bob, employee: "bob")
    let settings = try await f.store.settings()
    let record = VoiceEvidence(sourceID: query.sourceID, company: "example", generation: settings.voiceLearningGeneration,
        modelID: "synthetic-model", originalSegments: query.segments, samples: [
            VoiceSample(id: "first", speaker: "them 1", startMS: 0, endMS: 10000, embedding: voiceVector()),
            VoiceSample(id: "second", speaker: "them 1", startMS: 10000, endMS: 20000, embedding: voiceVector(0.6))])
    try await f.store.saveVoiceEvidence(record); _ = try await f.store.refreshVoiceMatches()
    #expect(try await f.store.meeting(query.id).speakerAttributions == nil)
    var coarse = record
    coarse.originalSegments = [Segment(id: "long", speaker: "them 1", startMS: 0, endMS: 100000, text: "A long coarse passage.")]
    #expect(coarse.coveredPassageIDs(by: record.samples).isEmpty)
}

@Test func directoryRenameKeepsEnrollmentLinkedToTheStableEmployeeID() async throws {
    let f = try await VoiceFixture.create(); defer { try? FileManager.default.removeItem(at: f.root) }
    let donor = try await f.recording("donor"), query = try await f.recording("query")
    try await f.assign(donor, employee: "alice"); _ = try await f.store.refreshVoiceMatches()
    let before = try await f.store.meeting(query.id).speakerAttributions?["s1"]?.voiceMatch?.profileID
    try await PeopleDirectory(root: f.root).replace([DirectoryPerson(id: "alice", name: "Alex Example", jobTitle: "Designer")], company: "example")
    _ = try await f.store.refreshVoiceMatches()
    let after = try await f.store.meeting(query.id)
    #expect(after.speakerAttributions?["s1"]?.name == "Alex Example")
    #expect(after.speakerAttributions?["s1"]?.jobTitle == "Designer")
    #expect(after.speakerAttributions?["s1"]?.voiceMatch?.profileID == before)
}

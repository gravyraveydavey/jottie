import Foundation
import Testing
import JottieModels
import JottieLibrary
import JottieKnowledge
import JottieMCP

private func speakerFixture(shared: Bool = false) -> Meeting {
    var meeting = Meeting(sourceID: "voices", title: "Planning", segments: [
        Segment(id: "q", speaker: "me", text: "Dave, can you explain the launch plan?"),
        Segment(id: "a", speaker: shared ? "them" : "them 1", text: "Yes, the launch is next week."),
        Segment(id: "b", speaker: shared ? "them" : "them 2", text: "I'm Fi. I will check the copy.")
    ], participants: ["Dave Welch <dave@example.test>", "Fiona Gray <fi@example.test>"])
    meeting.participantContext = [
        ParticipantIdentity(invitee: meeting.participants[0], employeeID: "d", name: "David Welch", workEmail: "dave@example.test", jobTitle: "Product Director", company: "test", matchedBy: "email", syncedAt: Date()),
        ParticipantIdentity(invitee: meeting.participants[1], employeeID: "f", name: "Fiona Gray", workEmail: "fi@example.test", jobTitle: "Writer", company: "test", matchedBy: "email", syncedAt: Date())]
    return meeting
}
private func speakerAnalysis(_ meeting: Meeting, candidates: [SpeakerCandidate]) -> AnalysisRevision {
    var analysis = Analysis(title: "Launch", summary: "Launch is next week.", summaryEvidence: [Evidence(segmentID: "a", quote: "the launch is next week")])
    analysis.speakerCandidates = candidates
    return AnalysisRevision(transcriptRevision: meeting.transcriptRevision, promptRevision: "test", analysis: analysis)
}
private func addressedCandidate(label: String = "them 1", name: String = "Dave Welsh", confidence: Double = 0.95) -> SpeakerCandidate {
    SpeakerCandidate(label: label, name: name, evidence: [Evidence(segmentID: "q", quote: "Dave, can you explain"), Evidence(segmentID: "a", quote: "Yes, the launch")], segmentIDs: ["a"], confidence: confidence, basis: ["direct_address_response", "alias"])
}
@Test func aliasesResolveVariantsWithoutCollapsingAmbiguousPeople() {
    let people = [DirectoryPerson(id: "d", name: "David Welch"), DirectoryPerson(id: "f", name: "Fiona Gray"), DirectoryPerson(id: "j", name: "Jonathon Busby"), DirectoryPerson(id: "k", name: "Jonathan Barrett")]
    let matches = PeopleDirectory.match(["Dave Welsh", "Fi", "Busby", "Jon Barret", "Barret", "Jon"], people: people, company: "test", syncedAt: Date())
    #expect(matches.map(\.employeeID) == ["d", "f", "j", "k", "k"])
    #expect(matches.first?.aliases?.contains("Dave Welsh") == true)
    #expect(PeopleDirectory.match(["Dave Welch <other@example.test>"], people: people, company: "test", syncedAt: Date()).isEmpty)
}
@Test func directoryAliasesSurviveSyncAndIndexRebuildButNotCompanySwitch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try PeopleDirectory(root: root)
    let person = DirectoryPerson(id: "1", name: "Alex Smith")
    try await directory.replace([person], company: "test")
    try await directory.setAliases(["Lex", "Alex Smyth"], employeeID: "1", company: "test")
    try await directory.replace([person], company: "test")
    try await LibraryStore(root: root).rebuildIndex()
    #expect(try await PeopleDirectory(root: root).matching(["Lex"], company: "test").first?.employeeID == "1")
    try await directory.replace([person], company: "different")
    #expect(try await directory.matching(["Lex"], company: "different").isEmpty)
}
@Test func evidenceBackedAssignmentUpdatesOfficialProjectionWithoutRewritingSpeech() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root)
    let original = speakerFixture()
    try await store.save(original)
    let revision = speakerAnalysis(original, candidates: [addressedCandidate()])
    try await store.apply(revision, to: original.id)
    let value = try await store.meeting(original.id)
    #expect(value.speakerAttributions?["a"]?.name == "David Welch")
    #expect(value.speakerAttributions?["a"]?.jobTitle == "Product Director")
    #expect(value.speakerAttributions?["a"]?.analysisRevision == revision.id)
    #expect(value.segments == original.segments && value.transcriptRevision == original.transcriptRevision)
    #expect(value.transcript.contains("David Welch: Yes"))
    #expect(value.reconciledSpeakers.contains { $0.name == "David Welch" && $0.sources.contains("Meeting invite") && $0.sources.contains("Name mentioned") })
    #expect(try String(contentsOf: store.meetingDirectory(value.id).appendingPathComponent("transcript.md"), encoding: .utf8).contains("David Welch: Yes"))
    try await store.rebuildIndex()
    var query = SearchQuery(); query.text = "David Welch"
    #expect(try await store.search(query).count == 1)
}
@Test func weakConflictingAndInvalidSpeakerEvidenceNeverAutoAssigns() throws {
    let meeting = speakerFixture()
    for candidate in [addressedCandidate(confidence: 0.7), SpeakerCandidate(label: "them 1", name: "David Welch", evidence: [Evidence(segmentID: "a", quote: "launch")], segmentIDs: ["a"], confidence: 0.99, basis: ["role_context", "elimination"])] {
        #expect(SpeakerReconciliation.applying(speakerAnalysis(meeting, candidates: [candidate]), to: meeting).speakerAttributions == nil)
    }
    var conflict = addressedCandidate(name: "Fiona Gray"); conflict.basis = ["self_introduction"]
    #expect(SpeakerReconciliation.applying(speakerAnalysis(meeting, candidates: [conflict]), to: meeting).speakerAttributions == nil)
    var invalid = addressedCandidate(); invalid.segmentIDs = ["b"]
    #expect(throws: JottieError.self) { try speakerAnalysis(meeting, candidates: [invalid]).analysis.validate(segments: meeting.segments) }
}
@Test func sharedChannelAssignmentsStayScopedAndManualCorrectionsSurviveRegeneration() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root)
    let original = speakerFixture(shared: true)
    try await store.save(original)
    let fi = SpeakerCandidate(label: "them", name: "Fi", evidence: [Evidence(segmentID: "b", quote: "I'm Fi")], segmentIDs: ["b"], confidence: 0.96, basis: ["self_introduction", "alias"])
    try await store.apply(speakerAnalysis(original, candidates: [fi]), to: original.id)
    var value = try await store.meeting(original.id)
    #expect(value.speakerAttributions?["b"]?.name == "Fiona Gray")
    #expect(value.speakerAttributions?["a"] == nil)
    try await store.setSpeakerAssignment(segmentIDs: ["b"], name: "Manual Person", role: "Reviewer", employeeID: nil, meetingID: original.id)
    try await store.apply(speakerAnalysis(original, candidates: [fi]), to: original.id)
    value = try await store.meeting(original.id)
    #expect(value.speakerAttributions?["b"]?.method == "manual")
    #expect(value.speakerName(for: value.segments[2]) == "Manual Person")
    try await store.setSpeakerAssignment(segmentIDs: ["b"], name: "", role: nil, employeeID: nil, meetingID: original.id)
    try await store.apply(speakerAnalysis(original, candidates: [fi]), to: original.id)
    value = try await store.meeting(original.id)
    #expect(value.speakerName(for: value.segments[2]).hasPrefix("Speaker "))
    #expect(value.speakerNames.isEmpty)
    #expect(try await LibraryStore(root: root).meeting(original.id).speakerAttributions == value.speakerAttributions)
}

@Test func selfIntroductionRequiresIntroductionNotJustMentionAndSharedAliasesStayUnresolved() {
    var meeting = speakerFixture()
    meeting.segments[1].text = "Fiona asked about the launch."
    let mentioned = SpeakerCandidate(label: "them 1", name: "Fiona Gray", evidence: [Evidence(segmentID: "a", quote: "Fiona asked")], segmentIDs: ["a"], confidence: 0.99, basis: ["self_introduction"])
    #expect(SpeakerReconciliation.applying(speakerAnalysis(meeting, candidates: [mentioned]), to: meeting).speakerAttributions == nil)
    meeting = speakerFixture()
    meeting.participantContext?.append(ParticipantIdentity(invitee: "Other Dave", employeeID: "d2", name: "David Jones", workEmail: nil, jobTitle: "Engineer", company: "test", matchedBy: "unique-name", syncedAt: Date()))
    #expect(SpeakerReconciliation.applying(speakerAnalysis(meeting, candidates: [addressedCandidate()]), to: meeting).speakerAttributions == nil)
}
@Test func consistentSeparatedVoiceCanPropagateButNeverSharedChannel() {
    for label in ["them 1", "speaker 1", "me 1", "them", "me unknown"] {
        var meeting = speakerFixture()
        for index in meeting.segments.indices where meeting.segments[index].speaker == "them 1" { meeting.segments[index].speaker = label }
        meeting.segments.append(Segment(id: "c", speaker: label, text: "I will send the plan."))
        var candidate = addressedCandidate(label: label)
        candidate.segmentIDs = ["a", "c"]; candidate.basis?.append("voice_consistency")
        let value = SpeakerReconciliation.applying(speakerAnalysis(meeting, candidates: [candidate]), to: meeting)
        #expect(value.speakerAttributions?["a"]?.name == "David Welch")
        #expect((value.speakerAttributions?["c"] != nil) == ["them 1", "speaker 1", "me 1"].contains(label))
    }
}

private actor SpeakerPromptRunner: StructuredRunner {
    var prompt = ""
    let output: Analysis
    init(output: Analysis) { self.output = output }
    func run(prompt: String, schema: Data) throws -> Data {
        self.prompt = prompt
        return try Codec.encode(output)
    }
}
@Test func reconciliationPromptCarriesAliasesManualPassagesAndReasoningRules() async throws {
    var meeting = speakerFixture()
    meeting.participantContext?[0].aliases = ["Dave Welsh"]
    meeting.speakerAttributions = ["b": SpeakerAttribution(name: "Fiona Gray", method: "manual")]
    let runner = SpeakerPromptRunner(output: speakerAnalysis(meeting, candidates: []).analysis)
    _ = try await CodexAnalyzer(runner: runner).analyze(meeting, prompt: "Summarise", folders: [])
    let prompt = await runner.prompt
    #expect(prompt.contains("Dave Welsh") && prompt.contains("direct_address_response") && prompt.contains("elimination"))
    #expect(prompt.contains("Manual passage assignments") && prompt.contains("Fiona Gray"))
    #expect(prompt.contains("Job title/topic alignment is weak"))
}

@Test func configuredMicrophoneIdentityWorksWithoutSummaryAnalysis() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("capture")
    try LibraryStore.directory(source)
    try Data(#"{"segments":[{"speaker":"me","start_ms":0,"end_ms":1000,"text":"Hello."}]}"#.utf8).write(to: source.appendingPathComponent("transcript.json"))
    try Data(#"{"started":"2026-10-28T09:00:00Z"}"#.utf8).write(to: source.appendingPathComponent("meta.json"))
    let store = try LibraryStore(root: root.appendingPathComponent("library"))
    let value = try await store.importAmanu(source, defaultSpeakerName: "Preferred Name")
    #expect(value.speakerNames["me"] == "Preferred Name" && value.analysis == nil)
    try await store.setSpeaker("me", name: "Manual Name", meetingID: value.id)
    #expect(try await store.importAmanu(source, defaultSpeakerName: "Changed Default").speakerNames["me"] == "Manual Name")
}

@Test func mcpReturnsOnlyPageAttributionsAndTracksSpeakerCorrections() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root)
    let meeting = speakerFixture()
    try await store.save(meeting)
    try await store.setSpeakerAssignment(segmentIDs: ["q", "b"], name: "Corrected Person", role: "Designer", employeeID: nil, meetingID: meeting.id)
    let before = try Data(contentsOf: store.meetingDirectory(meeting.id).appendingPathComponent("meeting.json"))
    let server = try JottieServer(root: root)
    let response = try await server.call(name: "get_transcript", arguments: ["meetingID": .string(meeting.id.uuidString), "limit": .int(1)])
    let value = try #require(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
    #expect((value["speakerAttributions"] as? [String: Any])?.keys.sorted() == ["q"])
    #expect((value["displayNames"] as? [String: String])?["q"] == "Corrected Person")
    #expect(value["speakerRevision"] as? String == (try await store.meeting(meeting.id)).speakerRevision)
    #expect(try Data(contentsOf: store.meetingDirectory(meeting.id).appendingPathComponent("meeting.json")) == before)
}

@Test func ambiguousManualNicknameDoesNotHideMultipleUndetectedInvitees() {
    var meeting = speakerFixture()
    meeting.participants = ["Jonathon Busby", "Jonathan Barrett"]
    meeting.participantContext = nil
    meeting.speakerNames["them 1"] = "Jon"
    #expect(meeting.undetectedInvitees.map(\.name) == meeting.participants)
    meeting.speakerNames["them 1"] = "Busby"
    #expect(meeting.undetectedInvitees.map(\.name) == ["Jonathan Barrett"])
}
@Test func staleManualCorrectionIsRejectedWithoutChangingTranscript() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root), meeting = speakerFixture()
    try await store.save(meeting)
    await #expect(throws: JottieError.self) {
        try await store.setSpeakerAssignment(segmentIDs: ["a"], name: "Person", role: nil, employeeID: nil, meetingID: meeting.id, expectedRevision: "outdated")
    }
    #expect(try await store.meeting(meeting.id).speakerAttributions == nil)
}

@Test func namedSourceLabelsSurviveAndCanonicalAliasesMergeVoiceFragments() {
    let imported = Meeting(sourceID: "named", title: "Imported", segments: [Segment(id: "s", speaker: "Jamie Chen", text: "Hello")])
    #expect(imported.speakerName(for: imported.segments[0]) == "Jamie Chen")
    #expect(imported.reconciledSpeakers.first?.sources.contains("Transcript label") == true)
    var meeting = speakerFixture()
    meeting.speakerNames["me"] = "Dave"
    meeting.speakerRoles = ["me": " "]
    meeting = SpeakerReconciliation.applying(speakerAnalysis(meeting, candidates: [addressedCandidate()]), to: meeting)
    let rows = meeting.reconciledSpeakers.filter { $0.employeeID == "d" }
    #expect(rows.count == 1 && rows[0].segmentIDs == ["q", "a"])
    #expect(rows.first?.jobTitle == "Product Director")
    #expect(rows.first?.sources.contains("User assignment") == true && rows.first?.sources.contains("AI inference") == true)
    #expect(meeting.undetectedInvitees.map(\.name) == ["Fiona Gray"])
}

@Test func longUnresolvedMeetingReconcilesWithoutRepeatedDirectoryWork() throws {
    var meeting = speakerFixture()
    meeting.segments = (0..<1200).map { Segment(id: "long-\($0)", speaker: $0.isMultiple(of: 2) ? "me" : "them", text: "We discussed the plan and agreed to review the next milestone.") }
    meeting.participantContext = (0..<8).map { ParticipantIdentity(invitee: "Invited Person \($0)", employeeID: "\($0)", name: "Invited Person \($0)", workEmail: nil, jobTitle: "Designer", company: "test", matchedBy: "unique-name", syncedAt: Date()) }
    meeting.participants = (meeting.participantContext ?? []).map(\.invitee)
    let clock = ContinuousClock(), start = clock.now
    let rows = meeting.reconciledSpeakers
    let undetected = meeting.undetectedInvitees
    let display = meeting.displaySpeakerNames
    let elapsed = start.duration(to: clock.now)
    #expect(undetected.count == 8 && display.count == 1200)
    #expect(rows.count == 2 && rows.allSatisfy { $0.segmentIDs.count == 600 })
    #expect(elapsed < .seconds(2), "Long-meeting presentation must not repeatedly generate aliases per passage: \(elapsed)")
}

import Foundation
import Testing
import JottieModels
import JottieLibrary
@testable import JottieUI

@Test func summaryMarkdownPreservesNestedListsAndInlineFormatting() {
    let blocks = SummaryMarkdownBlock.parse("""
    Intro paragraph.

    - **Parent**
      - Child with *emphasis*
        - Grandchild
      - Another child
    - Next parent

    3. Third
       1. Nested number
    4. Fourth
    """)
    #expect(blocks.map(\.depth) == [0, 1, 2, 3, 2, 1, 1, 2, 1])
    #expect(blocks.map { String($0.text.characters) } == ["Intro paragraph.", "Parent", "Child with emphasis", "Grandchild", "Another child", "Next parent", "Third", "Nested number", "Fourth"])
    #expect(blocks[1].text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    #expect(blocks[2].text.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
    #expect(blocks[6].marker == "3." && blocks[7].marker == "1." && blocks[8].marker == "4.")
}

@Test func summaryMarkdownKeepsContinuationParagraphsUnderTheirListItem() {
    let blocks = SummaryMarkdownBlock.parse("""
    - First paragraph.

      Continued paragraph with a [link](https://example.test).

      - Child
    """)
    #expect(blocks.count == 3)
    #expect(blocks.map(\.depth) == [1, 1, 2])
    #expect(blocks[0].marker != nil && blocks[1].marker == nil && blocks[2].marker != nil)
    #expect(blocks[1].text.runs.contains { $0.link == URL(string: "https://example.test") })
}

@Test func folderTreeKeepsAncestorBranchesThroughNestedRowsAndStopsAtLastSiblings() {
    let root = Folder(name: "Project")
    let branch = Folder(name: "A workstream", parentID: root.id)
    let sibling = Folder(name: "B shared", parentID: root.id)
    let first = Folder(name: "One", parentID: branch.id), last = Folder(name: "Two", parentID: branch.id)
    let folders = [last, sibling, root, first, branch]
    let rows = SidebarFolderEntry.visible(folders, collapsed: [])
    #expect(rows.map(\.id) == [root.id, branch.id, first.id, last.id, sibling.id])
    #expect(rows.map(\.depth) == [0, 1, 2, 2, 1])
    #expect(rows[0].expanded && rows[1].expanded)
    #expect(rows[2].ancestorContinues == [true] && rows[3].ancestorContinues == [true])
    #expect(!rows[2].isLastSibling && rows[3].isLastSibling && rows[4].isLastSibling)
    let collapsed = SidebarFolderEntry.visible(folders, collapsed: [branch.id])
    #expect(collapsed.map(\.id) == [root.id, branch.id, sibling.id])
    #expect(!collapsed[1].expanded)
}

private func identityNoticeFixture() -> Meeting {
    var meeting = Meeting(sourceID: "synthetic-identity-notice", title: "Planning", segments: [Segment(id: "s1", speaker: "them 1", text: "The launch is ready.")])
    meeting.analysis = AnalysisRevision(transcriptRevision: meeting.transcriptRevision, promptRevision: "test",
        analysis: Analysis(title: "Planning", summary: "The launch is ready.", summaryEvidence: [Evidence(segmentID: "s1", quote: "The launch is ready.")]))
    return meeting
}

@Test func changedSpeakerOrCalendarDetailsNudgeOnlyUntilSummaryUsesThoseInputs() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root), meeting = identityNoticeFixture()
    try await store.save(meeting)
    #expect(try await store.meeting(meeting.id).summaryNeedsIdentityRefresh == false)
    try await store.assignTranscriptSpeaker(meetingID: meeting.id, label: "them 1", assignment: SpeakerAttribution(name: "Alex Example", method: "manual"))
    var saved = try await store.meeting(meeting.id)
    #expect(saved.summaryNeedsIdentityRefresh)
    let currentRevision = saved.analysis!
    try await store.apply(currentRevision, to: meeting.id)
    saved = try await store.meeting(meeting.id)
    #expect(!saved.summaryNeedsIdentityRefresh)
    let previousIdentity = saved.summaryIdentityRevision
    let event = CalendarEventContext(id: "event", calendarID: "calendar", calendarTitle: "Synthetic", title: "Planning",
        start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 60), invitees: ["Alex Example"])
    try await store.setCalendarContext(event, meetingID: meeting.id)
    #expect(try await store.meeting(meeting.id).summaryNeedsIdentityRefresh)
    // An analysis started before the calendar edit must not dismiss the notice.
    try await store.apply(currentRevision, to: meeting.id, identityRevision: previousIdentity)
    #expect(try await store.meeting(meeting.id).summaryNeedsIdentityRefresh)
    try await store.apply(currentRevision, to: meeting.id)
    #expect(try await LibraryStore(root: root).meeting(meeting.id).summaryNeedsIdentityRefresh == false)
}

@Test func directoryRefreshTimestampsDoNotTriggerSummaryNudges() {
    var meeting = identityNoticeFixture()
    var person = ParticipantIdentity(invitee: "Alex", employeeID: "a", name: "Alex Example", workEmail: nil, jobTitle: "Writer",
        company: "synthetic", matchedBy: "unique-name", syncedAt: Date(timeIntervalSince1970: 0))
    meeting.participantContext = [person]
    let revision = meeting.summaryIdentityRevision
    person.syncedAt = Date(timeIntervalSince1970: 1000); person.matchedBy = "unique-alias"
    meeting.participantContext = [person]
    #expect(meeting.summaryIdentityRevision == revision)
    person.jobTitle = "Director"; meeting.participantContext = [person]
    #expect(meeting.summaryIdentityRevision != revision)
}

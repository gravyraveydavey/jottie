import SwiftUI
import AppKit
import JottieModels
import JottieLibrary

@MainActor struct MeetingDetailPane: View {
    @ObservedObject var model: LibraryViewModel
    let meeting: Meeting
    @ViewState private var tab = "Summary"
    @ViewState private var copied = false
    @ViewState private var targetSegment: String?
    @ViewState private var showOriginalTranscript = false
    @ViewState private var transcriptTab = "Original transcript"
    @ViewState private var cleanupSelection = Set<String>()
    @ViewState private var cleanupSpeakers = Set<String>()
    private var folderName: String { model.folders.first { $0.id == meeting.folderID }?.name ?? "Import" }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { model.navigate(meeting.folderID?.uuidString ?? "inbox") } label: { Label(folderName, systemImage: "folder") }
                    .buttonStyle(.plain).foregroundStyle(JottieStyle.muted).help("Open this folder's context")
                Spacer()
                Button { Task { await model.toggleStar(meeting) } } label: {
                    Image(systemName: meeting.starred == true ? "star.fill" : "star")
                        .foregroundStyle(meeting.starred == true ? JottieStyle.accent : JottieStyle.foreground)
                }.buttonStyle(JottieButtonStyle(compact: true)).help(meeting.starred == true ? "Unstar meeting" : "Star meeting")
                    .accessibilityLabel(meeting.starred == true ? "Unstar meeting" : "Star meeting")
                Button { copy() } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "square.on.square") }
                    .buttonStyle(JottieButtonStyle(compact: true)).help("Copy the current tab's content")
                Menu {
                    Button("Export Markdown…") { model.export() }
                    Button("Regenerate analysis") { Task { await model.regenerate(meeting) } }
                    Button("Move to Trash", role: .destructive) { model.trashSelection() }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().help("Export, regenerate or move to Trash")
            }.font(JottieStyle.font(12)).padding(.horizontal, 20).frame(height: 48)
            JottieRule()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        documentHeader
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 14) {
                                ForEach([("Summary", "sparkles"), ("Transcript", "doc.text"), ("Speakers", "person.2")], id: \.0) { name, icon in
                                    DocumentTab(title: name, icon: icon, selected: tab == name, processing: name == "Transcript" && model.isCleaning(meeting)) { tab = name; copied = false }
                                }
                                Spacer(minLength: 0)
                            }
                            JottieRule()
                        }
                        if tab == "Summary" { summary }
                        else if tab == "Transcript" {
                            HStack(spacing: 18) {
                                ForEach(["Original transcript", "Cleanup suggestions"], id: \.self) { name in
                                    DocumentTab(title: name, icon: name == "Cleanup suggestions" ? "wand.and.stars" : "doc.text", selected: transcriptTab == name, processing: name == "Cleanup suggestions" && model.isCleaning(meeting)) { transcriptTab = name }
                                }
                                Spacer()
                            }
                            if transcriptTab == "Cleanup suggestions" {
                                CleanupSuggestionsPane(model: model, meeting: meeting, selectedChanges: $cleanupSelection, selectedSpeakers: $cleanupSpeakers) { transcriptTab = "Original transcript" }
                            } else { transcript }
                        } else { InlineSpeakers(model: model, meeting: meeting) }
                    }.padding(.horizontal, tab == "Transcript" ? 24 : 48).padding(.vertical, 44)
                        .frame(maxWidth: tab == "Transcript" ? .infinity : 768, alignment: .leading).frame(maxWidth: .infinity)
                }
                .onChange(of: targetSegment) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } } }
            }
        }.background(JottieStyle.background).accessibilityElement(children: .contain).accessibilityLabel("Meeting detail")
            .onChange(of: model.cleanupReviewMeeting?.cleanupDraft?.id) { _, _ in
                if model.cleanupReviewMeeting?.id == meeting.id { tab = "Transcript"; transcriptTab = "Cleanup suggestions" }
            }
            .onChange(of: meeting.id) { _, _ in showOriginalTranscript = false; transcriptTab = "Original transcript" }
            .onChange(of: meeting.transcriptRevision) { _, _ in showOriginalTranscript = false }
    }
    private var documentHeader: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("MEETING NOTES", systemImage: "doc.text").font(JottieStyle.font(11, .medium)).tracking(1.1).foregroundStyle(JottieStyle.muted)
            Text(meeting.displayTitle).font(JottieStyle.font(30, .semibold)).tracking(-0.7).lineSpacing(2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { dateLabel; timeLabel; speakersLabel }
                VStack(alignment: .leading, spacing: 8) { dateLabel; HStack(spacing: 16) { timeLabel; speakersLabel } }
            }.font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted)
            FlowLayout(spacing: 6) { ForEach(meeting.analysis?.analysis.tags ?? [], id: \.self) { JottieBadge(text: $0) } }
        }
    }
    private var dateLabel: some View { Label(meeting.startedAt.formatted(.dateTime.day().month(.abbreviated).year()), systemImage: "calendar") }
    private var timeLabel: some View { Label(meeting.startedAt.formatted(.dateTime.hour().minute()) + (meeting.durationLabel.map { " · " + $0 } ?? ""), systemImage: "clock") }
    private var speakersLabel: some View { Label("\(meeting.reconciledSpeakers.count) speaker entries", systemImage: "person.2") }
    private var summary: some View {
        VStack(alignment: .leading, spacing: 32) {
            HStack {
                Text(summaryStatus).font(JottieStyle.font(11)).foregroundStyle(JottieStyle.muted)
                Spacer()
                Button { Task { await model.regenerate(meeting) } } label: { Label("Regenerate summary", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(JottieButtonStyle(kind: .outline, compact: true)).disabled(model.working)
                    .help("Create a new summary revision using your saved prompt and Codex settings")
            }
            if let analysis = meeting.analysis?.analysis {
                JottieSection(title: "At a glance") { prose(analysis.summary) }
                if !analysis.topics.isEmpty { JottieSection(title: "Key takeaways") { bullets(analysis.topics) } }
                JottieRule()
                findings("Decisions", icon: "checkmark", items: analysis.decisions)
                findings("Next steps", icon: "checklist", items: analysis.actions)
                findings("Open questions", icon: "questionmark.bubble", items: analysis.questions)
                if !analysis.uncertainties.isEmpty { JottieSection(title: "Uncertainties") { bullets(analysis.uncertainties) } }
                if let reason = meeting.filingReason { prose(reason).font(JottieStyle.font(12)) }
            } else if let imported = meeting.importedSummary {
                JottieSection(title: "Imported summary") { prose(imported) }
                Text("Regenerate to create evidence-backed analysis using Jottie's current prompt.").font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted)
            } else {
                JottieEmpty(title: "Ready for a summary", message: "Enable Codex analysis in Settings, then generate a summary to see the key points, decisions and next steps.", icon: "sparkles")
            }
        }
    }
    private var summaryStatus: String {
        if model.working { return "Processing · previous summary remains available" }
        guard let revision = meeting.analysis else { return "No generated summary yet" }
        let basis = meeting.cleanupOriginalSegments == nil ? "Original transcript" : "Cleaned transcript"
        return revision.promptRevision == model.savedSettings.analysisRevision ? "Summary up to date · \(basis)" : "Earlier prompt · update available"
    }
    private func findings(_ title: String, icon: String, items: [Finding]) -> some View {
        JottieSection(title: title, icon: icon, count: title == "Next steps" ? items.count : nil) {
            if items.isEmpty { prose("No \(title.lowercased()) recorded in this conversation.") }
            ForEach(items) { finding in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: title == "Next steps" ? (finding.status == "completed" ? "checkmark.circle.fill" : "circle") : "circle.fill")
                            .font(.system(size: title == "Next steps" ? 15 : 5)).foregroundStyle(JottieStyle.accent.opacity(0.6)).padding(.top, title == "Next steps" ? 3 : 9)
                            .help(title == "Next steps" ? "Status from meeting evidence: \(finding.status). This is not a task-completion control." : finding.status)
                        prose(finding.text).frame(maxWidth: .infinity, alignment: .leading)
                        if let owner = finding.owner { Text(owner).font(JottieStyle.font(11)).foregroundStyle(JottieStyle.muted).padding(.top, 3) }
                    }
                    HStack(spacing: 8) {
                        Text(([finding.status.replacingOccurrences(of: "_", with: " "), finding.dueDate].compactMap { $0 }).joined(separator: " · "))
                            .font(JottieStyle.font(10)).foregroundStyle(JottieStyle.muted)
                        EvidenceLinks(evidence: finding.evidence) { id in tab = "Transcript"; targetSegment = nil; Task { @MainActor in targetSegment = id } }
                    }.padding(.leading, 24)
                }
            }
        }
    }
    private var transcript: some View {
        LazyVStack(alignment: .leading, spacing: 30) {
            TranscriptCleanupTools(model: model, meeting: meeting, showOriginal: $showOriginalTranscript) { transcriptTab = "Cleanup suggestions" }
            let displayed = transcriptMeeting
            Label(displayed.reconciledSpeakers.map(\.name).joined(separator: ", "), systemImage: "person.2")
                .font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted)
            let displayNames = displayed.displaySpeakerNames
            ForEach(displayed.segments) { segment in
                HStack(alignment: .top, spacing: 18) {
                    Text(String(format: "%02d:%02d", segment.startMS / 60000, segment.startMS / 1000 % 60))
                        .font(JottieStyle.mono()).foregroundStyle(JottieStyle.muted).padding(.top, 1).frame(width: 38, alignment: .leading)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(displayNames[segment.id] ?? "Unknown speaker").font(JottieStyle.font(12, .semibold))
                        prose(segment.text)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(8).background(targetSegment == segment.id ? JottieStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 8)).id(segment.id)
            }
            JottieRule()
            Text("End of transcript · \(displayed.segments.count) segments").font(JottieStyle.font(11)).foregroundStyle(JottieStyle.muted)
        }
    }
    private var transcriptMeeting: Meeting {
        var value = meeting
        if showOriginalTranscript { value.segments = meeting.originalTranscript }
        return value
    }
    private func prose(_ text: String) -> some View {
        Text(text).font(JottieStyle.font(14)).foregroundStyle(JottieStyle.muted).lineSpacing(9).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
    private func bullets(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, text in
                HStack(alignment: .top, spacing: 12) { Circle().fill(JottieStyle.accent.opacity(0.5)).frame(width: 4, height: 4).padding(.top, 9); prose(text) }
            }
        }
    }
    private func copy() {
        let text: String
        if tab == "Transcript", transcriptTab == "Cleanup suggestions", let draft = meeting.cleanupDraft,
           let proposed = try? draft.result.projectedSegments(against: meeting, selecting: cleanupSelection) {
            var value = meeting; value.segments = proposed; text = value.transcript
        } else if tab == "Transcript" { text = transcriptMeeting.transcript }
        else if tab == "Speakers" { text = meeting.reconciledSpeakers.map { "\($0.name) — \($0.jobTitle ?? "")" }.joined(separator: "\n") }
        else { text = meeting.markdown.components(separatedBy: "\n## Transcript\n").first ?? meeting.markdown }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); copied = true
    }
}

struct DocumentTab: View {
    let title: String
    let icon: String
    let selected: Bool
    var processing = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                HStack(spacing: 7) {
                    if processing { ProgressView().controlSize(.mini).accessibilityHidden(true) }
                    Label(title, systemImage: icon)
                }.font(JottieStyle.font(14, selected ? .medium : .regular)).padding(.horizontal, 3)
                Rectangle().fill(selected ? JottieStyle.foreground : .clear).frame(height: 2)
            }.foregroundStyle(selected ? JottieStyle.foreground : JottieStyle.muted).contentShape(Rectangle())
        }.buttonStyle(.plain).fixedSize(horizontal: true, vertical: false).help("Show \(title.lowercased())").accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityLabel(title).accessibilityValue(processing ? "Transcript cleanup in progress" : "")
    }
}

private struct EvidenceLinks: View {
    let evidence: [Evidence]
    let open: (String) -> Void
    @ViewState private var expanded = false
    var body: some View {
        Button { expanded.toggle() } label: { Label("Sources", systemImage: "link") }.buttonStyle(.plain).font(JottieStyle.font(10)).foregroundStyle(JottieStyle.accent)
            .popover(isPresented: $expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Transcript evidence").font(JottieStyle.font(13, .semibold))
                    ForEach(Array(evidence.enumerated()), id: \.offset) { _, source in
                        Button { expanded = false; open(source.segmentID) } label: {
                            VStack(alignment: .leading, spacing: 4) { Text("“\(source.quote)”").lineSpacing(4); Text(source.segmentID).font(JottieStyle.mono(10)).foregroundStyle(JottieStyle.accent) }
                        }.buttonStyle(.plain)
                    }
                }.font(JottieStyle.font(12)).padding(18).frame(width: 330)
            }
    }
}


struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? 600).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let positions = arrange(subviews, width: bounds.width).positions
        for (index, position) in positions.enumerated() { subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified) }
    }
    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, positions: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        var positions: [CGPoint] = []
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            positions.append(CGPoint(x: x, y: y)); x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), positions)
    }
}

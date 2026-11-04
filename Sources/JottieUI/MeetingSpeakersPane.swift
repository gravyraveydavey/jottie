import SwiftUI
import JottieModels
import JottieLibrary

@MainActor struct InlineSpeakers: View {
    @ObservedObject var model: LibraryViewModel
    let meeting: Meeting
    @ViewState private var choosingCalendar = false
    @ViewState private var correcting: ReconciledSpeaker?
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if model.savedSettings.voiceLearningEnabled {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.voiceStatus)
                        Text(model.voiceEvidenceCounts[meeting.id].map { "\($0) usable voice windows saved for this recording" } ?? "No saved voice evidence for this recording")
                    }.font(JottieStyle.font(11)).foregroundStyle(JottieStyle.muted)
                    Spacer()
                    Button("Re-evaluate voices") { Task { await model.reevaluateVoices() } }.disabled(model.updatingVoices)
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                ForEach(meeting.reconciledSpeakers) { row in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(row.name).font(JottieStyle.font(15, .semibold))
                                if let role = row.jobTitle, !role.isEmpty { Text(role).font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted) }
                                Text("\(row.segmentIDs.count) passages" + (row.inferred ? " · Likely identity" : ""))
                                    .font(JottieStyle.font(11)).foregroundStyle(JottieStyle.muted)
                            }
                            Spacer()
                            Button("Correct assignment") { correcting = row }
                                .buttonStyle(JottieButtonStyle(kind: .outline, compact: true))
                        }
                        FlowLayout { ForEach(row.sources, id: \.self) { JottieBadge(text: $0) } }
                        if let suggestion = row.segmentIDs.compactMap({ meeting.voiceSuggestions?[$0] }).first,
                           let match = suggestion.voiceMatch {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Voice suggestion: \(suggestion.name)").font(JottieStyle.font(12, .medium))
                                Text("Similarity \(String(format: "%.2f", match.similarity)) · \(match.sampleCount) independent windows · review with Correct assignment")
                                    .font(JottieStyle.font(11)).foregroundStyle(JottieStyle.muted)
                            }
                        }
                        if let match = row.segmentIDs.compactMap({ meeting.speakerAttributions?[$0]?.voiceMatch }).first {
                            Text("Local voice match · similarity \(String(format: "%.2f", match.similarity)) · \(match.sampleCount) independent windows")
                                .font(JottieStyle.font(11)).foregroundStyle(JottieStyle.muted)
                        }
                        if !row.evidence.isEmpty {
                            DisclosureGroup("Attribution evidence") {
                                ForEach(Array(row.evidence.enumerated()), id: \.offset) { _, item in
                                    Text("\(item.segmentID): “\(item.quote)”").font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted).textSelection(.enabled)
                                }
                            }.font(JottieStyle.font(12))
                        }
                    }.padding(16).overlay { RoundedRectangle(cornerRadius: 12).stroke(JottieStyle.border, lineWidth: 1) }
                }

            }
            if !meeting.undetectedInvitees.isEmpty {
                JottieSection(title: "Invited but not detected", icon: "person.crop.circle.badge.questionmark") {
                    ForEach(meeting.undetectedInvitees) { person in
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(person.name).font(JottieStyle.font(13, .medium))
                                if let role = person.role { Text(role).font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted) }
                            }
                            Spacer()
                            JottieBadge(text: person.mentioned ? "Name mentioned · Voice unidentified" : "Meeting invite")
                        }.padding(.vertical, 5)
                    }
                    Text("No confidently assigned voice was found. People may have attended silently; a name mentioned in conversation may also refer to someone absent.")
                        .font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted)
                }
            }
            JottieRule()
            JottieSection(title: "Meeting sources", icon: "calendar") {
                Text(meeting.calendarContext.map { "\($0.title) · \($0.calendarTitle)" } ?? "No meeting invitation attached.")
                    .font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted)
                HStack {
                    Button("Find / change calendar event") { choosingCalendar = true }
                    Button("Refresh directory matches") { Task { await model.refreshPeople(for: meeting) } }.disabled(meeting.directoryIdentityCandidates.isEmpty)
                }.buttonStyle(JottieButtonStyle(kind: .outline, compact: true))
                if meeting.summaryNeedsIdentityRefresh {
                    HStack(spacing: 6) {
                        Text("Speaker or meeting details changed.").foregroundStyle(JottieStyle.muted)
                        Button("Regenerate summary") { Task { await model.regenerate(meeting) } }
                            .buttonStyle(.plain).foregroundStyle(JottieStyle.accent)
                            .disabled(model.working || model.isSummarizing(meeting))
                    }.font(JottieStyle.font(11))
                }
            }
        }.task { await model.loadDirectoryPeople() }
            .sheet(isPresented: $choosingCalendar) { MeetingCalendarPicker(model: model, meeting: meeting) }
            .sheet(item: $correcting) { SpeakerAssignmentEditor(model: model, meeting: meeting, row: $0) }
    }
}

@MainActor struct SpeakerAssignmentEditor: View {
    @ObservedObject var model: LibraryViewModel
    let meeting: Meeting
    let row: ReconciledSpeaker
    var initialSegmentID: String? = nil
    var saveDraft: (([String], SpeakerAttribution) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name = ""
    @ViewState private var role = ""
    @ViewState private var employeeID: String?
    @ViewState private var selected = Set<String>()
    @ViewState private var choosePassages = false
    @ViewState private var saving = false
    @ViewState private var error: String?
    @ViewState private var selectedName: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Correct speaker assignment").font(JottieStyle.font(22, .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Apply to this row's passages, or select individual passages. Leave the name blank to mark them unknown. This correction overrides future AI analysis.")
                        .font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted).fixedSize(horizontal: false, vertical: true)
                    TextField("Type a name, alias or email to search BambooHR", text: $name).textFieldStyle(JottieInputStyle())
                        .accessibilityLabel("Speaker name and BambooHR search")
                        .onChange(of: name) { _, value in
                            if let selectedName, selectedName != value { employeeID = nil; self.selectedName = nil; role = "" }
                        }
                    speakerChoices
                    TextField("Job title", text: $role).textFieldStyle(JottieInputStyle())
                    Toggle("Choose individual passages (\(selected.count) selected)", isOn: $choosePassages).toggleStyle(.checkbox)
                    if choosePassages {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                ForEach(meeting.segments.filter { row.segmentIDs.contains($0.id) }) { segment in
                                    Toggle(isOn: Binding(get: { selected.contains(segment.id) }, set: { if $0 { selected.insert(segment.id) } else { selected.remove(segment.id) } })) {
                                        Text("\(segment.startMS / 60000):\(String(format: "%02d", segment.startMS / 1000 % 60)) · \(segment.text)")
                                            .font(JottieStyle.font(12)).lineLimit(3)
                                    }.toggleStyle(.checkbox)
                                }
                            }
                        }.frame(height: min(280, max(100, CGFloat(row.segmentIDs.count) * 72)))
                    }
                    let suggestions = meeting.analysis?.analysis.speakerCandidates?.filter { $0.label == row.label } ?? []
                    if !suggestions.isEmpty {
                        DisclosureGroup("AI suggestions") {
                            ForEach(Array(suggestions.enumerated()), id: \.offset) { _, candidate in
                                Text(candidate.name + " · " + candidate.evidence.map(\.quote).joined(separator: " / "))
                                    .font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted)
                            }
                        }
                    }
                }
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save assignment") {
                    saving = true
                    Task {
                        do {
                            let targets = choosePassages ? Array(selected) : row.segmentIDs
                            if let saveDraft {
                                saveDraft(targets, SpeakerAttribution(name: name, jobTitle: role, employeeID: employeeID, method: "manual"))
                                dismiss(); return
                            }
                            try await model.store.editTranscript(meetingID: meeting.id, text: [:],
                                assignments: Dictionary(uniqueKeysWithValues: targets.map { ($0, SpeakerAttribution(name: name, jobTitle: role, employeeID: employeeID, method: "manual")) }),
                                expectedRevision: meeting.transcriptRevision, expectedSpeakerRevision: meeting.speakerRevision)
                            await model.reload(); dismiss()
                        } catch { self.error = error.localizedDescription; saving = false }
                    }
                }.buttonStyle(JottieButtonStyle(kind: .primary)).disabled(saving || (choosePassages && selected.isEmpty))
            }
            if let error { Text(error).font(JottieStyle.font(12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }.padding(28).frame(width: 610, height: 700)
            .onAppear {
                name = row.id.hasPrefix("voice:") ? "" : row.name
                role = row.jobTitle ?? ""; employeeID = row.employeeID; selectedName = name
                selected = initialSegmentID.map { Set([$0]) } ?? Set(row.segmentIDs); choosePassages = initialSegmentID != nil
            }
            .task { await model.loadDirectoryPeople() }
            .disabled(saving)
    }

    private var speakerChoices: some View {
        let invited = SpeakerChoice.calendarCandidates(for: meeting, people: model.directoryPeople)
        let matches = SpeakerChoice.directoryMatches(name, people: model.directoryPeople)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if !invited.isEmpty {
                    Text("From this meeting's calendar invitation").font(JottieStyle.font(11, .semibold)).foregroundStyle(JottieStyle.muted)
                    ForEach(invited) { choice in choiceButton(choice) }
                }
                if !NameAliases.normalise(name).isEmpty {
                    Text("BambooHR directory · \(matches.count) matches").font(JottieStyle.font(11, .semibold)).foregroundStyle(JottieStyle.muted)
                    ForEach(matches) { choice in choiceButton(choice) }
                    if matches.isEmpty { Text("No directory matches. You can save the name you entered.").font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted) }
                } else {
                    Text(model.directoryPeople.isEmpty ? "Sync BambooHR in Settings → Integrations for directory suggestions, or enter a name." : "Type to search all \(model.directoryPeople.count) people in the synced BambooHR directory, or enter a name.")
                        .font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(height: 180)
    }

    private func choiceButton(_ choice: SpeakerChoice) -> some View {
        Button {
            name = choice.name; selectedName = choice.name; role = choice.jobTitle ?? ""; employeeID = choice.employeeID
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(choice.name).font(JottieStyle.font(13, .medium))
                Text([choice.jobTitle, choice.email].compactMap { $0 }.joined(separator: " · "))
                    .font(JottieStyle.font(11)).foregroundStyle(JottieStyle.muted)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(JottieStyle.accent)
    }
}

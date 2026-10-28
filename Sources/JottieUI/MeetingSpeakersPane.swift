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
            JottieSection(title: "Speakers detected", icon: "person.2") {
                Text("Reconciled from voice labels, conversation evidence, invitation names and directory aliases. AI assignments are likely identities, not verified attendance.")
                    .font(JottieStyle.font(13)).foregroundStyle(JottieStyle.muted).lineSpacing(6)
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
                        if !row.evidence.isEmpty {
                            DisclosureGroup("Attribution evidence") {
                                ForEach(Array(row.evidence.enumerated()), id: \.offset) { _, item in
                                    Text("\(item.segmentID): “\(item.quote)”").font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted).textSelection(.enabled)
                                }
                            }.font(JottieStyle.font(12))
                        }
                    }.padding(16).overlay { RoundedRectangle(cornerRadius: 12).stroke(JottieStyle.border, lineWidth: 1) }
                }
                if meeting.speakerLabels.contains("them") || meeting.speakerLabels.contains("speaker") {
                    Text("A shared channel can contain several people. Correct individual passages where needed; old recordings without audio cannot be reliably separated by voice.")
                        .font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted).lineSpacing(5)
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
                Text("Regenerate summary to reconcile with the latest aliases and invitation. Original utterances stay intact; manual assignments take precedence.")
                    .font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted)
            }
        }.task { await model.loadDirectoryPeople() }
            .sheet(isPresented: $choosingCalendar) { MeetingCalendarPicker(model: model, meeting: meeting) }
            .sheet(item: $correcting) { SpeakerAssignmentEditor(model: model, meeting: meeting, row: $0) }
    }
}

@MainActor private struct SpeakerAssignmentEditor: View {
    @ObservedObject var model: LibraryViewModel
    let meeting: Meeting
    let row: ReconciledSpeaker
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name = ""
    @ViewState private var role = ""
    @ViewState private var employeeID: String?
    @ViewState private var selected = Set<String>()
    @ViewState private var choosePassages = false
    @ViewState private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Correct speaker assignment").font(JottieStyle.font(22, .semibold))
            Text("Apply to this row's passages, or select individual passages. Leave the name blank to mark them unknown. This correction overrides future AI analysis.")
                .font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted).fixedSize(horizontal: false, vertical: true)
            TextField("Full name", text: $name).textFieldStyle(JottieInputStyle()).onChange(of: name) { _, value in
                if model.directoryPeople.first(where: { $0.id == employeeID })?.name != value { employeeID = nil }
            }
            if !name.isEmpty {
                ForEach(Array(model.directoryPeople.filter { person in NameAliases.all(name: person.name, aliases: person.aliases).contains { NameAliases.normalise($0).contains(NameAliases.normalise(name)) } }.prefix(5))) { person in
                    Button(person.name + (person.jobTitle.map { " · " + $0 } ?? "")) { name = person.name; role = person.jobTitle ?? ""; employeeID = person.id }
                        .buttonStyle(.plain).foregroundStyle(JottieStyle.accent)
                }
            }
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
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save assignment") {
                    saving = true
                    Task {
                        do {
                            let matches = model.directoryPeople.filter { NameAliases.normalise($0.name) == NameAliases.normalise(name) }
                            try await model.store.setSpeakerAssignment(segmentIDs: choosePassages ? Array(selected) : row.segmentIDs,
                                name: name, role: role, employeeID: employeeID ?? (matches.count == 1 ? matches[0].id : nil), meetingID: meeting.id, expectedRevision: meeting.transcriptRevision)
                            await model.reload(); dismiss()
                        } catch { model.message = error.localizedDescription; saving = false }
                    }
                }.buttonStyle(JottieButtonStyle(kind: .primary)).disabled(saving || (choosePassages && selected.isEmpty))
            }
        }.padding(28).frame(width: 610)
            .onAppear { name = row.name.hasPrefix("Speaker ") ? "" : row.name; role = row.jobTitle ?? ""; employeeID = row.employeeID; selected = Set(row.segmentIDs) }
    }
}

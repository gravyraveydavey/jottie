import SwiftUI
import JottieModels
import JottieLibrary

struct TranscriptPassageDraft {
    var text: String
    let originalText: String
}

@MainActor struct InlineTranscriptText: View {
    @ObservedObject var model: LibraryViewModel
    let meetingID: UUID
    let segment: Segment
    @Binding var activePassage: String?
    @FocusState private var fieldFocused: Bool
    @ViewState private var editing = false
    @ViewState private var saving = false
    @ViewState private var error: String?
    private var key: String { meetingID.uuidString + ":" + segment.id }
    private var text: String { model.transcriptEditDrafts[key]?.text ?? segment.text }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if editing {
                TextField("Transcript passage", text: Binding(get: { text }, set: { value in
                    if model.transcriptEditDrafts[key] == nil { begin() }
                    model.transcriptEditDrafts[key]?.text = value
                }), axis: .vertical)
                    .textFieldStyle(JottieInputStyle()).font(JottieStyle.font(14)).lineSpacing(9)
                    .focused($fieldFocused)
                    .accessibilityLabel("Edit transcript at \(segment.startMS / 1000) seconds")
                    .task { await Task.yield(); fieldFocused = true }
                    .onTapGesture { fieldFocused = true }
                    .onExitCommand { cancel() }
            } else {
                Text(text).font(JottieStyle.font(14)).foregroundStyle(JottieStyle.muted).lineSpacing(9)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle()).onTapGesture { begin() }
                    .accessibilityAddTraits(.isButton).accessibilityAction { begin() }
                    .accessibilityHint("Click to edit")
            }
            if saving { ProgressView().controlSize(.mini).accessibilityLabel("Saving transcript edit") }
            if let error {
                HStack(alignment: .top) {
                    Text(error).font(JottieStyle.font(11)).foregroundStyle(.red)
                    Button("Retry") { editing = true; commit() }.buttonStyle(.plain).font(JottieStyle.font(11))
                    Button("Discard") { cancel() }.buttonStyle(.plain).font(JottieStyle.font(11))
                }
            } else if !editing && !saving && model.transcriptEditDrafts[key] != nil {
                Text("Unsaved edit").font(JottieStyle.font(11)).foregroundStyle(.red)
            }
        }
        .onChange(of: activePassage) { _, value in if value != segment.id { commit() } }
        .onChange(of: fieldFocused) { _, value in if !value { commit() } }
        .onDisappear { commit() }
    }
    private func begin() {
        guard !saving else { return }
        if model.transcriptEditDrafts[key] == nil {
            model.transcriptEditDrafts[key] = TranscriptPassageDraft(text: segment.text, originalText: segment.text)
        }
        error = nil; editing = true; activePassage = segment.id
    }
    private func cancel() {
        editing = false; model.transcriptEditDrafts[key] = nil; error = nil; fieldFocused = false
        if activePassage == segment.id { activePassage = nil }
    }
    private func commit() {
        guard editing, !saving, let draft = model.transcriptEditDrafts[key] else { return }
        editing = false; fieldFocused = false
        if activePassage == segment.id { activePassage = nil }
        guard draft.text != draft.originalText else { model.transcriptEditDrafts[key] = nil; return }
        saving = true; error = nil
        Task {
            do {
                try await model.store.editTranscriptPassage(meetingID: meetingID, segmentID: segment.id,
                    text: draft.text, expectedText: draft.originalText)
                await model.reload()
                if model.transcriptEditDrafts[key]?.text == draft.text { model.transcriptEditDrafts[key] = nil }
            } catch { self.error = error.localizedDescription; model.message = error.localizedDescription; await model.reload() }
            saving = false
        }
    }
}

@MainActor struct TranscriptSpeakerLabel: View {
    @ObservedObject var model: LibraryViewModel
    let meeting: Meeting
    let label: String
    let name: String
    let beforeOpen: () -> Void
    @ViewState private var choosing = false
    var body: some View {
        Button { beforeOpen(); choosing = true } label: {
            Text(name).font(JottieStyle.font(12, .semibold))
        }.buttonStyle(.plain).help("Reassign all passages from this speaker")
            .popover(isPresented: $choosing, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                TranscriptSpeakerPicker(model: model, meeting: meeting, label: label) { choosing = false }
            }
    }
}

@MainActor private struct TranscriptSpeakerPicker: View {
    @ObservedObject var model: LibraryViewModel
    let meeting: Meeting
    let label: String
    let didAssign: () -> Void
    @ViewState private var query = ""
    @ViewState private var saving = false
    @ViewState private var error: String?
    private var invited: [SpeakerChoice] {
        let needle = NameAliases.normalise(query)
        return SpeakerChoice.calendarCandidates(for: meeting, people: model.directoryPeople).filter { choice in
            needle.isEmpty || (NameAliases.all(name: choice.name, aliases: nil) + [choice.email ?? ""])
                .contains { NameAliases.normalise($0).contains(needle) }
        }
    }
    private var matches: [SpeakerChoice] {
        let shortlisted = Set(invited.map(\.id))
        return SpeakerChoice.directoryMatches(query, people: model.directoryPeople).filter { !shortlisted.contains($0.id) }
    }
    private var listHeight: CGFloat {
        let count = invited.count + (query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (invited.isEmpty ? meeting.reconciledSpeakers.filter { !$0.id.hasPrefix("voice:") }.count : 0)
            : matches.count + 1)
        return min(240, max(44, CGFloat(count) * 48 + 24))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search or enter a name", text: $query).textFieldStyle(JottieInputStyle())
                .accessibilityLabel("Search BambooHR speakers")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if !invited.isEmpty {
                        Text("From calendar").font(JottieStyle.font(10, .medium)).foregroundStyle(JottieStyle.muted)
                        ForEach(invited) { choice in candidate(choice) }
                    }
                    if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("BambooHR directory").font(JottieStyle.font(10, .medium)).foregroundStyle(JottieStyle.muted).padding(.top, 6)
                        ForEach(matches) { choice in candidate(choice) }
                        Button("Use “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”") {
                            assign(SpeakerAttribution(name: query, method: "manual"))
                        }.buttonStyle(.plain).font(JottieStyle.font(12)).padding(.vertical, 8)
                    } else if invited.isEmpty {
                        ForEach(meeting.reconciledSpeakers.filter { !$0.id.hasPrefix("voice:") }) { person in
                            Button(person.name) { assign(SpeakerAttribution(name: person.name, jobTitle: person.jobTitle, employeeID: person.employeeID, method: "manual")) }
                                .buttonStyle(.plain).font(JottieStyle.font(12)).padding(.vertical, 8)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: listHeight)
            if saving { ProgressView().controlSize(.small) }
            if let error { Text(error).font(JottieStyle.font(11)).foregroundStyle(.red) }
        }.padding(16).frame(width: 300).disabled(saving)
            .task { await model.loadDirectoryPeople() }
    }
    private func candidate(_ choice: SpeakerChoice) -> some View {
        Button { assign(SpeakerAttribution(name: choice.name, jobTitle: choice.jobTitle, employeeID: choice.employeeID, method: "manual")) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(choice.name).font(JottieStyle.font(13, .medium))
                let detail = [choice.jobTitle, choice.email].compactMap { $0 }.joined(separator: " · ")
                if !detail.isEmpty { Text(detail).font(JottieStyle.font(10)).foregroundStyle(JottieStyle.muted) }
            }.padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func assign(_ assignment: SpeakerAttribution) {
        saving = true; error = nil
        Task {
            do {
                try await model.store.assignTranscriptSpeaker(meetingID: meeting.id, label: label, assignment: assignment)
                await model.reload(); didAssign()
            } catch { self.error = error.localizedDescription; saving = false }
        }
    }
}

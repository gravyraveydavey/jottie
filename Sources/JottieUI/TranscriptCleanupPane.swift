import SwiftUI
import JottieModels
import JottieLibrary

@MainActor struct TranscriptCleanupTools: View {
    @ObservedObject var model: LibraryViewModel
    let meeting: Meeting
    @Binding var showOriginal: Bool
    let openSuggestions: () -> Void
    @ViewState private var editingContext = false
    @ViewState private var historyPresentation: CleanupHistoryPresentation?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(meeting.recordingContext?.playbackDescription ?? "Recording context unavailable").font(JottieStyle.font(12, .medium))
            if !meeting.cleanupRecommendation.isEmpty {
                Label(meeting.cleanupRecommendation, systemImage: "waveform.path").font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted)
            }
            Text("Cleanup sends transcript text, invitees, matched directory details and recording context to Codex using your ChatGPT sign-in. You review changes before applying them.")
                .font(JottieStyle.font(11)).foregroundStyle(JottieStyle.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                if model.isCleaning(meeting) {
                    ProgressView().controlSize(.small)
                    Text(model.cleanupStatus(for: meeting)).font(JottieStyle.font(12))
                    if model.cleanupProcessingID == meeting.id {
                        Button("Cancel") { model.cancelTranscriptCleanup() }.buttonStyle(JottieButtonStyle(kind: .outline, compact: true))
                    }
                } else {
                    Button(action: openSuggestions) { Label(meeting.cleanupDraft == nil ? "Clean up transcript" : "Review cleanup", systemImage: "wand.and.stars") }
                        .buttonStyle(JottieButtonStyle(kind: .outline, compact: true))
                        .disabled(model.working || model.cleanupProcessingID != nil)
                }
                Button("Recording context…") { editingContext = true }.buttonStyle(JottieButtonStyle(kind: .outline, compact: true))
                Menu {
                    if meeting.cleanupOriginalSegments != nil {
                        Button(showOriginal ? "Show cleaned transcript" : "Show original transcript") { showOriginal.toggle() }
                        Button("Restore original transcript") { Task { await model.restoreOriginalTranscript(meeting) } }
                    }
                    Button("Cleanup history…") {
                        Task {
                            do { historyPresentation = CleanupHistoryPresentation(revisions: try await model.store.cleanupHistory(meetingID: meeting.id)) }
                            catch { model.message = error.localizedDescription }
                        }
                    }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
            }
            if let revision = meeting.activeCleanup {
                Text(showOriginal ? "Original transcript · retained for comparison" : "Reviewed cleanup · \(revision.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(JottieStyle.font(11)).foregroundStyle(JottieStyle.muted)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(JottieStyle.selection.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .sheet(isPresented: $editingContext) { RecordingContextEditor(model: model, meeting: meeting) }
        .sheet(item: $historyPresentation) { history in CleanupHistorySheet(meeting: meeting, revisions: history.revisions) }
    }
}

@MainActor struct RecordingContextEditor: View {
    @ObservedObject var model: LibraryViewModel
    let meeting: Meeting
    @Environment(\.dismiss) private var dismiss
    @ViewState private var playback = "detected"
    @ViewState private var note = ""
    @ViewState private var error: String?
    @ViewState private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Recording context").font(JottieStyle.font(20, .semibold))
            Text("Confirm how you listened during this meeting. Connection type alone cannot distinguish speakers from headphones.")
                .font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted)
            Picker("Playback", selection: $playback) {
                Text("Use detected context").tag("detected")
                Text("Speakers").tag("speakers")
                Text("Headphones").tag("headphones")
                Text("Unknown").tag("unknown")
            }
            TextField("Additional context, e.g. external USB microphone", text: $note, axis: .vertical).lineLimit(3...5)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array((meeting.recordingContext?.routes ?? []).enumerated()), id: \.offset) { _, route in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(route.at.formatted(date: .omitted, time: .standard)).font(JottieStyle.mono(10))
                            Text("Microphone: \(route.input.name ?? "Unknown") · \(route.input.transport)")
                            Text("Playback: \(route.output.name ?? "Unknown") · \(route.output.transport) · \(route.output.kind)")
                            Text(route.outputSource == "call_app" ? "Playback reported by the call app" : "System default playback; call-app routing may differ")
                        }.font(JottieStyle.font(11)).foregroundStyle(JottieStyle.muted)
                    }
                    if let cancellation = meeting.recordingContext?.echoCancellation { Text("Audio echo cancellation: \(cancellation)").font(JottieStyle.font(11)) }
                    if let count = meeting.recordingContext?.echoSegmentsRemoved { Text("Local echo cleanup removed \(count) passages.").font(JottieStyle.font(11)) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 180)
            if let error { Text(error).foregroundStyle(.red).font(JottieStyle.font(12)) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save context") {
                    saving = true
                    Task {
                        defer { saving = false }
                        do { try await model.updateRecordingContext(meeting, playback: playback == "detected" ? nil : playback, note: note); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.disabled(saving || note.count > 4000).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 560)
        .onAppear { playback = meeting.recordingContext?.playbackOverride ?? "detected"; note = meeting.recordingContext?.userNote ?? "" }
    }
}

@MainActor struct CleanupSuggestionsPane: View {
    @ObservedObject var model: LibraryViewModel
    let meeting: Meeting
    @Binding var selectedChanges: Set<String>
    @Binding var selectedSpeakers: Set<String>
    let didOverwrite: () -> Void
    @ViewState private var preferences = TranscriptCleanupPreferences()
    @ViewState private var expectedCount = ""
    @ViewState private var optionsExpanded = true
    @ViewState private var changesExpanded = false
    @ViewState private var speakersExpanded = false
    @ViewState private var error: String?
    @ViewState private var applying = false
    private var savedPreferences: TranscriptCleanupPreferences { meeting.cleanupPreferences ?? TranscriptCleanupPreferences() }
    private var currentPreferences: TranscriptCleanupPreferences {
        var value = preferences; value.expectedSpeakerCount = Int(expectedCount); return value
    }
    private var validCount: Bool { expectedCount.isEmpty || Int(expectedCount).map { (1...50).contains($0) } == true }
    private var stale: Bool {
        guard let draft = meeting.cleanupDraft else { return false }
        return draft.baseRevision != meeting.transcriptRevision || draft.contextRevision != meeting.cleanupContextRevision || draft.promptRevision != model.cleanupPromptRevision
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            DisclosureGroup("Cleanup options", isExpanded: $optionsExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Join nearby fragments from the same confirmed speaker", isOn: $preferences.joinFragments)
                    Toggle("Remove um, uh, erm and other hesitation fillers", isOn: $preferences.stripFillers)
                    Text("Joined sentences keep the timestamp of their first fragment. The original remains recoverable.").foregroundStyle(JottieStyle.muted)
                    HStack {
                        Text("Confirmed number of speakers (optional)")
                        TextField("e.g. 2", text: $expectedCount).frame(width: 70)
                    }
                    TextField("Additional cleanup instructions", text: $preferences.instructions, axis: .vertical).lineLimit(3...6)
                    Text("Your manual speaker assignments take precedence. A confirmed count constrains the result; it does not identify unnamed people.")
                        .foregroundStyle(JottieStyle.muted)
                    Text("This sends transcript text, matched invitation/directory information and recording context to Codex using your ChatGPT sign-in. You review the result before overwriting.")
                        .foregroundStyle(JottieStyle.muted)
                }.font(JottieStyle.font(12)).padding(.top, 12)
            }.font(JottieStyle.font(14, .medium)).disabled(model.isCleaning(meeting))
            HStack(spacing: 12) {
                if model.isCleaning(meeting) {
                    ProgressView().controlSize(.small)
                    Text(model.cleanupStatus(for: meeting)).font(JottieStyle.font(12))
                    if model.cleanupProcessingID == meeting.id {
                        Button("Cancel") { model.cancelTranscriptCleanup() }.buttonStyle(JottieButtonStyle(kind: .outline, compact: true))
                    }
                } else {
                    Button(meeting.cleanupDraft == nil ? "Generate cleanup suggestions" : "Generate fresh suggestions") {
                        error = nil; model.startTranscriptCleanup(meeting, preferences: currentPreferences)
                    }.buttonStyle(JottieButtonStyle(kind: .outline, compact: true))
                        .disabled(!validCount || preferences.instructions.count > 4000 || model.working || model.cleanupProcessingID != nil)
                }
                Spacer()
                if meeting.cleanupDraft != nil {
                    Button("Overwrite transcript") {
                        applying = true
                        Task {
                            defer { applying = false }
                            do { try await model.applyTranscriptCleanup(meeting, changes: selectedChanges, speakers: selectedSpeakers); didOverwrite() }
                            catch { self.error = error.localizedDescription }
                        }
                    }.buttonStyle(JottieButtonStyle(kind: .primary, compact: true))
                        .disabled(applying || stale || currentPreferences != savedPreferences || (selectedChanges.isEmpty && selectedSpeakers.isEmpty) || model.cleanupProcessingID != nil || model.isCleaning(meeting))
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(JottieStyle.font(12)) }
            if stale || (meeting.cleanupDraft != nil && currentPreferences != savedPreferences) {
                Text("The transcript, speakers or cleanup options have changed. Generate fresh suggestions before overwriting.")
                    .font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted)
            }
            if let draft = meeting.cleanupDraft {
                review(draft)
            } else {
                Text("Generate a readable transcript preview here. The saved transcript stays unchanged until you choose Overwrite transcript.")
                    .font(JottieStyle.font(14)).foregroundStyle(JottieStyle.muted)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { loadPreferences(); loadSelection() }
        .onChange(of: meeting.id) { _, _ in loadPreferences(); loadSelection() }
        .onChange(of: meeting.cleanupDraft?.id) { _, _ in loadPreferences(); loadSelection() }
    }
    @ViewBuilder private func review(_ draft: TranscriptCleanupRevision) -> some View {
        DisclosureGroup("Review \(draft.result.changes.count) individual changes", isExpanded: $changesExpanded) {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(draft.result.changes) { change in
                    CleanupChangeRow(change: change, selected: selection(change.id, in: $selectedChanges))
                }
            }.padding(.top, 12)
        }.font(JottieStyle.font(13, .medium))
        if !draft.result.speakerSuggestions.isEmpty {
            DisclosureGroup("Speaker suggestions (optional)", isExpanded: $speakersExpanded) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Speaker suggestions start unchecked. Confirmed identities cannot be overwritten.").font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted)
                    ForEach(draft.result.speakerSuggestions) { suggestion in
                        let protected = suggestion.segmentIDs.contains { id in
                            guard let segment = meeting.segments.first(where: { $0.id == id }) else { return true }
                            return meeting.speakerAttributions?[id]?.method == "manual" || meeting.speakerNames[segment.speaker]?.isEmpty == false || meeting.hasNamedSourceLabel(segment.speaker)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(isOn: selection(suggestion.id, in: $selectedSpeakers)) { Text(suggestion.name).font(JottieStyle.font(13, .semibold)) }.disabled(protected)
                            Text(suggestion.reason)
                            ForEach(Array(suggestion.evidence.enumerated()), id: \.offset) { _, evidence in Text("“\(evidence.quote)”").foregroundStyle(JottieStyle.muted).textSelection(.enabled) }
                        }.font(JottieStyle.font(12)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.top, 12)
            }.font(JottieStyle.font(13, .medium))
        }
        ForEach(Array(draft.result.notes.enumerated()), id: \.offset) { _, note in Text(note).font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted) }
        JottieRule()
        Text("Proposed transcript").font(JottieStyle.font(18, .semibold))
        if let proposed = try? draft.result.projectedSegments(against: meeting, selecting: selectedChanges) {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(proposed) { segment in
                    HStack(alignment: .top, spacing: 16) {
                        Text(String(format: "%02d:%02d", segment.startMS / 60000, segment.startMS / 1000 % 60))
                            .font(JottieStyle.mono()).foregroundStyle(JottieStyle.muted).frame(width: 44, alignment: .leading)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(meeting.speakerName(for: segment)).font(JottieStyle.font(12, .semibold))
                            Text(segment.text).font(JottieStyle.font(14)).lineSpacing(7).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("These selections conflict or the preview is out of date. Keep one copy of each duplicate, or generate fresh suggestions.")
                .font(JottieStyle.font(13)).foregroundStyle(.red)
        }
    }
    private func loadPreferences() { preferences = savedPreferences; expectedCount = savedPreferences.expectedSpeakerCount.map(String.init) ?? "" }
    private func loadSelection() {
        optionsExpanded = meeting.cleanupDraft == nil
        selectedChanges = Set(meeting.cleanupDraft?.result.changes.filter { !$0.uncertain }.map(\.id) ?? []); selectedSpeakers = []
    }
    private func selection(_ id: String, in values: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { values.wrappedValue.contains(id) }, set: { selected in
            if selected { values.wrappedValue.insert(id) } else { values.wrappedValue.remove(id) }
        })
    }
}

private struct CleanupChangeRow: View {
    let change: TranscriptTextChange
    @Binding var selected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $selected) {
                Text((change.kind == "duplicate" ? "Remove duplicate" : change.kind == "filler" ? "Remove hesitation" : change.sourceIDs.count > 1 ? "Join \(change.sourceIDs.count) fragments" : "Correct wording") + (change.uncertain ? " · uncertain" : ""))
                    .font(JottieStyle.font(13, .semibold))
            }
            Text("Original: \(change.originalText)").foregroundStyle(JottieStyle.muted).textSelection(.enabled)
            Text(change.replacementText.isEmpty ? "Proposed: remove this redundant passage" : "Proposed: \(change.replacementText)").textSelection(.enabled)
            Text(change.reason).foregroundStyle(JottieStyle.muted)
        }.font(JottieStyle.font(13)).frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(JottieStyle.selection.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct CleanupHistoryPresentation: Identifiable {
    let id = UUID()
    var revisions: [TranscriptCleanupRevision]
}

private struct CleanupHistorySheet: View {
    let meeting: Meeting
    let revisions: [TranscriptCleanupRevision]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Cleanup history").font(JottieStyle.font(20, .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if revisions.isEmpty { Text("No cleanup revisions have been applied.") }
                    ForEach(revisions) { revision in
                        DisclosureGroup {
                            Text("Model: \(revision.model.isEmpty ? "Configured Codex default" : revision.model) · \(revision.effort.isEmpty ? "Default reasoning" : revision.effort)").foregroundStyle(JottieStyle.muted)
                            ForEach(revision.result.changes.filter { revision.selectedChangeIDs?.contains($0.id) == true }) { change in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Original: \(change.originalText)")
                                    Text(change.kind == "duplicate" ? "Removed duplicate" : "Applied: \(change.replacementText)")
                                    Text(change.reason).foregroundStyle(JottieStyle.muted)
                                }.padding(.vertical, 8).textSelection(.enabled)
                            }
                            ForEach(revision.result.speakerSuggestions.filter { revision.selectedSpeakerIDs?.contains($0.id) == true }) { suggestion in Text("Speaker assignment: \(suggestion.name) · \(suggestion.reason)") }
                        } label: {
                            Text("\(revision.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(revision.selectedChangeIDs?.count ?? 0) text changes · \(revision.selectedSpeakerIDs?.count ?? 0) speaker suggestions")
                        }
                    }
                }.font(JottieStyle.font(12)).frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }.padding(24).frame(width: 680, height: 500)
    }
}

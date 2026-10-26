import SwiftUI
import AppKit
import JottieModels
import JottieLibrary
import JottieKnowledge

@MainActor struct LibrarySettingsView: View {
    @ObservedObject var model: LibraryViewModel
    @Environment(\.dismiss) var dismiss
    @ViewState private var preview = false
    @ViewState private var promptKind = "meeting"
    private var editedPrompt: Binding<String> { promptKind == "meeting" ? $model.settings.summaryPrompt : $model.settings.folderContextPrompt }
    var body: some View {
        VStack {
            TabView {
                Form {
                    Section("Codex summaries and organisation") {
                        Toggle("Automatically analyse meetings with my signed-in Codex CLI", isOn: $model.settings.analysisEnabled)
                        Text("Transcription stays on this Mac. Codex receives meeting text and selected context using your subscription; usage limits apply.").font(.caption).foregroundStyle(.secondary)
                        TextField("Codex executable (automatic if blank)", text: $model.settings.codexPath)
                            .onChange(of: model.settings.codexPath) { _, _ in model.codexStatus = nil; model.codexTestMessage = nil }
                        if let status = model.codexStatus {
                            Label(status.message, systemImage: status.ready ? "checkmark.circle.fill" : "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(status.ready ? Color.green : Color.orange)
                            if let version = status.version { Text(version).font(.caption).textSelection(.enabled) }
                            if !status.executable.isEmpty { Text(status.executable).font(.caption).textSelection(.enabled) }
                        }
                        HStack {
                            Button(model.checkingCodex ? "Checking…" : "Check Codex") { Task { await model.checkCodex() } }
                                .disabled(model.checkingCodex || model.testingCodex)
                            Button(model.testingCodex ? "Testing…" : "Test connection") { Task { await model.testCodex() } }
                                .disabled(model.checkingCodex || model.testingCodex)
                        }
                        Text("Check verifies installation and ChatGPT sign-in. Test sends a small invented prompt using your Codex allowance.").font(.caption).foregroundStyle(.secondary)
                        if let result = model.codexTestMessage { Text(result).font(.callout).textSelection(.enabled) }
                        Picker("Model", selection: $model.settings.codexModel) {
                            Text("CLI default").tag("")
                            ForEach(model.codexModels) { choice in Text(choice.name).tag(choice.id) }
                            if !model.settings.codexModel.isEmpty && !model.codexModels.contains(where: { $0.id == model.settings.codexModel }) {
                                Text(model.settings.codexModel).tag(model.settings.codexModel)
                            }
                        }
                        TextField("Model ID (blank for CLI default)", text: $model.settings.codexModel)
                            .onChange(of: model.settings.codexModel) { _, _ in
                                if !model.codexEfforts.contains(model.settings.codexEffort) { model.settings.codexEffort = "" }
                            }
                        Picker("Reasoning effort", selection: $model.settings.codexEffort) {
                            ForEach(model.codexEfforts, id: \.self) { effort in Text(effort.isEmpty ? "Model default" : effort.capitalized).tag(effort) }
                        }
                        Text("The list comes from your CLI. Model access depends on your account. These choices apply to summaries, tags and folder context; Test connection uses them too.").font(.caption).foregroundStyle(.secondary)
                        Stepper("Folder context check: \(model.settings.refreshMinutes) minutes", value: $model.settings.refreshMinutes, in: 1...10080)
                        Button("Update folder contexts now") { Task { if await model.saveSettings(processPending: false) { await model.updateNow() } } }
                    }
                    Section("Capture") {
                        Text("Audio is temporary and deleted after successful local transcription. Failed sessions keep their audio for recovery.").font(.callout)
                        Button("Recording settings…") { model.onCaptureSettings?() }
                    }
                    Section("Assistant access") {
                        Text("One local Jottie MCP connection exposes read-only meeting search, transcripts and folder context.")
                        LabeledContent("Name", value: "Jottie")
                        LabeledContent("Description", value: "Search local meeting summaries, transcripts and folder knowledge.")
                        LabeledContent("Connection", value: "Local command · stdio")
                        LabeledContent("Server URL / Tunnel", value: "Not used by this local service")
                        LabeledContent("Authentication", value: "None · access uses your macOS account")
                        Text("If Codex's connection window only offers Server URL or Tunnel, use the copied configuration in Codex Settings → Configuration → config.toml instead. Jottie does not expose an HTTP endpoint or create a tunnel. Codex sign-in is needed for analysis, not for MCP retrieval.").font(.caption).foregroundStyle(.secondary)
                        Button("Copy Codex MCP configuration") { model.copyMCPConfig() }
                    }
                }.formStyle(.grouped).tabItem { Label("General", systemImage: "gearshape") }
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Prompt", selection: $promptKind) {
                        Text("Meeting summary").tag("meeting")
                        Text("Folder context").tag("folder")
                    }.pickerStyle(.segmented)
                    Text(promptKind == "meeting" ? "Applies to new analysis. Regenerate selected meetings to use a changed prompt." : "Folder context reads structured meeting summaries across the subtree. Save, then Update folder contexts now to rebuild using this format.").font(.caption).foregroundStyle(.secondary)
                    Text("Evidence and publication rules always apply.").font(.caption).foregroundStyle(.secondary)
                    if preview {
                        ScrollView { Text(editedPrompt.wrappedValue).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
                    } else {
                        TextEditor(text: editedPrompt).font(.body).border(.quaternary)
                    }
                    HStack {
                        Toggle("Preview", isOn: $preview).toggleStyle(.checkbox)
                        Spacer()
                        Button("Reset default") { editedPrompt.wrappedValue = promptKind == "meeting" ? Prompts.summary : Prompts.folderContext }
                    }
                }.padding().tabItem { Label("Summary", systemImage: "text.alignleft") }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Choose calendars for meeting titles and speaker context.").font(.headline)
                    Text("Attendees are identity candidates. Calendar-triggered recording is configured separately in Recording settings.").font(.caption).foregroundStyle(.secondary)
                    Button("Load calendars / request access") {
                        Task {
                            do { model.calendars = try await EventKitCalendars().choices() }
                            catch { model.message = error.localizedDescription }
                        }
                    }
                    List(model.calendars) { choice in
                        Toggle(choice.title, isOn: Binding(get: { model.settings.selectedCalendarIDs.contains(choice.id) }, set: { selected in
                            model.settings.selectedCalendarIDs.removeAll { $0 == choice.id }
                            if selected { model.settings.selectedCalendarIDs.append(choice.id) }
                        }))
                    }
                    Text("Calendar changes take effect for future recordings. Relaunch after enabling calendar integration in Recording settings.").font(.caption).foregroundStyle(.secondary)
                }.padding().tabItem { Label("Calendars", systemImage: "calendar") }
                Form {
                    Text("Register Jottie as a public macOS client in your Microsoft tenant. Tokens stay in the Microsoft Keychain cache.").font(.callout)
                    TextField("Application (client) ID", text: $model.settings.microsoftClientID)
                    TextField("Tenant ID", text: $model.settings.microsoftTenantID)
                    Text("Redirect URI: msauth.com.gravyraveydavey.jottie://auth").font(.caption).textSelection(.enabled)
                    Button("Save and sign into Microsoft…") {
                        Task { if await model.saveSettings() { await model.signIn() } }
                    }
                    Text(model.accountID.isEmpty ? "Sign in, then edit a folder to choose its publication destination." : "Connected. Folder destinations can now be selected.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Publishing is one-way. Remote revisions remain available after local moves or deletion.").font(.caption)
                }.formStyle(.grouped).tabItem { Label("Microsoft", systemImage: "cloud") }
            }
            HStack {
                if let message = model.message { Text(message).font(.caption).lineLimit(3) }
                Spacer()
                Button("Save") { Task { if await model.saveSettings() { model.configurePublisher(); dismiss() } } }.keyboardShortcut(.defaultAction)
            }.padding()
        }.frame(width: 760, height: 680)
            .task { await model.checkCodex() }
    }
}

@MainActor struct FolderEditor: View {
    @ObservedObject var model: LibraryViewModel
    @ViewState var folder: Folder
    @Environment(\.dismiss) var dismiss
    @ViewState private var aliases = ""
    @ViewState private var remoteURL = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Folder").font(.title2)
            TextField("Name", text: $folder.name)
            TextField("Tag aliases (comma separated)", text: $aliases)
            Picker("Parent", selection: Binding(get: { folder.parentID?.uuidString ?? "" }, set: { folder.parentID = UUID(uuidString: $0) })) {
                Text("Root").tag("")
                ForEach(model.flatFolders.filter {
                    !LibraryStore.descendants(folder.id, in: model.folders).contains($0.folder.id)
                }, id: \.folder.id) { item in Text(String(repeating: "  ", count: item.depth) + item.folder.name).tag(item.folder.id.uuidString) }
            }
            Divider()
            Text("SharePoint / OneDrive publishing").font(.headline)
            if let destination = folder.destination {
                Text(destination.webURL).font(.caption).textSelection(.enabled)
                Button("Disable publishing for this folder") { folder.destination = nil }
            }
            TextField("Destination folder sharing URL", text: $remoteURL)
            Button("Connect destination and enable publication") {
                Task {
                    folder.aliases = aliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    if await model.saveFolder(folder) { await model.connect(folder, url: remoteURL) }
                    if let updated = model.folders.first(where: { $0.id == folder.id }) { folder = updated }
                }
            }.disabled(remoteURL.isEmpty || folder.name.isEmpty)
            Text("Applies to this folder and descendants unless a subfolder has its own destination. Unfiled meetings in Import stay local.").font(.caption).foregroundStyle(.secondary)
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                if model.folders.contains(where: { $0.id == folder.id }) {
                    Button("Delete empty folder", role: .destructive) {
                        Task {
                            do { try await model.store.deleteFolder(folder.id); await model.reload(); dismiss() }
                            catch { model.message = error.localizedDescription }
                        }
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    folder.aliases = aliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    Task { if await model.saveFolder(folder) { dismiss() } }
                }.disabled(folder.name.trimmingCharacters(in: .whitespaces).isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 580)
            .onAppear { aliases = folder.aliases.joined(separator: ", ") }
    }
}

@MainActor struct SpeakerEditor: View {
    @ObservedObject var model: LibraryViewModel
    let meeting: Meeting
    @ViewState private var names: [String: String] = [:]
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Speaker corrections").font(.title2)
            Text("Only name a channel when you know who spoke. A shared remote channel may contain several people.").font(.callout).foregroundStyle(.secondary)
            ForEach(Array(Set(meeting.segments.map(\.speaker))).sorted(), id: \.self) { label in
                TextField(label, text: Binding(get: { names[label] ?? "" }, set: { names[label] = $0 }))
                ForEach(Array((meeting.analysis?.analysis.speakerCandidates ?? []).filter { $0.label == label }.enumerated()), id: \.offset) { _, candidate in
                    HStack {
                        Text("Unconfirmed: \(candidate.name) · \(candidate.evidence.map(\.quote).joined(separator: " "))").font(.caption)
                        Button("Use name") { names[label] = candidate.name }
                    }
                }
            }
            Text("Source utterances stay unchanged. Regenerate analysis to apply corrected names to a new summary revision.").font(.caption)
            HStack {
                Spacer(); Button("Cancel") { dismiss() }
                Button("Save") {
                    Task {
                        do {
                            for (label, name) in names { try await model.store.setSpeaker(label, name: name, meetingID: meeting.id) }
                            await model.reload(); dismiss()
                        } catch { model.message = error.localizedDescription }
                    }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 520).onAppear { names = meeting.speakerNames }
    }
}

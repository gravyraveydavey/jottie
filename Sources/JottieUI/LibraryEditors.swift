import SwiftUI
import AppKit
import JottieModels
import JottieLibrary
import JottieKnowledge

@MainActor struct LibrarySettingsView: View {
    @ObservedObject var model: LibraryViewModel
    @ViewState private var tab = "Summary prompts"
    @ViewState private var preview = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 24)).foregroundStyle(JottieStyle.accent)
                    Text("Settings").font(JottieStyle.font(30, .semibold)).tracking(-0.7)
                    Text("Shape how Jottie brings your conversations together.").foregroundStyle(JottieStyle.muted)
                }
                HStack(spacing: 16) {
                    ForEach([("Summary prompts", "text.alignleft"), ("General", "gearshape"), ("Calendars", "calendar"), ("Microsoft", "cloud"), ("MCP", "link")], id: \.0) { name, icon in
                        DocumentTab(title: name, icon: icon, selected: tab == name) { tab = name }
                    }
                }
                Group {
                    switch tab {
                    case "Summary prompts": prompts
                    case "General": general
                    case "Calendars": calendars
                    case "Microsoft": microsoft
                    default: mcp
                    }
                }
                JottieRule()
                HStack(spacing: 12) {
                    Button {
                        Task { if await model.saveSettings() { model.configurePublisher() } }
                    } label: { Label("Save settings", systemImage: "checkmark") }
                        .buttonStyle(JottieButtonStyle(kind: .primary)).disabled(!model.settingsDirty || model.settings.summaryPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.settings.folderContextPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .keyboardShortcut("s", modifiers: .command)
                    Text(model.settingsDirty ? "You have unsaved changes." : "Settings saved on this Mac.").font(JottieStyle.font(11)).foregroundStyle(JottieStyle.muted)
                    Spacer()
                }
            }.padding(.horizontal, 48).padding(.vertical, 40).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
        }.font(JottieStyle.font(14)).background(JottieStyle.background)
            .textFieldStyle(JottieInputStyle()).buttonStyle(JottieButtonStyle(kind: .outline))
            .task { if model.codexStatus == nil { await model.checkCodex() } }
    }
    private var prompts: some View {
        VStack(alignment: .leading, spacing: 24) {
            JottieSection(title: "Summary prompts") {
                description("When a prompt changes, existing summaries can be updated explicitly. Regenerate one summary or use Update summaries to refresh the library.")
            }
            Toggle("Preview prompts", isOn: $preview).toggleStyle(.checkbox).font(JottieStyle.font(12))
            promptEditor("Meeting summary prompt", text: $model.settings.summaryPrompt,
                         hint: "Used for each meeting’s overview, topics, decisions and next steps.", defaultValue: Prompts.summary)
            promptEditor("Folder summary prompt", text: $model.settings.folderContextPrompt,
                         hint: "Combines structured meeting summaries across this folder and all subfolders. Transcripts are not read.", defaultValue: Prompts.folderContext)
            JottieRule()
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Keep your library up to date").font(JottieStyle.font(14, .semibold))
                    Text("\(model.updateCount) summaries are missing or use earlier inputs.").font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted)
                }
                Spacer()
                Button("Update summaries") { Task { await model.updateSummaries() } }
                    .disabled(model.settingsDirty || model.working)
            }
            description("Evidence and publication rules always apply. Existing revisions remain available; saving a prompt does not overwrite meeting history.")
        }
    }
    private func promptEditor(_ title: String, text: Binding<String>, hint: String, defaultValue: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(JottieStyle.font(13, .medium))
                Spacer()
                Button("Reset default") { text.wrappedValue = defaultValue }.buttonStyle(JottieButtonStyle(compact: true))
            }
            if preview {
                Text(text.wrappedValue).font(JottieStyle.font(13)).textSelection(.enabled).padding(12).frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
                    .background(JottieStyle.surface, in: RoundedRectangle(cornerRadius: 8))
            } else {
                TextEditor(text: text).font(JottieStyle.font(13)).scrollContentBackground(.hidden).padding(8).frame(height: 145)
                    .background(JottieStyle.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).stroke(JottieStyle.border, lineWidth: 1) }.accessibilityLabel(title)
            }
            description(hint)
        }
    }
    private var general: some View {
        VStack(alignment: .leading, spacing: 24) {
            JottieSection(title: "Codex summaries and organisation") {
                Toggle("Automatically analyse meetings with my signed-in Codex CLI", isOn: $model.settings.analysisEnabled).toggleStyle(.switch)
                description("Transcription stays on this Mac. Codex receives meeting text using your subscription; usage limits apply. There is no API fallback.")
                field("Codex executable", hint: "Automatic discovery if blank") {
                    TextField("Automatic", text: $model.settings.codexPath)
                        .onChange(of: model.settings.codexPath) { _, _ in model.codexStatus = nil; model.codexTestMessage = nil }
                }
                if let status = model.codexStatus {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(status.message, systemImage: status.ready ? "checkmark.circle" : "exclamationmark.triangle").foregroundStyle(status.ready ? Color.green : .orange)
                        if let version = status.version { description(version) }
                        if !status.executable.isEmpty { Text(status.executable).font(JottieStyle.mono(10)).foregroundStyle(JottieStyle.muted).textSelection(.enabled) }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(JottieStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                }
                HStack {
                    Button(model.checkingCodex ? "Checking…" : "Check Codex") { Task { await model.checkCodex() } }.disabled(model.checkingCodex || model.testingCodex)
                    Button(model.testingCodex ? "Testing…" : "Test connection") { Task { await model.testCodex() } }.disabled(model.checkingCodex || model.testingCodex)
                }
                description("Check verifies installation and sign-in. Test submits a small invented prompt using your Codex allowance.")
                if let message = model.codexTestMessage { description(message) }
                HStack(alignment: .top, spacing: 24) {
                    field("Model") {
                        Picker("Model", selection: $model.settings.codexModel) {
                            Text("CLI default").tag("")
                            ForEach(model.codexModels) { Text($0.name).tag($0.id) }
                            if !model.settings.codexModel.isEmpty && !model.codexModels.contains(where: { $0.id == model.settings.codexModel }) { Text(model.settings.codexModel).tag(model.settings.codexModel) }
                        }.labelsHidden()
                    }
                    field("Reasoning effort") {
                        Picker("Reasoning effort", selection: $model.settings.codexEffort) {
                            ForEach(model.codexEfforts, id: \.self) { Text($0.isEmpty ? "Model default" : $0.capitalized).tag($0) }
                        }.labelsHidden()
                    }
                }
                field("Model ID", hint: "Optional: enter a model absent from the CLI catalog.") {
                    TextField("CLI default", text: $model.settings.codexModel)
                        .onChange(of: model.settings.codexModel) { _, _ in if !model.codexEfforts.contains(model.settings.codexEffort) { model.settings.codexEffort = "" } }
                }
                description("The same choices apply to meeting summaries, tags, folder context and connection tests. Model access depends on your account.")
                Stepper("Folder context check: \(model.settings.refreshMinutes) minutes", value: $model.settings.refreshMinutes, in: 1...10080)
                Button("Update folder contexts now") { Task { if await model.saveSettings(processPending: false) { await model.updateNow() } } }.disabled(model.working)
            }
            JottieRule()
            JottieSection(title: "Capture") {
                Toggle("Record meetings automatically", isOn: Binding(get: { model.capture.autoRecord }, set: { _ in model.onAutoRecord?() })).toggleStyle(.switch).disabled(model.onAutoRecord == nil)
                Toggle("Show live transcript while recording", isOn: Binding(get: { model.capture.liveEnabled }, set: { model.onLive?($0) })).toggleStyle(.switch).disabled(model.onLive == nil)
                description(model.capture.autoDecision ?? "Audio is temporary and deleted after durable local transcription. Failed sessions keep their audio for recovery.")
                Button("Recording and permission settings…") { model.onCaptureSettings?() }.disabled(model.onCaptureSettings == nil)
            }
            JottieSection(title: "Appearance") {
                Picker("Theme", selection: $model.appearance) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }.frame(maxWidth: 300)
            }
        }
    }
    private var calendars: some View {
        JottieSection(title: "Calendar context", icon: "calendar") {
            description("Choose calendars for meeting titles and speaker context. Attendees are identity candidates, not confirmed speakers. Calendar-triggered recording is configured separately in Recording settings.")
            Button("Load calendars / request access") {
                Task { do { model.calendars = try await EventKitCalendars().choices() } catch { model.message = error.localizedDescription } }
            }
            ForEach(model.calendars) { choice in
                Toggle(choice.title, isOn: Binding(get: { model.settings.selectedCalendarIDs.contains(choice.id) }, set: { selected in
                    model.settings.selectedCalendarIDs.removeAll { $0 == choice.id }; if selected { model.settings.selectedCalendarIDs.append(choice.id) }
                })).toggleStyle(.checkbox).padding(.vertical, 4)
            }
            description("Changes apply to future recordings. Relaunch after enabling calendar integration in Recording settings.")
        }
    }
    private var microsoft: some View {
        JottieSection(title: "SharePoint and OneDrive", icon: "cloud") {
            description("Register Jottie as a public macOS client in your Microsoft tenant. Tokens stay in the Microsoft Keychain cache. Publishing requires explicit folder and destination configuration.")
            field("Application (client) ID") { TextField("Client UUID", text: $model.settings.microsoftClientID) }
            field("Tenant ID") { TextField("Tenant UUID", text: $model.settings.microsoftTenantID) }
            Text("Redirect URI: msauth.com.gravyraveydavey.jottie://auth").font(JottieStyle.mono(11)).textSelection(.enabled)
            Button("Save and sign into Microsoft…") { Task { if await model.saveSettings() { await model.signIn() } } }
            description(model.accountID.isEmpty ? "Sign in, then edit a folder to choose its publication destination." : "Connected. Folder destinations can now be selected.")
            description("Publishing is one-way. Remote revisions remain after local moves or deletion. Audio is never published.")
        }
    }
    private var mcp: some View {
        JottieSection(title: "Assistant access", icon: "link") {
            description("One local connection exposes read-only meeting search, transcripts and folder context. Retrieval works without the GUI or Codex sign-in.")
            VStack(spacing: 0) {
                mcpRow("Name", "Jottie")
                mcpRow("Description", "Search local meeting summaries, transcripts and folder knowledge")
                mcpRow("Connection", "Local command · stdio")
                mcpRow("Server URL / Tunnel", "Not used by this local service")
                mcpRow("Authentication", "None · your macOS account controls access")
            }.overlay { RoundedRectangle(cornerRadius: 10).stroke(JottieStyle.border, lineWidth: 1) }
            description("If Codex's connection window only offers Server URL or Tunnel, paste the copied configuration into Codex Settings → Configuration → config.toml. Jottie does not expose an HTTP endpoint or create a tunnel.")
            Button { model.copyMCPConfig() } label: { Label("Copy Codex MCP configuration", systemImage: "square.on.square") }
        }
    }
    private func mcpRow(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) { Text(label).font(JottieStyle.font(12, .medium)).frame(width: 155, alignment: .leading); Text(value).font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.padding(14)
            JottieRule()
        }
    }
    private func field<Content: View>(_ title: String, hint: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(JottieStyle.font(13, .medium))
            content()
            if let hint { description(hint) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func description(_ text: String) -> some View { Text(text).font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted).lineSpacing(6).fixedSize(horizontal: false, vertical: true) }
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
            .font(JottieStyle.font()).foregroundStyle(JottieStyle.foreground).background(JottieStyle.background)
            .textFieldStyle(JottieInputStyle()).buttonStyle(JottieButtonStyle(kind: .outline))
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

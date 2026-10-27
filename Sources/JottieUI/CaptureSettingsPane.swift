import SwiftUI

/// UI-only contracts; the executable adapts the existing capture configuration and permissions.
public struct CaptureSetting: Identifiable, Equatable {
    public enum Kind: Equatable { case toggle, choice([String]), text, multiline, number, list }
    public var id: String
    public var title: String
    public var help: String
    public var kind: Kind
    public var value: String
    public var placeholder: String
    public var restart: Bool
    public init(id: String, title: String, help: String, kind: Kind, value: String, placeholder: String, restart: Bool) {
        self.id = id; self.title = title; self.help = help; self.kind = kind; self.value = value; self.placeholder = placeholder; self.restart = restart
    }
}
public struct CaptureSettingsSection: Identifiable {
    public var id: String { title }
    public var title: String
    public var fields: [CaptureSetting]
    public init(title: String, fields: [CaptureSetting]) { self.title = title; self.fields = fields }
}
public struct CaptureSettingsAction: Identifiable {
    public var id: String
    public var title: String
    public var status: String
    public init(id: String, title: String, status: String) { self.id = id; self.title = title; self.status = status }
}
public struct CaptureModelItem: Identifiable {
    public var id: String
    public var title: String
    public var status: String
    public var installed: Bool
    public init(id: String, title: String, status: String, installed: Bool) { self.id = id; self.title = title; self.status = status; self.installed = installed }
}
@MainActor public final class CaptureSettingsController: ObservableObject {
    @Published public var sections: [CaptureSettingsSection] = []
    @Published public var actions: [CaptureSettingsAction] = []
    @Published public var models: [CaptureModelItem] = []
    @Published public var message: String?
    @Published public var busy = false
    public var refresh: () -> Void = {}
    public var commit: (String, String) -> Bool = { _, _ in false }
    public var perform: (String) async -> Void = { _ in }
    public init() {}
}
@MainActor struct CaptureSettingsPane: View {
    @ObservedObject var controller: CaptureSettingsController
    @ViewState private var deleting: CaptureModelItem?
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            JottieSection(title: "Permissions and startup", icon: "lock.shield") {
                ForEach(controller.actions) { action in
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(action.title).font(JottieStyle.font(13, .medium))
                            Text(action.status).font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted)
                        }
                        Spacer()
                        Button(action.id == "audio" ? "Play test tone" : action.id == "login" ? "Enable" : action.id == "unlogin" ? "Disable" : "Manage access") {
                            Task { await controller.perform(action.id) }
                        }.disabled(controller.busy)
                    }.padding(.vertical, 5)
                }
                if let message = controller.message { Text(message).font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted).textSelection(.enabled) }
            }
            if !controller.models.isEmpty {
                JottieSection(title: "Local speech models", icon: "internaldrive") {
                    ForEach(controller.models) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.title).font(JottieStyle.font(13, .medium))
                                Text(item.status).font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted)
                            }
                            Spacer()
                            Button("Download / repair") { Task { await controller.perform("download:" + item.id) } }.disabled(controller.busy)
                            if item.installed {
                                Button { deleting = item } label: { Image(systemName: "trash") }.disabled(controller.busy)
                                    .help("Delete \(item.title) and disable features that require it").accessibilityLabel("Delete \(item.title)")
                            }
                        }.padding(.vertical, 6)
                    }
                    if controller.busy { ProgressView().controlSize(.small) }
                }
            }
            ForEach(controller.sections) { section in
                JottieSection(title: section.title) {
                    ForEach(section.fields) { field in CaptureSettingRow(field: field, controller: controller).id(field.id) }
                }
                JottieRule()
            }
            Button { Task { await controller.perform("choose-folder") } } label: { Label("Choose capture folder…", systemImage: "folder") }
            Button { Task { await controller.perform("reveal") } } label: { Label("Reveal capture configuration", systemImage: "doc.text") }
            Text("Capture controls save individually and apply immediately unless marked ‘Restart required’. Audio is removed after successful transcription; only local transcription engines are available.")
                .font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted)
        }.onAppear { controller.refresh() }
            .alert(item: $deleting) { item in
                Alert(title: Text("Delete \(item.title)?"), message: Text("The model files will be removed. Transcription or live features using this model will be disabled so it is not downloaded again automatically."),
                      primaryButton: .destructive(Text("Delete")) { Task { await controller.perform("delete:" + item.id) } }, secondaryButton: .cancel())
            }
    }
}
@MainActor private struct CaptureSettingRow: View {
    let field: CaptureSetting
    @ObservedObject var controller: CaptureSettingsController
    @ViewState private var draft = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(field.title).font(JottieStyle.font(13, .medium))
                if field.restart { JottieBadge(text: "Restart required") }
                Spacer()
                if field.kind == .toggle {
                    Toggle(field.title, isOn: Binding(get: { field.value == "true" }, set: { _ = controller.commit(field.id, $0 ? "true" : "false") }))
                        .labelsHidden().toggleStyle(.switch).disabled(controller.busy)
                }
            }
            if case .choice(let choices) = field.kind {
                Picker(field.title, selection: Binding(get: { field.value }, set: { _ = controller.commit(field.id, $0) })) {
                    ForEach(choices, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(maxWidth: 350).disabled(controller.busy)
            } else if field.kind != .toggle {
                HStack(alignment: .top) {
                    if field.kind == .multiline { TextEditor(text: $draft).frame(height: 100).font(JottieStyle.font(13)) }
                    else { TextField(field.placeholder, text: $draft).onSubmit { _ = controller.commit(field.id, draft) } }
                    Button("Apply") { _ = controller.commit(field.id, draft) }.disabled(draft == field.value || controller.busy)
                }
            }
            Text(field.help).font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 9)
            .onAppear { draft = field.value }.onChange(of: field.value) { _, value in draft = value }
    }
}

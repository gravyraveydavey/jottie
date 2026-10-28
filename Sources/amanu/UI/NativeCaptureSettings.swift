import AppKit
import FluidAudio
import Foundation
import JottieUI

/// Adapts the inherited settings schema into the main window's native components.
/// Config.update still drives SettingsApplier, so all existing live side effects are shared.
@MainActor final class NativeCaptureSettings {
    let controller = CaptureSettingsController()
    private var watch: ConfigWatch.Token?
    private let isBusy: () -> Bool
    private var models: [ModelStorage.Model] = []
    private var calendarGrant: SetupPermissions.State?
    init(isBusy: @escaping () -> Bool) {
        self.isBusy = isBusy
        controller.refresh = { [weak self] in self?.refresh() }
        controller.commit = { [weak self] id, value in self?.commit(id, value) ?? false }
        controller.perform = { [weak self] id in await self?.perform(id) }
        watch = ConfigWatch.observe { [weak self] in self?.refresh() }
        refresh()
    }
    static func supported(_ entry: SettingsSchema.Entry) -> Bool {
        let key = entry.path.joined(separator: ".")
        // Replaced by native Codex settings, or deliberately disabled by Jottie's privacy policy.
        return !key.hasPrefix("summary.") && !key.hasPrefix("transcription.assemblyai.") && !key.hasPrefix("transcription.openai.")
            && !key.hasPrefix("transcription.elevenlabs.") && !["transcription.cloud", "transcription.local_engine", "keep_audio", "analytics", "speaker_names.backend", "speaker_names.model"].contains(key)
    }
    private func rawValue(_ entry: SettingsSchema.Entry) -> Any? {
        var value: Any = Config.raw()
        for key in entry.path { guard let next = (value as? [String: Any])?[key] else { return nil }; value = next }
        return value
    }
    func refresh() {
        controller.sections = SettingsSchema.sections.compactMap { section in
            let fields: [CaptureSetting] = section.entries.filter(Self.supported).map { entry in
                var kind: CaptureSetting.Kind
                switch entry.kind {
                case .toggle: kind = .toggle
                case .choice(let choices): kind = .choice(choices)
                case .number: kind = .number
                case .list: kind = .list
                case .multilineText: kind = .multiline
                case .text: kind = .text
                }
                let key = entry.path.joined(separator: ".")
                var value = rawValue(entry) ?? (entry.hasValueDefault ? entry.defaultValue : "")
                var help = entry.help
                if key == "recordings_dir" {
                    value = Config.resolveRoot(cliOverride: nil).path
                    help = "Temporary capture and recovery files. The meeting library remains in Application Support/Jottie; changing this folder does not move existing captures."
                }
                if key == "transcription.engine" || key == "transcription.local_engine" {
                    kind = .choice(Config.localEngines.sorted()); value = key == "transcription.engine" ? Config.transcriptionEngine() : Config.transcriptionLocalEngine()
                    help = "Local speech recognition on this Mac. No cloud fallback."
                }
                let text: String
                if case .toggle = kind { text = (value as? Bool == true) ? "true" : "false" }
                else if let array = value as? [String] { text = array.joined(separator: ", ") }
                else { text = String(describing: value) }
                return CaptureSetting(id: key, title: entry.label, help: help, kind: kind, value: text,
                    placeholder: SettingsSchema.describeDefault(entry), restart: entry.needsRestart)
            }
            return fields.isEmpty ? nil : CaptureSettingsSection(title: section.title, fields: fields)
        }
        let login = LoginItem.status()
        controller.actions = [
            CaptureSettingsAction(id: login == .enabled ? "unlogin" : "login", title: "Start at login", status: login == .enabled ? "Enabled" : login == .needsApproval ? "Waiting for approval in macOS Login Items" : login == .unavailable ? "Available in the installed application" : "Off"),
            CaptureSettingsAction(id: "microphone", title: "Microphone", status: permissionLabel(SetupPermissions.microphone())),
            CaptureSettingsAction(id: "audio", title: "System audio", status: SetupPermissions.rememberedSystemAudio(heardAt: SetupState.systemAudioHeardAt()) == .heard ? "Verified by a successful tone test" : "Test plays a short tone through your speakers"),
            CaptureSettingsAction(id: "calendar", title: "Calendar access", status: permissionLabel(calendarGrant ?? SetupPermissions.calendar()))
        ]
        models = Platform.supportsLocalModels ? ModelStorage().all() : []
        controller.models = models.map { model in
            CaptureModelItem(id: model.directory.path, title: model.name,
                status: model.isDownloaded ? "\(ByteCountFormatter.string(fromByteCount: Int64(model.bytes), countStyle: .file)) on disk" : "Not downloaded · About \(ByteCountFormatter.string(fromByteCount: Int64(model.advertisedBytes), countStyle: .file))", installed: model.isDownloaded)
        }
        if Platform.supportsLocalModels {
            let speakers = LocalSpeakerModels()
            controller.models.append(CaptureModelItem(id: "local-speakers", title: "Local speaker separation",
                status: speakers.isReady ? "Downloaded · Separates microphone, remote and imported voices" : "Not downloaded · Required to distinguish voices sharing an audio track", installed: speakers.isReady))
        }
    }
    private func permissionLabel(_ state: SetupPermissions.State) -> String {
        switch state {
        case .granted: return "Allowed"
        case .denied: return "Not allowed · Manage access in System Settings"
        case .notAsked: return "Access not requested yet"
        case .unknown: return "Access has not been verified"
        }
    }
    private func commit(_ id: String, _ value: String) -> Bool {
        guard let entry = SettingsSchema.everyEntry.first(where: { $0.path.joined(separator: ".") == id }), Self.supported(entry) else { return false }
        if id == "transcription.engine" || id == "transcription.local_engine" {
            guard Config.localEngines.contains(value) else { return false }
            let saved = Config.update(path: ["transcription", "engine"], value: value) && Config.update(path: ["transcription", "local_engine"], value: value)
            controller.message = saved ? "Local engine saved." : "Could not save capture configuration."
            refresh(); return saved
        }
        let input: SettingsSchema.Input
        switch entry.kind {
        case .toggle: input = .flag(value == "true")
        case .choice: input = .choice(value)
        default: input = .text(value)
        }
        let resolution = SettingsSchema.resolve(input, for: entry)
        let saved: Bool
        switch resolution {
        case .invalid: controller.message = "Enter a valid value for \(entry.label)."; return false
        case .clear: saved = Config.update(path: entry.path, value: nil)
        case .set(let value): saved = Config.update(path: entry.path, value: value)
        }
        controller.message = saved ? (entry.needsRestart ? "Saved. Restart Jottie to apply \(entry.label)." : "Saved \(entry.label).") : "Could not save capture configuration."
        refresh(); return saved
    }
    private func perform(_ id: String) async {
        guard !controller.busy else { return }
        if isBusy(), id == "audio" || id == "login" || id == "unlogin" || id.hasPrefix("delete:") || id.hasPrefix("download:") {
            controller.message = "Stop recording and wait for transcription to finish before this action."; return
        }
        controller.busy = true; defer { controller.busy = false; refresh() }
        do {
            switch id {
            case "login": if try LoginItem.register() == .needsApproval { LoginItem.openSettings() }
            case "unlogin": _ = try LoginItem.unregister()
            case "microphone": if await SetupPermissions.requestMicrophone() == .denied { SetupPermissions.openSettings(.microphone) }
            case "calendar":
                let result = await SetupPermissions.requestCalendar(); calendarGrant = result
                if result == .denied { SetupPermissions.openSettings(.calendar) }
                else if result == .granted { controller.message = "Calendar access allowed. Select calendars in Integrations and relaunch Jottie to enable capture context." }
            case "audio":
                let result = await SetupPermissions.testSystemAudio()
                if result == .heard { SetupState.rememberSystemAudioHeard(); controller.message = "System audio test succeeded." }
                else { controller.message = "No test tone was captured. Check System Audio Recording permissions, then retry."; SetupPermissions.openSettings(.systemAudio) }
            case "choose-folder":
                let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
                panel.message = "Choose a temporary capture folder outside any publishing destination. The meeting library stays in Application Support/Jottie."
                if panel.runModal() == .OK, let url = panel.url { _ = commit("recordings_dir", url.path) }
            case "reveal": NSWorkspace.shared.activateFileViewerSelecting([Config.path])
            default:
                let deleting = id.hasPrefix("delete:")
                let path = String(id.dropFirst(deleting ? 7 : 9))
                if path == "local-speakers" {
                    let models = LocalSpeakerModels()
                    if deleting {
                        if FileManager.default.fileExists(atPath: models.root.path) { try FileManager.default.removeItem(at: models.root) }
                        Config.update(path: ["transcription", "separate_speakers"], value: false)
                        controller.message = "Deleted speaker models and disabled separation."
                    } else {
                        controller.message = "Downloading and validating local speaker models…"
                        try await models.download()
                        Config.update(path: ["transcription", "separate_speakers"], value: true)
                        controller.message = "Local speaker separation is ready and enabled for future transcription."
                    }
                    return
                }
                guard let model = models.first(where: { $0.directory.path == path }) else { return }
                if deleting {
                    let choice = TranscriptionChoice.read(engine: Config.transcriptionEngine(), cloudProvider: Config.transcriptionCloudProvider(), enabled: Config.transcriptionEnabled(), localModels: Platform.supportsLocalModels, localEngine: Config.transcriptionLocalEngine())
                    let updates = ModelStorage.updatesAfterDeleting(model.kind, choice: choice, liveEnabled: Config.liveTranscriptionEnabled())
                    try ModelStorage().delete(model)
                    for update in updates { Config.update(path: update.path, value: update.value) }
                    controller.message = "Deleted \(model.name). Features requiring this model were disabled."
                } else {
                    controller.message = "Downloading \(model.name)…"
                    switch model.kind {
                    case .parakeet: _ = try await AsrModels.downloadAndLoad(version: model.name.hasSuffix("v2") ? .v2 : .v3)
                    case .whisper: _ = try await WhisperModelStore().download()
                    case .gigaAM: _ = try await GigaAMModelStore().download()
                    case .live: _ = try await LiveTranscriptionModelStore().download(language: LiveTranscriptionLanguage.prompt(for: Config.transcriptionLanguage()))
                    }
                    controller.message = "\(model.name) is ready."
                }
            }
        } catch { controller.message = error.localizedDescription }
    }
}

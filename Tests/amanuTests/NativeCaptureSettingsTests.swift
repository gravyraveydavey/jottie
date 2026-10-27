import Foundation
import Testing
@testable import amanu

@Suite(.serialized) @MainActor struct NativeCaptureSettingsTests {
    @Test(.freshHome) func allActiveSchemaFieldsHaveNativeControlsAndWritesReachRuntime() throws {
        let adapter = NativeCaptureSettings(isBusy: { false })
        let fields = adapter.controller.sections.flatMap(\.fields)
        let expected = SettingsSchema.sections.flatMap(\.entries).filter(NativeCaptureSettings.supported).map { $0.path.joined(separator: ".") }
        #expect(Set(fields.map(\.id)) == Set(expected))
        #expect(fields.contains { $0.id == "recordings_dir" })
        #expect(fields.contains { $0.id == "auto_record.stop_delay_seconds" })
        #expect(!fields.contains { $0.id == "keep_audio" || $0.id == "analytics" || $0.id.hasPrefix("summary.") || $0.id.contains("api_key") })
        var changes: [SettingsApplier.Change] = []
        let applier = SettingsApplier(apply: { changes.append($0) })
        #expect(adapter.controller.commit("menu_bar_icon", "false"))
        #expect(changes.contains(.icons))
        #expect(adapter.controller.commit("auto_record.stop_delay_seconds", "28"))
        #expect((Config.raw()["auto_record"] as? [String: Any])?["stop_delay_seconds"] as? Int == 28)
        #expect(!adapter.controller.commit("auto_record.stop_delay_seconds", "not a number"))
        #expect(!adapter.controller.commit("summary.backend", "openai-api"))
        #expect(!adapter.controller.commit("transcription.engine", "openai"))
        #expect(adapter.controller.commit("transcription.engine", "whisper"))
        #expect(Config.transcriptionEngine() == "whisper")
        withExtendedLifetime(applier) {}
    }
    @Test(.freshHome) func destructiveModelActionsAndToneTestRefuseActiveCapture() async {
        let adapter = NativeCaptureSettings(isBusy: { true })
        await adapter.controller.perform("audio")
        #expect(adapter.controller.message?.contains("Stop recording") == true)
        await adapter.controller.perform("download:unused")
        #expect(adapter.controller.message?.contains("Stop recording") == true)
    }
}

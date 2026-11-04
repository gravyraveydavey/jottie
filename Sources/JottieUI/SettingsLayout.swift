import Foundation

/// Route by configuration key, independent of translated schema section titles.
enum CaptureSettingsArea {
    case general, recording, transcription, calendar

    static func area(for key: String) -> Self {
        if key == "calendar" || key == "auto_record.calendar" { return .calendar }
        if ["user_name", "interface_language", "dock_icon", "menu_bar_icon", "window", "on_stop"].contains(key) { return .general }
        if key.hasPrefix("transcription.") || key.hasPrefix("live_transcription.") || key == "transcript_echo_filter" || key.hasPrefix("speaker_names.") { return .transcription }
        return .recording
    }

    static func isAdvanced(_ key: String) -> Bool {
        if key.hasPrefix("auto_record.") {
            return !["auto_record.enabled", "auto_record.mic_activity", "auto_record.calendar"].contains(key)
        }
        return ["on_stop", "recordings_dir", "mic_voice_processing", "transcript_echo_filter"].contains(key)
            || key.hasPrefix("transcription.whisper.") || key.hasPrefix("transcription.parakeet.")
    }

    func includesAction(_ key: String) -> Bool {
        switch self {
        case .general: return key == "login" || key == "unlogin"
        case .recording: return key == "microphone" || key == "audio"
        case .calendar: return key == "calendar"
        case .transcription: return false
        }
    }
}

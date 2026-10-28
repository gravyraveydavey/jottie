import Foundation
import JottieUI

/// Read only session metadata, never whole transcripts on the UI thread.
enum CaptureQueueSnapshot {
    static func sessions(in root: URL) -> [URL] {
        SessionInventory.sessionFolders(in: root).filter { dir in
            (!FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path)
                || TranscriptVersions.isRequested(dir))
                && !FileManager.default.fileExists(atPath: dir.appendingPathComponent(".recording.json").path)
        }
    }
    static func retryableSessions(in root: URL) -> [URL] {
        sessions(in: root).filter { !SessionClaim.isHeld($0) && PostProcessor.obstacleToTranscribing($0) == nil }
    }
    static func items(in root: URL) -> [CaptureQueueItem] {
        sessions(in: root).compactMap { dir in
            guard let meta = SessionState.read(dir) else { return nil }
            let failed = meta[SessionState.Key.transcriptionFailed] as? String
            let state = SessionClaim.isHeld(dir) ? "Processing" : failed != nil ? "Failed"
                : !Config.transcriptionEnabled() ? "Disabled"
                : meta[SessionState.Key.transcriptionDeferred] as? Bool == true ? "Deferred" : "Queued"
            return CaptureQueueItem(id: dir.path, title: meta["title"] as? String ?? dir.lastPathComponent,
                state: state, detail: failed ?? (state == "Deferred" ? "Audio retained. Check recording settings and transcribe.log, then retry."
                    : state == "Disabled" ? "Enable transcription under Settings → Recording to process this file."
                    : "Local transcription and speaker separation; audio is retained until the transcript is saved."))
        }
    }
}

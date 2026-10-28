import Foundation
import Testing
@testable import amanu

@Suite(.serialized) struct CaptureQueueSnapshotTests {
    @Test(.freshHome) func queueIncludesPendingAndFailedButNotCompletedOrActiveRecordings() throws {
        let root = Home.current.url.appendingPathComponent("Capture")
        func session(_ name: String, extra: [String: Any] = [:]) throws -> URL {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let fields = ["title": name, "files": ["source": "source.m4a"]] as [String: Any]
            try JSONSerialization.data(withJSONObject: fields.merging(extra) { _, value in value }).write(to: dir.appendingPathComponent("meta.json"))
            return dir
        }
        _ = try session("pending")
        _ = try session("failed", extra: ["transcription_failed": "Synthetic decode failure"])
        let done = try session("done")
        try Data("{}".utf8).write(to: done.appendingPathComponent("transcript.json"))
        let active = try session("active")
        try Data("{}".utf8).write(to: active.appendingPathComponent(".recording.json"))
        let items = CaptureQueueSnapshot.items(in: root)
        #expect(items.map(\.title) == ["failed", "pending"])
        #expect(items.first?.state == "Failed")
        #expect(items.first?.detail == "Synthetic decode failure")
        #expect(CaptureQueueSnapshot.retryableSessions(in: root).isEmpty) // no audio: cannot retry
    }
}

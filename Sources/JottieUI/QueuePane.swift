import SwiftUI
import JottieModels
import JottieLibrary

@MainActor struct QueuePane: View {
    @ObservedObject var model: LibraryViewModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "checklist").font(.system(size: 24)).foregroundStyle(JottieStyle.accent)
                        Text("Queue").font(JottieStyle.font(30, .semibold)).tracking(-0.7)
                        Text("A little visibility into what’s being worked on.").foregroundStyle(JottieStyle.muted)
                    }
                    Spacer()
                    Button { Task { await model.updateNow() } } label: {
                        Label(model.working ? "Processing" : "Process queue", systemImage: "play")
                    }.buttonStyle(JottieButtonStyle(kind: .primary)).disabled(model.working || model.cleanupProcessingID != nil || model.jobs.contains { $0.isTranscriptCleanup && $0.state == "running" } || model.jobs.isEmpty)
                }
                if model.progress.total > 0 || !model.jobs.isEmpty {
                  VStack(alignment: .leading, spacing: 12) {
                    Text("Transcript cleanup, summaries & knowledge").font(JottieStyle.font(17, .semibold))
                    HStack {
                        Text(model.progress.label)
                        Spacer()
                        JottieBadge(text: "\(model.jobs.count) pending", outlined: true)
                    }.font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted)
                    ProgressView(value: Double(model.progress.completed), total: Double(max(1, model.progress.total))).tint(JottieStyle.accent)
                  }
                }
                if let importing = model.capture.mediaImport {
                    HStack { ProgressView().controlSize(.small); Text(importing) }
                        .font(JottieStyle.font(13)).foregroundStyle(JottieStyle.muted)
                }
                if let result = model.capture.importResult {
                    Text(result).font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted).textSelection(.enabled)
                }
                if !model.capture.transcriptionItems.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Transcription & speaker separation").font(JottieStyle.font(17, .semibold))
                            Spacer()
                            Button("Retry transcription") { model.onRetryTranscription?() }
                                .buttonStyle(JottieButtonStyle(kind: .outline, compact: true))
                                .disabled(model.onRetryTranscription == nil || model.capture.transcriptionItems.contains { $0.state == "Processing" })
                        }
                        ForEach(model.capture.transcriptionItems) { item in
                            HStack(alignment: .top, spacing: 16) {
                                Image(systemName: "waveform").foregroundStyle(JottieStyle.accent)
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(item.title).font(JottieStyle.font(14, .medium))
                                    Text(item.detail).font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted).textSelection(.enabled)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                JottieBadge(text: item.state, outlined: true)
                            }.padding(16).overlay { RoundedRectangle(cornerRadius: 12).stroke(JottieStyle.border, lineWidth: 1) }
                        }
                    }
                }
                if model.jobs.isEmpty && model.capture.transcriptionItems.isEmpty && model.capture.mediaImport == nil && model.capture.transcription == nil {
                    JottieEmpty(title: "Everything is up to date", message: "Imported recordings, transcription, transcript cleanup, analysis, folder context and publication jobs will appear here.", icon: "checkmark")
                } else if !model.jobs.isEmpty {
                    LazyVStack(spacing: 0) {
                        ForEach(model.jobs) { job in
                            jobRow(job)
                            if job.id != model.jobs.last?.id { JottieRule() }
                        }
                    }.overlay { RoundedRectangle(cornerRadius: 12).stroke(JottieStyle.border, lineWidth: 1) }
                }
                Text("Transcripts are committed before analysis. Deferred jobs retain their last successful result; retry after resolving the reported issue. Nothing here switches to a paid API.")
                    .font(JottieStyle.font(11)).foregroundStyle(JottieStyle.muted).lineSpacing(6)
            }.padding(40).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
        }.background(JottieStyle.background)
    }
    private func jobRow(_ job: WorkStatus) -> some View {
        let id = job.id.split(separator: ":").compactMap { UUID(uuidString: String($0)) }.first
        let meeting = model.meetings.first { $0.id == id }
        let folder = model.folders.first { $0.id == id }
        return HStack(alignment: .top, spacing: 16) {
            Image(systemName: folder == nil ? "doc.text" : "folder").foregroundStyle(JottieStyle.muted)
                .frame(width: 36, height: 36).background(JottieStyle.surface, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 7) {
                Button(meeting?.displayTitle ?? folder?.name ?? job.stage.capitalized) {
                    if let meeting { model.navigate("all"); model.openMeeting(meeting.id) }
                    else if let folder { model.navigate(folder.id.uuidString) }
                }.buttonStyle(.plain).font(JottieStyle.font(14, .medium))
                Text("\(job.stage.capitalized) · Attempt \(job.attempts)").font(JottieStyle.font(11)).foregroundStyle(JottieStyle.muted)
                if let message = job.message { Text(message).font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                if let label = job.sectionProgress {
                    Text(label).font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted)
                    ProgressView(value: Double(job.completedSections ?? 0), total: Double(max(1, job.totalSections ?? 1))).tint(JottieStyle.accent)
                        .accessibilityLabel("Cleanup sections completed")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 6) {
                    if job.state == "running" { ProgressView().controlSize(.small) }
                    JottieBadge(text: job.state == "running" ? "Processing" : job.state.capitalized, outlined: true)
                }
                if job.isTranscriptCleanup, job.state == "running", model.cleanupProcessingID == id {
                    Button("Cancel cleanup") { model.cancelTranscriptCleanup() }.buttonStyle(JottieButtonStyle(kind: .outline, compact: true))
                }
                if job.state != "running" || !job.isTranscriptCleanup {
                    Button(job.isTranscriptCleanup ? "Review cleanup options" : "Retry") { Task { await model.retry(job) } }.buttonStyle(JottieButtonStyle(kind: .outline, compact: true)).disabled(job.state == "running" || model.working)
                }
            }
        }.padding(16)
    }
}

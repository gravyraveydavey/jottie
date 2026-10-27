import SwiftUI
import AppKit
import JottieModels
import JottieLibrary

@MainActor struct FolderDetailPane: View {
    let folder: Folder
    @ObservedObject var model: LibraryViewModel
    private var context: FolderContext? { model.contexts[folder.id] }
    private var members: [Meeting] { model.folderMeetings(folder).sorted { $0.startedAt > $1.startedAt } }
    private var current: Bool {
        context?.inputRevision == LibraryStore.contextFingerprint(folder: folder, folders: model.folders, meetings: model.meetings, settings: model.savedSettings)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Folder overview", systemImage: "folder").font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted)
                Spacer()
                Button { copyContext() } label: { Label("Copy", systemImage: "square.on.square") }
                    .buttonStyle(JottieButtonStyle(compact: true)).disabled(context == nil).help("Copy this folder's current context")
            }.padding(.horizontal, 20).frame(height: 48)
            JottieRule()
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    VStack(alignment: .leading, spacing: 16) {
                        Image(systemName: "folder").font(.system(size: 24)).foregroundStyle(JottieStyle.accent)
                            .frame(width: 44, height: 44).background(JottieStyle.selection, in: RoundedRectangle(cornerRadius: 12))
                        HStack(spacing: 12) { Text(folder.name).font(JottieStyle.font(30, .semibold)).tracking(-0.7); JottieBadge(text: "\(members.count) meetings") }
                        paragraph("The threads, decisions and next steps across this folder.")
                    }
                    HStack {
                        Text(context == nil ? "No context generated yet" : current ? "Summary up to date" : "Changes pending · last successful context")
                            .font(JottieStyle.font(11)).foregroundStyle(current ? JottieStyle.muted : .orange)
                        Spacer()
                        Button { Task { await model.updateNow() } } label: { Label("Update now", systemImage: "arrow.triangle.2.circlepath") }
                            .buttonStyle(JottieButtonStyle(kind: .outline, compact: true)).disabled(model.working)
                            .help("Refresh folder context from structured meeting summaries")
                    }
                    if members.isEmpty {
                        JottieEmpty(title: "No conversations here yet", message: "Move meetings into this folder or its subfolders to build a shared context.", icon: "folder")
                    } else if let context {
                        JottieSection(title: "Context") { paragraph(context.overview) }
                        JottieSection(title: "Latest updates") {
                            ForEach(members.prefix(3)) { meeting in
                                HStack(alignment: .top, spacing: 16) {
                                    Rectangle().fill(JottieStyle.accent.opacity(0.2)).frame(width: 2)
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(meeting.startedAt.formatted(.dateTime.day().month(.abbreviated).year())).font(JottieStyle.font(11)).foregroundStyle(JottieStyle.muted)
                                        Button { model.openMeeting(meeting.id) } label: { Label(meeting.displayTitle, systemImage: "arrow.up.right").font(JottieStyle.font(14, .medium)) }.buttonStyle(.plain).help("Open source meeting")
                                        paragraph(meeting.analysis?.analysis.summary ?? meeting.importedSummary ?? "Awaiting summary")
                                    }
                                }.fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        JottieRule()
                        entries("To-do", icon: "checklist", items: context.actions.filter { $0.status != "completed" })
                        entries("Decisions", icon: "checkmark", items: context.decisions)
                        entries("Open questions", icon: "questionmark.bubble", items: context.questions.filter { $0.status != "resolved" })
                        entries("Recent changes", icon: "clock.arrow.circlepath", items: context.recentChanges)
                        JottieSection(title: "Source meetings", icon: "link") {
                            ForEach(Array(Set(context.sources.map(\.meetingID))).sorted { $0.uuidString < $1.uuidString }, id: \.self) { id in sourceButton(id) }
                        }
                        Text("Updated \(context.generatedAt.formatted()) · Checks every \(model.settings.refreshMinutes) minutes while Jottie is running.")
                            .font(JottieStyle.font(11)).foregroundStyle(JottieStyle.muted)
                    } else {
                        JottieEmpty(title: "This folder is ready for a summary", message: "Analyse its meetings first, then update this context. Only meeting summaries are used.", icon: "sparkles")
                    }
                }.padding(.horizontal, 48).padding(.vertical, 44).frame(maxWidth: 768, alignment: .leading).frame(maxWidth: .infinity)
            }
        }.background(JottieStyle.background)
    }
    private func paragraph(_ value: String) -> some View {
        Text(value).font(JottieStyle.font(14)).foregroundStyle(JottieStyle.muted).lineSpacing(9).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
    private func entries(_ title: String, icon: String, items: [ContextEntry]) -> some View {
        JottieSection(title: title, icon: icon, count: title == "To-do" ? items.count : nil) {
            if items.isEmpty { paragraph("None recorded.") }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 8) {
                    paragraph(item.text)
                    Text(([item.status.replacingOccurrences(of: "_", with: " "), item.owner, item.dueDate].compactMap { $0 }).joined(separator: " · "))
                        .font(JottieStyle.font(11)).foregroundStyle(JottieStyle.muted)
                    ForEach(Array(Set(item.sources.map(\.meetingID))).sorted { $0.uuidString < $1.uuidString }, id: \.self) { id in sourceButton(id) }
                }
            }
        }
    }
    private func sourceButton(_ id: UUID) -> some View {
        Button { model.openMeeting(id) } label: { Label(model.meetings.first { $0.id == id }?.displayTitle ?? id.uuidString, systemImage: "arrow.up.right") }
            .buttonStyle(.plain).font(JottieStyle.font(11)).foregroundStyle(JottieStyle.accent).help("Open source meeting")
    }
    private func copyContext() {
        guard let context else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(context.markdown, forType: .string)
        model.message = "Folder context copied."
    }
}

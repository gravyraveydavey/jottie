import SwiftUI
import JottieModels

@MainActor struct TrashPane: View {
    @ObservedObject var model: LibraryViewModel
    @ViewState private var confirmingEmpty = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Trash").font(JottieStyle.font(28, .semibold))
                    Text("Meetings stay here for 48 hours. Expired items are deleted when Jottie is running. Published copies are retained.")
                        .font(JottieStyle.font(13)).foregroundStyle(JottieStyle.muted)
                }
                Spacer()
                Button { confirmingEmpty = true } label: { Label("Empty Trash", systemImage: "trash") }
                    .buttonStyle(JottieButtonStyle(kind: .outline)).disabled(model.trash.isEmpty)
                    .help("Permanently delete all meetings in Jottie Trash")
            }.padding(28)
            JottieRule()
            if model.trash.isEmpty {
                JottieEmpty(title: "Trash is empty", message: "Meetings you move to Trash will appear here.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.trash) { item in
                            HStack(spacing: 16) {
                                Image(systemName: "doc.text").foregroundStyle(JottieStyle.muted)
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(item.meeting.displayTitle).font(JottieStyle.font(14, .medium))
                                    Text("Deletes \(item.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted)
                                }
                                Spacer()
                                Button { Task { await model.restoreTrash(item) } } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                                    .buttonStyle(JottieButtonStyle(kind: .outline))
                            }.padding(22)
                            JottieRule()
                        }
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(JottieStyle.background)
            .alert("Permanently empty Jottie Trash?", isPresented: $confirmingEmpty) {
                Button("Empty Trash", role: .destructive) { Task { await model.emptyTrash() } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This deletes \(model.trash.count) local meeting bundles, including their transcripts and analysis history. This cannot be undone. Published copies remain.") }
    }
}

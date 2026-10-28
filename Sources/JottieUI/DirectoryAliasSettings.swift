import SwiftUI
import JottieModels

@MainActor struct DirectoryAliasSettings: View {
    @ObservedObject var model: LibraryViewModel
    @ViewState private var query = ""
    @ViewState private var selected = ""
    @ViewState private var aliases = ""
    private var person: DirectoryPerson? { model.directoryPeople.first { $0.id == selected } }
    var body: some View {
        if !model.directoryPeople.isEmpty {
            JottieSection(title: "Name aliases", icon: "person.text.rectangle") {
                Text("Nicknames and spelling variants help reconcile invitations and transcript names. Shared aliases stay ambiguous; a mention alone does not establish attendance.")
                    .font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted)
                TextField("Find a directory person…", text: $query).textFieldStyle(JottieInputStyle())
                if !query.isEmpty {
                    ForEach(Array(model.directoryPeople.filter { person in NameAliases.all(name: person.name, aliases: person.aliases).contains { NameAliases.normalise($0).contains(NameAliases.normalise(query)) } }.prefix(8))) { item in
                        Button(item.name + (item.jobTitle.map { " · " + $0 } ?? "")) {
                            selected = item.id; aliases = (item.aliases ?? []).joined(separator: ", "); query = ""
                        }.buttonStyle(.plain).foregroundStyle(JottieStyle.accent)
                    }
                }
                if let person {
                    Text(person.name).font(JottieStyle.font(14, .semibold))
                    Text("Suggested: " + NameAliases.generated(for: person.name).joined(separator: ", "))
                        .font(JottieStyle.font(12)).foregroundStyle(JottieStyle.muted)
                    TextField("Additional aliases, separated by commas", text: $aliases).textFieldStyle(JottieInputStyle())
                    Button("Save aliases") { Task { await model.saveAliases(aliases, for: person) } }
                        .buttonStyle(JottieButtonStyle(kind: .outline, compact: true))
                }
            }.task { await model.loadDirectoryPeople() }
        }
    }
}

import Foundation
import JottieModels

/// Invitation suggestions and directory autocomplete never assign a speaker automatically.
public struct SpeakerChoice: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var jobTitle: String?
    public var employeeID: String?
    public var email: String?

    public static func calendarCandidates(for meeting: Meeting, people: [DirectoryPerson]) -> [SpeakerChoice] {
        let invitees = meeting.calendarContext?.invitees ?? meeting.participants
        let matches = PeopleDirectory.match(invitees, people: people, company: "", syncedAt: Date())
        var seen = Set<String>()
        return invitees.compactMap { invitee in
            let match = matches.first { $0.invitee == invitee }
            let parts = invitee.split(separator: "<", maxSplits: 1).map(String.init)
            let rawName = (parts.first ?? invitee).trimmingCharacters(in: .whitespacesAndNewlines)
            let email = invitee.contains("@") ? (parts.last ?? invitee).replacingOccurrences(of: ">", with: "")
                .replacingOccurrences(of: "mailto:", with: "").trimmingCharacters(in: .whitespacesAndNewlines) : nil
            let name = match?.name ?? (rawName.isEmpty || rawName.contains("@") ? email ?? invitee : rawName)
            let key = match.map { "employee:" + $0.employeeID } ?? "invitee:" + (email?.lowercased() ?? NameAliases.normalise(name))
            guard !name.isEmpty, seen.insert(key).inserted else { return nil }
            return SpeakerChoice(id: key, name: name, jobTitle: match?.jobTitle, employeeID: match?.employeeID,
                email: match?.workEmail ?? email)
        }
    }

    public static func directoryMatches(_ query: String, people: [DirectoryPerson]) -> [SpeakerChoice] {
        let needle = NameAliases.normalise(query)
        guard !needle.isEmpty else { return [] }
        return people.filter { person in
            let values = NameAliases.all(name: person.name, aliases: person.aliases) + [person.workEmail ?? "", person.jobTitle ?? ""]
            return values.contains { NameAliases.normalise($0).contains(needle) }
        }.sorted { lhs, rhs in
            let left = NameAliases.normalise(lhs.name).hasPrefix(needle)
            let right = NameAliases.normalise(rhs.name).hasPrefix(needle)
            if left != right { return left }
            if lhs.name != rhs.name { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
            return lhs.id < rhs.id
        }.map { SpeakerChoice(id: "employee:" + $0.id, name: $0.name, jobTitle: $0.jobTitle,
            employeeID: $0.id, email: $0.workEmail) }
    }
}

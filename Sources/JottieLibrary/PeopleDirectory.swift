import Foundation
import GRDB
import JottieModels

/// Durable cache, deliberately separate from the disposable search projection.
public actor PeopleDirectory {
    private let database: DatabaseQueue
    public init(root: URL) throws {
        try LibraryStore.directory(root)
        database = try DatabaseQueue(path: root.appendingPathComponent("directory.sqlite").path)
        try database.write { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS directory(company TEXT, id TEXT, name TEXT, email TEXT, title TEXT, PRIMARY KEY(company,id)); CREATE TABLE IF NOT EXISTS directory_sync(company TEXT PRIMARY KEY, synced REAL NOT NULL)")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent("directory.sqlite").path)
    }
    public func replace(_ people: [DirectoryPerson], company: String, now: Date = Date()) throws {
        guard Set(people.map(\.id)).count == people.count else { throw JottieError.invalid("BambooHR returned duplicate employee IDs; the previous directory was retained.") }
        try database.write { db in
            // Retain only the explicitly connected company, not old tenant directories.
            try db.execute(sql: "DELETE FROM directory; DELETE FROM directory_sync")
            for person in people {
                try db.execute(sql: "INSERT INTO directory VALUES(?,?,?,?,?)", arguments: [company, person.id, person.name, person.workEmail, person.jobTitle])
            }
            try db.execute(sql: "INSERT INTO directory_sync VALUES(?,?)", arguments: [company, now.timeIntervalSince1970])
        }
    }
    public func clear() throws { try database.write { try $0.execute(sql: "DELETE FROM directory; DELETE FROM directory_sync") } }
    public func snapshot(company: String) throws -> (people: [DirectoryPerson], syncedAt: Date?) {
        try database.read { db in
            let people = try Row.fetchAll(db, sql: "SELECT * FROM directory WHERE company=? ORDER BY name,id", arguments: [company]).map {
                DirectoryPerson(id: $0["id"], name: $0["name"], workEmail: $0["email"], jobTitle: $0["title"])
            }
            let timestamp = try Double.fetchOne(db, sql: "SELECT synced FROM directory_sync WHERE company=?", arguments: [company])
            return (people, timestamp.map(Date.init(timeIntervalSince1970:)))
        }
    }
    public func matching(_ invitees: [String], company: String) throws -> [ParticipantIdentity] {
        let snapshot = try snapshot(company: company)
        guard let synced = snapshot.syncedAt else { return [] }
        return Self.match(invitees, people: snapshot.people, company: company, syncedAt: synced)
    }
    private static func email(_ input: String) -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("mailto:") { value.removeFirst(7) }
        return value.replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func match(_ invitees: [String], people: [DirectoryPerson], company: String, syncedAt: Date) -> [ParticipantIdentity] {
        invitees.compactMap { invitee -> ParticipantIdentity? in
            let value = invitee.trimmingCharacters(in: .whitespacesAndNewlines)
            let email: String? = value.contains("@") ? Self.email(value.split(separator: "<").last.map(String.init) ?? value) : nil
            let name = value.split(separator: "<").first.map(String.init) ?? value
            // An email present on an invite is authoritative for matching; never fall back to a conflicting name.
            let matches = people.filter { person in
                if let email { return person.workEmail.map(Self.email) == email }
                return LibraryStore.normalise(person.name) == LibraryStore.normalise(name)
            }
            guard matches.count == 1, let person = matches.first else { return nil }
            return ParticipantIdentity(invitee: invitee, employeeID: person.id, name: person.name, workEmail: person.workEmail,
                jobTitle: person.jobTitle, company: company, matchedBy: email == nil ? "unique-name" : "email", syncedAt: syncedAt)
        }
    }
}

import Foundation
import SQLite3
import Testing
import JottieModels
import JottieLibrary

@Test func openingExistingDirectoryDoesNotWriteWhileAnotherConnectionReads() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try PeopleDirectory(root: root)
    try await directory.replace([DirectoryPerson(id: "1", name: "Jamie Chen", workEmail: nil, jobTitle: nil)], company: "acme")

    var reader: OpaquePointer?
    try #require(sqlite3_open(root.appendingPathComponent("directory.sqlite").path, &reader) == SQLITE_OK)
    defer { sqlite3_close(reader) }
    try #require(sqlite3_exec(reader, "BEGIN; SELECT * FROM directory", nil, nil, nil) == SQLITE_OK)
    defer { sqlite3_exec(reader, "ROLLBACK", nil, nil, nil) }

    // Reopening an existing schema must be a read. Previously its redundant
    // CREATE TABLE transaction failed at COMMIT against this active reader.
    let reopened = try PeopleDirectory(root: root)
    #expect(try await reopened.snapshot(company: "acme").people.count == 1)
}

@Test func overlappingDirectoryLoadsDoNotFailWhenOpeningSettings() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try PeopleDirectory(root: root)
    let people = [DirectoryPerson(id: "1", name: "Jamie Chen", workEmail: "jamie@example.test", jobTitle: "Designer")]
    try await directory.replace(people, company: "acme")
    try await directory.setAliases(["Jamie"], employeeID: "1", company: "acme")

    // Settings, alias controls and the background refresh open the same cache
    // independently, then read it while the other connections are opening.
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<4 {
            group.addTask {
                for _ in 0..<50 {
                    let connection = try PeopleDirectory(root: root)
                    let snapshot = try await connection.snapshot(company: "acme")
                    #expect(snapshot.people.first?.id == "1")
                    #expect(snapshot.people.first?.aliases == ["Jamie"])
                    #expect(snapshot.syncedAt != nil)
                }
            }
        }
        try await group.waitForAll()
    }
}

@Test func independentDirectoryConnectionsSerializeAliasUpdates() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try PeopleDirectory(root: root)
    let people = (0..<4).map { DirectoryPerson(id: String($0), name: "Test person \($0)", workEmail: nil, jobTitle: nil) }
    try await directory.replace(people, company: "acme")

    try await withThrowingTaskGroup(of: Void.self) { group in
        for person in people {
            group.addTask {
                let connection = try PeopleDirectory(root: root)
                for revision in 0..<25 {
                    try await connection.setAliases(["Alias \(revision)"], employeeID: person.id, company: "acme")
                    #expect(try await connection.snapshot(company: "acme").people.count == people.count)
                }
            }
        }
        try await group.waitForAll()
    }
    let snapshot = try await directory.snapshot(company: "acme")
    #expect(snapshot.people.count == people.count)
    #expect(snapshot.people.allSatisfy { $0.aliases == ["Alias 24"] })
}

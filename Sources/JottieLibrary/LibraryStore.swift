import Foundation
import Darwin
import GRDB
import JottieModels

/// Canonical JSON is committed before its disposable SQLite projection. A process
/// lock also protects CLI/import writers, not just callers of this actor.
public actor LibraryStore: MeetingRepository {
    public nonisolated let root: URL
    private let readOnly: Bool
    private var index: DatabaseQueue?
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Jottie", isDirectory: true)
    }
    public init(root: URL = LibraryStore.defaultRoot, readOnly: Bool = false) throws {
        self.root = root; self.readOnly = readOnly
        if !readOnly {
            try Self.directory(root)
            for name in ["Meetings", "Contexts", "Trash"] { try Self.directory(root.appendingPathComponent(name)) }
        }
        let path = root.appendingPathComponent("search.sqlite").path
        var configuration = Configuration()
        configuration.readonly = readOnly
        if readOnly {
            index = try? DatabaseQueue(path: path, configuration: configuration)
        } else {
            do {
                let queue = try DatabaseQueue(path: path)
                try Self.prepare(queue)
                index = queue
            } catch {
                // Only derived data is discarded. Jobs/receipts live elsewhere.
                for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
                let queue = try DatabaseQueue(path: path)
                try Self.prepare(queue); index = queue
            }
        }
    }
    private static func prepare(_ queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS meeting_search USING fts5(
                    id UNINDEXED, title, transcript, summary, topics, people, tags, tokenize='unicode61');
                CREATE TABLE IF NOT EXISTS meeting_catalog(id TEXT PRIMARY KEY, folderID TEXT, started REAL NOT NULL);
                CREATE INDEX IF NOT EXISTS meeting_folder_date ON meeting_catalog(folderID,started);
                CREATE TABLE IF NOT EXISTS tag_catalog(meetingID TEXT NOT NULL, tag TEXT NOT NULL, PRIMARY KEY(meetingID,tag));
                CREATE INDEX IF NOT EXISTS tag_lookup ON tag_catalog(tag,meetingID);
                CREATE TABLE IF NOT EXISTS action_catalog(id TEXT, meetingID TEXT, text TEXT, status TEXT, owner TEXT, dueDate TEXT);
                CREATE TABLE IF NOT EXISTS folder_catalog(id TEXT PRIMARY KEY, parentID TEXT, name TEXT, aliases TEXT);
                CREATE VIRTUAL TABLE IF NOT EXISTS context_search USING fts5(folderID UNINDEXED, content);
                CREATE TABLE IF NOT EXISTS projection_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
                """)
        }
    }
    public static func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
    public nonisolated func meetingDirectory(_ id: UUID) -> URL {
        root.appendingPathComponent("Meetings").appendingPathComponent(id.uuidString)
    }
    private func read<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
        try Codec.decode(type, from: Data(contentsOf: url))
    }
    private func write<T: Encodable>(_ value: T, _ url: URL) throws {
        try Codec.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func locked<T>(_ work: () throws -> T) throws -> T {
        guard !readOnly else { throw JottieError.invalid("This library connection is read-only.") }
        let descriptor = open(root.appendingPathComponent(".library.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw JottieError.unavailable("Cannot lock the library.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw JottieError.unavailable("Cannot lock the library.") }
        defer { flock(descriptor, LOCK_UN) }
        return try work()
    }
    public func meetings() throws -> [Meeting] {
        let directory = root.appendingPathComponent("Meetings")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]).compactMap { path in
            guard UUID(uuidString: path.lastPathComponent) != nil,
                  FileManager.default.fileExists(atPath: path.appendingPathComponent("meeting.json").path) else { return nil }
            return try read(Meeting.self, path.appendingPathComponent("meeting.json"))
        }.sorted { $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt > $1.startedAt }
    }
    public func meeting(_ id: UUID) throws -> Meeting {
        try read(Meeting.self, meetingDirectory(id).appendingPathComponent("meeting.json"))
    }
    public func folders() throws -> [Folder] {
        let path = root.appendingPathComponent("folders.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        return try read([Folder].self, path)
    }
    public func settings() throws -> LibrarySettings {
        let path = root.appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return LibrarySettings() }
        return try read(LibrarySettings.self, path)
    }
    public func saveSettings(_ settings: LibrarySettings) throws {
        guard (1...10080).contains(settings.refreshMinutes), settings.summaryPrompt.utf8.count <= 100_000,
              !settings.summaryPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              settings.folderContextPrompt.utf8.count <= 100_000,
              !settings.folderContextPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              LibrarySettings.efforts.contains(settings.codexEffort),
              settings.codexModel.isEmpty || settings.codexModel.range(of: "^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$", options: .regularExpression) != nil
        else { throw JottieError.invalid("Use nonempty prompts, a valid model ID and effort, and an interval of 1–10080 minutes.") }
        try locked { try write(settings, root.appendingPathComponent("settings.json")) }
    }
    /// Adopt only an explicit Codex choice from this fork's old capture settings.
    /// A saved library preference (including an explicit opt-out) always wins.
    @discardableResult public func migrateLegacyCodexPreference(backend: String?, enabled: Bool?) throws -> Bool {
        try locked {
            let path = root.appendingPathComponent("settings.json")
            guard !FileManager.default.fileExists(atPath: path.path), backend == "codex-cli", enabled != false else { return false }
            var settings = LibrarySettings()
            settings.analysisEnabled = true
            try write(settings, path)
            return true
        }
    }
    public func save(_ meeting: Meeting) throws {
        try locked { try commit(meeting) }
    }
    private func commit(_ meeting: Meeting) throws {
        var meeting = meeting
        if let revision = meeting.analysis, revision.analysis.tags.count > 10 {
            meeting.analysis = AnalysisRevision(transcriptRevision: revision.transcriptRevision, promptRevision: revision.promptRevision,
                analysis: MeetingTags.applying(to: revision.analysis, existing: []))
        }
        let knownFolders = try folders()
        let transcriptDigest = Codec.hash(try Codec.encode(meeting.segments))
        guard meeting.schemaVersion == 1, Set(meeting.segments.map(\.id)).count == meeting.segments.count,
              meeting.transcriptRevision == transcriptDigest,
              meeting.folderID == nil || knownFolders.contains(where: { $0.id == meeting.folderID })
        else { throw JottieError.invalid("Invalid meeting or folder.") }
        let dir = meetingDirectory(meeting.id)
        try Self.directory(dir)
        let transcriptHistory = dir.appendingPathComponent("TranscriptHistory")
        try Self.directory(transcriptHistory)
        let sourceRevision = transcriptHistory.appendingPathComponent("\(meeting.transcriptRevision).json")
        if !FileManager.default.fileExists(atPath: sourceRevision.path) {
            try write(meeting.segments, sourceRevision)
        }
        if let analysis = meeting.analysis {
            guard analysis.transcriptRevision == meeting.transcriptRevision,
                  analysis.id.count == 64, analysis.id.allSatisfy({ $0.isHexDigit }) else {
                throw JottieError.conflict("Analysis belongs to an earlier transcript.")
            }
            try analysis.analysis.validate(segments: meeting.segments)
            try Self.directory(dir.appendingPathComponent("Analysis"))
            try write(analysis, dir.appendingPathComponent("Analysis/\(analysis.id).json"))
        }
        if let assignments = meeting.speakerAttributions {
            let history = dir.appendingPathComponent("SpeakerHistory")
            try Self.directory(history)
            let bytes = try Codec.encode(assignments)
            try bytes.write(to: history.appendingPathComponent(Codec.hash(bytes) + ".json"), options: .atomic)
        }
        try write(meeting.segments, dir.appendingPathComponent("transcript.json"))
        try Data(meeting.transcript.utf8).write(to: dir.appendingPathComponent("transcript.md"), options: .atomic)
        try Data(meeting.markdown.utf8).write(to: dir.appendingPathComponent("meeting.md"), options: .atomic)
        // The one commit marker includes content, assignment, speakers and revision.
        try write(meeting, dir.appendingPathComponent("meeting.json"))
        do { try updateIndex(meeting) }
        catch { index = nil } // A disposable projection cannot undo a durable content commit.
    }
    public func saveFolder(_ folder: Folder) throws {
        try locked {
            var all = try folders()
            let parentExists = folder.parentID == nil || all.contains(where: { $0.id == folder.parentID })
            let cycles = folder.parentID.map { Self.descendants(folder.id, in: all).contains($0) } ?? false
            guard !folder.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  parentExists, !cycles
            else { throw JottieError.invalid("Folder name or parent is invalid; cycles are not allowed.") }
            all.removeAll { $0.id == folder.id }; all.append(folder)
            try write(all, root.appendingPathComponent("folders.json"))
        }
    }
    public func deleteFolder(_ id: UUID) throws {
        try locked {
            var all = try folders()
            guard !all.contains(where: { $0.parentID == id }),
                  !(try meetings()).contains(where: { $0.folderID == id })
            else { throw JottieError.invalid("Move this folder's meetings and subfolders first.") }
            all.removeAll { $0.id == id }
            try write(all, root.appendingPathComponent("folders.json"))
        }
    }
    public static func descendants(_ id: UUID, in folders: [Folder]) -> Set<UUID> {
        var result: Set<UUID> = [id]
        var count = 0
        repeat {
            count = result.count
            for folder in folders where folder.parentID.map(result.contains) == true { result.insert(folder.id) }
        } while count != result.count
        return result
    }
    public static func normalise(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    public func file(_ ids: [UUID], into folderID: UUID?, manual: Bool = true) throws {
        try locked {
            for id in ids {
                var value = try meeting(id)
                value.folderID = folderID; value.manuallyFiled = manual; value.filingReason = nil
                try commit(value)
            }
        }
    }
    public func setStarred(_ starred: Bool, meetingID: UUID) throws {
        try locked {
            var value = try meeting(meetingID)
            value.starred = starred
            try commit(value)
        }
    }
    public func setSpeakers(names: [String: String], roles: [String: String], meetingID: UUID) throws {
        try locked {
            var value = try meeting(meetingID)
            let labels = Set(value.segments.map(\.speaker))
            guard Set(names.keys).isSubset(of: labels), Set(roles.keys).isSubset(of: labels) else {
                throw JottieError.invalid("Unknown speaker.")
            }
            for (label, name) in names {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                value.speakerNames[label] = trimmed.isEmpty ? nil : trimmed
            }
            value.speakerRoles = roles.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            try commit(value)
        }
    }
    public func setSpeakerAssignment(segmentIDs: [String], name: String, role: String?, employeeID: String?, meetingID: UUID, expectedRevision: String? = nil) throws {
        try locked {
            var value = try meeting(meetingID)
            guard expectedRevision == nil || expectedRevision == value.transcriptRevision else { throw JottieError.conflict("Transcript changed while correcting speakers. Reopen the correction and retry.") }
            let ids = Set(value.segments.map(\.id))
            guard !segmentIDs.isEmpty, Set(segmentIDs).isSubset(of: ids) else { throw JottieError.invalid("Unknown transcript passage.") }
            var assignments = value.speakerAttributions ?? [:]
            for id in segmentIDs {
                assignments[id] = SpeakerAttribution(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    jobTitle: role, employeeID: employeeID, method: "manual")
            }
            value.speakerAttributions = assignments
            try commit(value)
        }
    }
    public func setCalendarContext(_ context: CalendarEventContext, meetingID: UUID) throws {
        try locked {
            var meeting = try self.meeting(meetingID)
            meeting.calendarContext = context; meeting.calendarContextManuallySet = true
            meeting.participants = context.invitees; meeting.participantContext = nil
            try commit(meeting)
        }
    }
    public func setParticipantContext(_ context: [ParticipantIdentity], meetingID: UUID) throws -> Meeting {
        try locked {
            var value = try meeting(meetingID)
            value.participantContext = context.isEmpty ? nil : context
            try commit(value)
            return value
        }
    }
    public func setSpeaker(_ label: String, name: String, meetingID: UUID) throws {
        try locked {
            var value = try meeting(meetingID)
            guard value.segments.contains(where: { $0.speaker == label }) else { throw JottieError.invalid("Unknown speaker.") }
            value.speakerNames[label] = name.trimmingCharacters(in: .whitespacesAndNewlines)
            // Keep the source text; a correction requires explicit re-analysis.
            try commit(value)
        }
    }
    public func apply(_ revision: AnalysisRevision, to id: UUID) throws {
        try locked {
            var value = try meeting(id)
            guard value.transcriptRevision == revision.transcriptRevision else { throw JottieError.conflict("Transcript changed during analysis.") }
            try revision.analysis.validate(segments: value.segments)
            value = SpeakerReconciliation.applying(revision, to: value)
            value.analysis = revision
            if !value.manuallyFiled {
                let tag = revision.analysis.primaryTag.map(Self.normalise)
                let matches = try folders().filter { folder in
                    tag != nil && ([folder.name] + folder.aliases).contains { Self.normalise($0) == tag }
                }
                value.folderID = matches.count == 1 ? matches[0].id : nil
                value.filingReason = matches.count == 1 ? nil : (matches.isEmpty ? "No folder matches the primary tag." : "More than one folder matches the primary tag.")
            }
            try commit(value)
        }
    }
    private struct TrashReceipt: Codable { var trashedAt: Date }
    private func retiredSources() throws -> Set<String> {
        let file = root.appendingPathComponent("retired-sources.json")
        return FileManager.default.fileExists(atPath: file.path) ? try read(Set<String>.self, file) : []
    }
    public func shouldImportAmanu(_ directory: URL) throws -> Bool {
        let sourceID = Codec.hash(directory.standardizedFileURL.path)
        return try !retiredSources().contains(sourceID)
    }
    /// Old un-timestamped Trash gets a full grace period from first discovery.
    private func trashItems(now: Date) throws -> [TrashEntry] {
        let items = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Trash"), includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]).compactMap { directory -> TrashEntry? in
            let file = directory.appendingPathComponent("meeting.json")
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            let meeting = try read(Meeting.self, file)
            let receipt = directory.appendingPathComponent("trash.json")
            let timestamp: Date
            if FileManager.default.fileExists(atPath: receipt.path) { timestamp = try read(TrashReceipt.self, receipt).trashedAt }
            else { timestamp = now; if !readOnly { try write(TrashReceipt(trashedAt: now), receipt) } }
            return TrashEntry(id: directory.lastPathComponent, meeting: meeting, trashedAt: timestamp)
        }.sorted { $0.trashedAt > $1.trashedAt }
        if !readOnly {
            let prior = try retiredSources()
            let updated = prior.union(items.map { $0.meeting.sourceID })
            if prior != updated { try write(updated, root.appendingPathComponent("retired-sources.json")) }
        }
        return items
    }
    public func trashEntries(now: Date = Date()) throws -> [TrashEntry] {
        if readOnly { return try trashItems(now: now) }
        return try locked { try trashItems(now: now) }
    }
    public func trash(_ ids: [UUID], now: Date = Date()) throws {
        try locked {
            for id in Set(ids) {
                let value = try meeting(id)
                // Prevent the capture scanner from resurrecting a deleted source, even after expiry.
                var retired = try retiredSources(); retired.insert(value.sourceID)
                try write(retired, root.appendingPathComponent("retired-sources.json"))
                let destination = root.appendingPathComponent("Trash/\(id.uuidString)-\(UUID().uuidString)")
                try write(TrashReceipt(trashedAt: now), meetingDirectory(id).appendingPathComponent("trash.json"))
                try FileManager.default.moveItem(at: meetingDirectory(id), to: destination)
                try index?.write { db in
                    try db.execute(sql: "DELETE FROM meeting_search WHERE id = ?", arguments: [id.uuidString])
                    try db.execute(sql: "DELETE FROM meeting_catalog WHERE id = ?", arguments: [id.uuidString])
                    try db.execute(sql: "DELETE FROM tag_catalog WHERE meetingID = ?", arguments: [id.uuidString])
                    try db.execute(sql: "DELETE FROM action_catalog WHERE meetingID = ?", arguments: [id.uuidString])
                }
            }
        }
    }
    public func restoreTrash(_ entryID: String) throws {
        try locked {
            guard let item = try trashItems(now: Date()).first(where: { $0.id == entryID }) else { throw JottieError.invalid("Trash item no longer exists.") }
            let destination = meetingDirectory(item.meeting.id)
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw JottieError.conflict("A meeting with this ID already exists.") }
            var meeting = item.meeting
            if let folderID = meeting.folderID, try !folders().contains(where: { $0.id == folderID }) { meeting.folderID = nil }
            try FileManager.default.moveItem(at: root.appendingPathComponent("Trash").appendingPathComponent(item.id), to: destination)
            try commit(meeting)
            var retired = try retiredSources(); retired.remove(meeting.sourceID)
            try write(retired, root.appendingPathComponent("retired-sources.json"))
        }
    }
    /// Called at launch and while running. Never touches publication receipts or remote copies.
    @discardableResult public func purgeTrash(now: Date = Date(), emptyAll: Bool = false) throws -> Int {
        try locked {
            let expired = try trashItems(now: now).filter { emptyAll || $0.expiresAt <= now }
            for item in expired {
                var retired = try retiredSources(); retired.insert(item.meeting.sourceID)
                try write(retired, root.appendingPathComponent("retired-sources.json"))
                try FileManager.default.removeItem(at: root.appendingPathComponent("Trash").appendingPathComponent(item.id))
            }
            return expired.count
        }
    }
    private func updateIndex(_ meeting: Meeting) throws {
        guard !readOnly else { return }
        try index?.write { db in try Self.indexMeeting(meeting, db: db) }
    }
    private static func indexMeeting(_ meeting: Meeting, db: Database) throws {
            try db.execute(sql: "DELETE FROM meeting_search WHERE id = ?", arguments: [meeting.id.uuidString])
            let a = meeting.analysis?.analysis
            try db.execute(sql: "INSERT INTO meeting_search(id,title,transcript,summary,topics,people,tags) VALUES (?,?,?,?,?,?,?)",
                arguments: [meeting.id.uuidString, meeting.displayTitle, meeting.transcript, a?.summary ?? meeting.importedSummary ?? "",
                            a?.topics.joined(separator: " ") ?? "", (meeting.participants + Array(meeting.speakerNames.values)).joined(separator: " "),
                            a?.tags.joined(separator: " ") ?? ""])
            try db.execute(sql: "INSERT OR REPLACE INTO meeting_catalog(id,folderID,started) VALUES(?,?,?)",
                           arguments: [meeting.id.uuidString, meeting.folderID?.uuidString, meeting.startedAt.timeIntervalSince1970])
            try db.execute(sql: "DELETE FROM tag_catalog WHERE meetingID=?", arguments: [meeting.id.uuidString])
            for tag in Set(a?.tags ?? []) {
                try db.execute(sql: "INSERT OR IGNORE INTO tag_catalog(meetingID,tag) VALUES(?,?)",
                               arguments: [meeting.id.uuidString, normalise(tag)])
            }
            try db.execute(sql: "DELETE FROM action_catalog WHERE meetingID=?", arguments: [meeting.id.uuidString])
            for action in a?.actions ?? [] {
                try db.execute(sql: "INSERT INTO action_catalog(id,meetingID,text,status,owner,dueDate) VALUES(?,?,?,?,?,?)",
                               arguments: [action.id, meeting.id.uuidString, action.text, action.status, action.owner, action.dueDate])
            }
    }
    public func rebuildIndex() throws {
        try locked {
            if index == nil {
                // Keep serving canonical files even if the disk cache became unusable.
                let memory = try DatabaseQueue()
                try Self.prepare(memory)
                index = memory
            }
            let all = try meetings(), tree = try folders()
            for meeting in all {
                let directory = meetingDirectory(meeting.id)
                for (name, data) in [("transcript.json", try Codec.encode(meeting.segments)),
                                     ("transcript.md", Data(meeting.transcript.utf8)), ("meeting.md", Data(meeting.markdown.utf8))] {
                    let path = directory.appendingPathComponent(name)
                    if (try? Data(contentsOf: path)) != data { try data.write(to: path, options: .atomic) }
                }
            }
            let fingerprint = try projectionFingerprint()
            let contexts = try tree.compactMap { try context($0.id) }
            try index?.write { db in
                try db.execute(sql: "DELETE FROM meeting_search; DELETE FROM meeting_catalog; DELETE FROM tag_catalog; DELETE FROM action_catalog; DELETE FROM folder_catalog; DELETE FROM context_search;")
                for meeting in all { try Self.indexMeeting(meeting, db: db) }
                for folder in tree {
                    try db.execute(sql: "INSERT INTO folder_catalog(id,parentID,name,aliases) VALUES(?,?,?,?)",
                                   arguments: [folder.id.uuidString, folder.parentID?.uuidString, folder.name, folder.aliases.joined(separator: " ")])
                }
                for context in contexts {
                    try db.execute(sql: "INSERT INTO context_search(folderID,content) VALUES(?,?)", arguments: [context.folderID.uuidString, context.markdown])
                }
                try db.execute(sql: "INSERT OR REPLACE INTO projection_meta(key,value) VALUES('revision',?)", arguments: [fingerprint])
            }
        }
    }
    public func reconcile() throws {
        if !readOnly {
            try locked {
                try repairStoredDocumentTurns()
                for meeting in try meetings() where (meeting.analysis?.analysis.tags.count ?? 0) > 10 { try commit(meeting) }
            }
        }
        let current = try projectionFingerprint()
        let indexed = try? index?.read { db in try String.fetchOne(db, sql: "SELECT value FROM projection_meta WHERE key='revision'") }
        if current != indexed { try rebuildIndex() }
    }
    private func projectionFingerprint() throws -> String {
        var paths = [root.appendingPathComponent("folders.json")]
        for directory in ["Meetings", "Contexts"] {
            let base = root.appendingPathComponent(directory)
            if let children = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                paths += children.filter { UUID(uuidString: $0.lastPathComponent) != nil }
                    .flatMap { child in
                        (directory == "Meetings" ? ["meeting.json", "transcript.json", "transcript.md", "meeting.md"] : ["current.json"])
                            .map { child.appendingPathComponent($0) }
                    }
            }
        }
        let entries = paths.sorted { $0.path < $1.path }.compactMap { path -> String? in
            guard let values = try? path.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return "\(path.path):\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
        return Codec.hash(entries.joined(separator: "\n"))
    }
    public func search(_ query: SearchQuery) throws -> [SearchHit] {
        let allFolders = try folders()
        let ids = query.folderID.map { query.includeDescendants ? Self.descendants($0, in: allFolders) : [$0] }
        let starredIDs = query.starredOnly ? try meetings().filter { $0.starred == true }.map(\.id.uuidString) : []
        if query.starredOnly && starredIDs.isEmpty { return [] }
        let terms = query.text.split(whereSeparator: \.isWhitespace).map(String.init)
        let fingerprint = try projectionFingerprint()
        let projected = try? index?.read { db in try String.fetchOne(db, sql: "SELECT value FROM projection_meta WHERE key='revision'") }
        if let index, projected == fingerprint {
            do {
                var sql = "SELECT m.id, '' AS excerpt FROM meeting_catalog m"
                var predicates: [String] = []
                var arguments: [DatabaseValue] = []
                if !terms.isEmpty {
                    sql = "SELECT m.id, snippet(meeting_search,-1,'','', ' … ',24) AS excerpt FROM meeting_catalog m JOIN meeting_search ON meeting_search.id=m.id"
                    predicates.append("meeting_search MATCH ?")
                    arguments.append(terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " AND ").databaseValue)
                }
                if query.inbox { predicates.append("m.folderID IS NULL") }
                if query.starredOnly {
                    predicates.append("m.id IN (\(Array(repeating: "?", count: starredIDs.count).joined(separator: ",")))")
                    arguments += starredIDs.map(\.databaseValue)
                }
                if let ids {
                    let values = ids.map(\.uuidString).sorted()
                    predicates.append("m.folderID IN (\(Array(repeating: "?", count: values.count).joined(separator: ",")))")
                    arguments += values.map(\.databaseValue)
                }
                if let tag = query.tag {
                    predicates.append("EXISTS(SELECT 1 FROM tag_catalog t WHERE t.meetingID=m.id AND t.tag=?)")
                    arguments.append(Self.normalise(tag).databaseValue)
                }
                if let after = query.after { predicates.append("m.started >= ?"); arguments.append(after.timeIntervalSince1970.databaseValue) }
                if let before = query.before { predicates.append("m.started <= ?"); arguments.append(before.timeIntervalSince1970.databaseValue) }
                if !predicates.isEmpty { sql += " WHERE " + predicates.joined(separator: " AND ") }
                sql += " ORDER BY m.started " + (query.oldestFirst ? "ASC" : "DESC") + ",m.id LIMIT ? OFFSET ?"
                arguments += [min(100, max(1, query.limit)).databaseValue, max(0, query.offset).databaseValue]
                let statement = sql, bindings = StatementArguments(arguments)
                let result = try index.read { db in try Row.fetchAll(db, sql: statement, arguments: bindings) }
                return try result.compactMap { row in
                    guard let id = UUID(uuidString: row["id"]), FileManager.default.fileExists(atPath: meetingDirectory(id).appendingPathComponent("meeting.json").path) else { return nil }
                    let value = try meeting(id)
                    let snippet: String = row["excerpt"]
                    return SearchHit(meeting: value, snippet: snippet.isEmpty ? String((value.analysis?.analysis.summary ?? value.transcript).prefix(240)) : snippet)
                }
            } catch {
                // Canonical files stay usable if the disposable index develops a bad page.
            }
        }
        let matches = try meetings().filter { meeting in
            if query.inbox && meeting.folderID != nil { return false }
            if query.starredOnly && meeting.starred != true { return false }
            if let ids, !ids.contains(meeting.folderID ?? UUID()) { return false }
            if let tag = query.tag, !(meeting.analysis?.analysis.tags ?? []).contains(where: { Self.normalise($0) == Self.normalise(tag) }) { return false }
            if let after = query.after, meeting.startedAt < after { return false }
            if let before = query.before, meeting.startedAt > before { return false }
            return terms.allSatisfy { meeting.markdown.localizedStandardContains($0) }
        }
        return matches.sorted {
            if $0.startedAt == $1.startedAt { return $0.id.uuidString < $1.id.uuidString }
            return query.oldestFirst ? $0.startedAt < $1.startedAt : $0.startedAt > $1.startedAt
        }.dropFirst(max(0, query.offset)).prefix(min(100, max(1, query.limit))).map {
            SearchHit(meeting: $0, snippet: String(($0.analysis?.analysis.summary ?? $0.importedSummary ?? $0.transcript).prefix(240)))
        }
    }
    public func context(_ folderID: UUID) throws -> FolderContext? {
        let path = root.appendingPathComponent("Contexts/\(folderID.uuidString)/current.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return try read(FolderContext.self, path)
    }
    public static func contextFingerprint(folder: Folder, folders: [Folder], meetings: [Meeting], settings: LibrarySettings = LibrarySettings()) -> String {
        let subtree = descendants(folder.id, in: folders)
        let parts = meetings.filter { $0.folderID.map(subtree.contains) == true }.map {
            "\($0.id):\($0.transcriptRevision):\($0.analysis?.id ?? "pending")"
        }.sorted()
        let tree = folders.filter { subtree.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
        return Codec.hash("folder-context-v2\n" + settings.contextRevision + parts.joined(separator: "\n") + ((try? String(decoding: Codec.encode(tree), as: UTF8.self)) ?? ""))
    }
    public func saveContext(_ context: FolderContext) throws {
        try locked {
            let allFolders = try folders()
            guard let folder = allFolders.first(where: { $0.id == context.folderID }),
                  context.inputRevision == Self.contextFingerprint(folder: folder, folders: allFolders, meetings: try meetings(), settings: try settings())
            else { throw JottieError.conflict("Folder membership changed during context generation.") }
            let dir = root.appendingPathComponent("Contexts/\(context.folderID.uuidString)")
            try Self.directory(dir); try Self.directory(dir.appendingPathComponent("History"))
            try write(context, dir.appendingPathComponent("History/\(context.inputRevision).json"))
            try Data(context.markdown.utf8).write(to: dir.appendingPathComponent("context.md"), options: .atomic)
            try write(context, dir.appendingPathComponent("current.json"))
        }
    }
    public func export(_ ids: [UUID], to destination: URL) throws {
        try Self.directory(destination)
        for id in ids {
            let value = try meeting(id)
            let path = destination.appendingPathComponent("\(value.id.uuidString).md")
            guard !FileManager.default.fileExists(atPath: path.path) else { throw JottieError.conflict("An export for this meeting already exists.") }
            try Data(value.markdown.utf8).write(to: path, options: .withoutOverwriting)
        }
    }
    /// Copies only prepared text/metadata; never traverses source audio or logs.
    @discardableResult public func importAmanu(_ directory: URL, defaultSpeakerName: String? = nil) throws -> Meeting {
        struct Source: Decodable {
            struct Part: Decodable { var speaker: String; var start_ms: Int; var end_ms: Int; var text: String }
            var segments: [Part]
            var engine: String?
            var model: String?
            var created_at: String?
        }
        let data = try Data(contentsOf: directory.appendingPathComponent("transcript.json"))
        guard data.count <= 64_000_000 else { throw JottieError.invalid("Transcript is too large to import.") }
        let source = try JSONDecoder().decode(Source.self, from: data)
        let metaData = try Data(contentsOf: directory.appendingPathComponent("meta.json"))
        let meta = try JSONSerialization.jsonObject(with: metaData) as? [String: Any] ?? [:]
        let calendar = meta["calendar"] as? [String: Any] ?? [:]
        let sourceID = Codec.hash(directory.standardizedFileURL.path)
        guard try !retiredSources().contains(sourceID) else { throw JottieError.conflict("This source is in Jottie Trash or was deleted.") }
        let started = (meta["started"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date(timeIntervalSince1970: 0)
        let parts = source.segments.enumerated().map {
            Segment(id: "s\($0.offset + 1)", speaker: $0.element.speaker, startMS: $0.element.start_ms,
                    endMS: $0.element.end_ms, text: $0.element.text)
        }
        var value = Meeting(sourceID: sourceID, title: meta["title"] as? String ?? calendar["title"] as? String ?? directory.lastPathComponent,
                            startedAt: started, segments: parts, participants: calendar["attendeeIdentities"] as? [String] ?? calendar["attendees"] as? [String] ?? [])
        if let snapshot = calendar["snapshot"], let encoded = try? JSONSerialization.data(withJSONObject: snapshot) {
            value.calendarContext = try? Codec.decode(CalendarEventContext.self, from: encoded)
        }
        value.sourceMetadata = ["engine": source.engine, "model": source.model, "createdAt": source.created_at,
                                "recordingApp": meta["app"] as? String, "trigger": meta["trigger"] as? String,
                                "speakerSeparation": meta["local_speaker_separation"] as? String,
                                "transcriptSHA256": Codec.hash(data)].compactMapValues { $0 }
        if let summary = try? Data(contentsOf: directory.appendingPathComponent("summary.md")), summary.count <= 8_000_000 {
            value.importedSummary = String(data: summary, encoding: .utf8)
        }
        if let namesData = try? Data(contentsOf: directory.appendingPathComponent("speakers.json")),
           let names = try? JSONSerialization.jsonObject(with: namesData) as? [String: Any],
           let speakers = names["speakers"] as? [String: [String: Any]] {
            value.speakerNames = speakers.compactMapValues { $0["name"] as? String }
        }
        if let name = defaultSpeakerName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
           value.segments.contains(where: { $0.speaker == "me" }), value.speakerNames["me"]?.isEmpty != false {
            value.speakerNames["me"] = name
        }

        return try locked {
            guard try !retiredSources().contains(sourceID) else { throw JottieError.conflict("This source is in Jottie Trash or was deleted.") }
            func keepOriginal(_ id: UUID) throws {
                let history = meetingDirectory(id).appendingPathComponent("SourceTranscriptHistory")
                try Self.directory(history)
                let file = history.appendingPathComponent("\(Codec.hash(data)).json")
                if !FileManager.default.fileExists(atPath: file.path) { try data.write(to: file, options: .atomic) }
            }
            let all = try meetings()
            if var existing = all.first(where: { $0.sourceID == sourceID || ($0.transcriptRevision == value.transcriptRevision && $0.startedAt == started) }) {
                try keepOriginal(existing.id)
                var changed = false
                if existing.transcriptRevision != value.transcriptRevision {
                    existing.speakerAttributions = existing.speakerAttributions?.filter { id, attribution in
                        attribution.method == "manual" && existing.segments.first(where: { $0.id == id }) == value.segments.first(where: { $0.id == id })
                    }
                    existing.segments = value.segments; existing.transcriptRevision = value.transcriptRevision; existing.analysis = nil
                    // Preserve user corrections for channels that still exist; source naming fills only missing names.
                    let labels = Set(value.segments.map(\.speaker))
                    existing.speakerNames = existing.speakerNames.filter { labels.contains($0.key) }
                    for (label, name) in value.speakerNames where existing.speakerNames[label] == nil { existing.speakerNames[label] = name }
                    existing.sourceMetadata = value.sourceMetadata
                    existing.importedSummary = value.importedSummary
                    changed = true
                }
                if existing.calendarContextManuallySet != true, value.calendarContext != nil || !value.participants.isEmpty {
                    if existing.participants != value.participants { existing.participants = value.participants; existing.participantContext = nil; changed = true }
                    if let context = value.calendarContext, existing.calendarContext != context { existing.calendarContext = context; changed = true }
                }
                if existing.importedSummary == nil && value.importedSummary != nil { existing.importedSummary = value.importedSummary; changed = true }
                if changed { try commit(existing) }
                return existing
            }
            try keepOriginal(value.id)
            try commit(value)
            return value
        }
    }

    public func importTranscripts(from urls: [URL]) throws -> TranscriptImportReport {
        let scan = try TranscriptDocuments.scan(urls, excluding: root)
        var report = TranscriptImportReport(); report.failures = scan.failures
        for directory in scan.legacy {
            do {
                let previous = Set(try meetings().map(\.id))
                let value = try importAmanu(directory)
                if previous.contains(value.id) { report.unchanged += 1 } else { report.imported += 1 }
            } catch { report.failures.append("\(directory.lastPathComponent): \(error.localizedDescription)") }
        }
        for url in scan.files {
            do {
                let document = try TranscriptDocuments.text(url)
                guard !document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let sourceID = Codec.hash("document:" + url.standardizedFileURL.path)
                let parsed = DocumentSpeakerTurns.parse(document.text)
                let segments = parsed?.segments ?? [Segment(id: "s1", speaker: "unknown", text: document.text)]
                let changed = try locked {
                    let existing = try meetings().first { $0.sourceID == sourceID || $0.sourceMetadata?["documentSHA256"] == document.digest }
                    var value = existing ?? Meeting(sourceID: sourceID, title: url.deletingPathExtension().lastPathComponent,
                        startedAt: parsed?.startedAt ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date(), segments: segments)
                    if let existing, existing.sourceMetadata?["documentSHA256"] == document.digest,
                       existing.sourceMetadata?["documentParserRevision"] == DocumentSpeakerTurns.revision { return false }
                    try replaceDocumentSegments(in: &value, with: segments)
                    if let started = parsed?.startedAt { value.startedAt = started }
                    var metadata = value.sourceMetadata ?? [:]
                    metadata["documentSHA256"] = document.digest
                    metadata["importFormat"] = url.pathExtension.lowercased()
                    metadata["documentParserRevision"] = DocumentSpeakerTurns.revision
                    if let parsed { metadata["documentPreamble"] = parsed.preamble }
                    value.sourceMetadata = metadata
                    let history = meetingDirectory(value.id).appendingPathComponent("SourceTextHistory")
                    try Self.directory(history)
                    try Data(document.text.utf8).write(to: history.appendingPathComponent(document.digest + ".txt"), options: .atomic)
                    try commit(value)
                    return true
                }
                if changed { report.imported += 1 } else { report.unchanged += 1 }
            } catch { report.failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        return report
    }

    /// Upgrades the old single-passage projection from already retained text.
    /// Never reaches Downloads, contacts a model or guesses how to redistribute
    /// user corrections across newly split passages.
    private func repairStoredDocumentTurns() throws {
        for var value in try meetings() {
            guard value.sourceMetadata?["documentParserRevision"] != DocumentSpeakerTurns.revision,
                  let digest = value.sourceMetadata?["documentSHA256"], digest.count == 64, digest.allSatisfy(\.isHexDigit),
                  value.segments.count == 1, value.segments[0].speaker == "unknown",
                  value.speakerNames.isEmpty, (value.speakerRoles ?? [:]).isEmpty,
                  !(value.speakerAttributions ?? [:]).values.contains(where: { $0.method == "manual" }) else { continue }
            let source = meetingDirectory(value.id).appendingPathComponent("SourceTextHistory/\(digest).txt")
            guard let size = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64_000_000,
                  let bytes = try? Data(contentsOf: source), bytes.count <= 64_000_000,
                  let text = String(data: bytes, encoding: .utf8), text == value.segments[0].text,
                  let parsed = DocumentSpeakerTurns.parse(text) else { continue }
            try replaceDocumentSegments(in: &value, with: parsed.segments)
            value.sourceMetadata?["documentParserRevision"] = DocumentSpeakerTurns.revision
            value.sourceMetadata?["documentPreamble"] = parsed.preamble
            if let started = parsed.startedAt { value.startedAt = started }
            try commit(value)
        }
    }
    private func replaceDocumentSegments(in value: inout Meeting, with segments: [Segment]) throws {
        let revision = Codec.hash(try Codec.encode(segments))
        guard value.transcriptRevision != revision else { return }
        let previous = Dictionary(uniqueKeysWithValues: value.segments.map { ($0.id, $0) })
        let current = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        value.speakerAttributions = value.speakerAttributions?.filter { id, attribution in
            attribution.method == "manual" && previous[id] == current[id]
        }
        let labels = Set(segments.map(\.speaker))
        value.speakerNames = value.speakerNames.filter { labels.contains($0.key) }
        value.speakerRoles = value.speakerRoles?.filter { labels.contains($0.key) }
        value.segments = segments; value.transcriptRevision = revision; value.analysis = nil
    }
}

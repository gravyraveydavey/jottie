import Foundation
import GRDB
import JottieModels

public struct WorkStatus: Sendable, Identifiable {
    public var id: String
    public var stage: String
    public var state: String
    public var attempts: Int
    public var message: String?
}

public struct ProcessingProgress: Sendable, Equatable {
    public var completed: Int
    public var total: Int
    public init(completed: Int = 0, total: Int = 0) { self.total = max(0, total); self.completed = min(max(0, completed), max(0, total)) }
    public var percent: Int { total == 0 ? 0 : Int((Double(completed) / Double(total) * 100).rounded(.down)) }
    public var label: String { "Processing \(completed) of \(total) items (\(percent)%)" }
}

/// Operational state deliberately does not share the rebuildable search database.
public actor WorkLedger {
    private let queue: DatabaseQueue
    public init(root: URL) throws {
        try LibraryStore.directory(root)
        queue = try DatabaseQueue(path: root.appendingPathComponent("work.sqlite").path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS jobs (
                    id TEXT PRIMARY KEY, stage TEXT NOT NULL, state TEXT NOT NULL,
                    attempts INTEGER NOT NULL DEFAULT 0, next REAL NOT NULL DEFAULT 0,
                    message TEXT, receipt BLOB);
                """)
        }
    }
    public func begin(_ id: String, stage: String, now: Date = Date(), allowCompleted: Bool = false) throws -> Bool {
        try queue.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO jobs(id,stage,state) VALUES (?,?,'pending')", arguments: [id, stage])
            if allowCompleted {
                try db.execute(sql: "UPDATE jobs SET state='pending', attempts=0,next=0 WHERE id=? AND state='done'", arguments: [id])
            }
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM jobs WHERE id = ?", arguments: [id]),
                  (row["state"] as String) != "done", (row["state"] as String) != "held",
                  (row["next"] as Double) <= now.timeIntervalSince1970
            else { return false }
            try db.execute(sql: "UPDATE jobs SET state='running', attempts=attempts+1, next=? WHERE id=?",
                           arguments: [now.addingTimeInterval(3600).timeIntervalSince1970, id])
            return true
        }
    }
    public func finish(_ id: String, receipt: Data? = nil) throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE jobs SET state='done',message=NULL,receipt=? WHERE id=?", arguments: [receipt, id])
        }
    }
    public func fail(_ id: String, message: String, retryable: Bool = true, now: Date = Date()) throws {
        try queue.write { db in
            let attempts = try Int.fetchOne(db, sql: "SELECT attempts FROM jobs WHERE id=?", arguments: [id]) ?? 1
            try db.execute(sql: "UPDATE jobs SET state=?, next=?, message=? WHERE id=?",
                arguments: [retryable && attempts < 5 ? "deferred" : "held",
                            now.addingTimeInterval(min(3600, 60 * pow(2, Double(attempts - 1)))).timeIntervalSince1970,
                            message, id])
        }
    }
    public func retry(_ id: String) throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE jobs SET state='pending',attempts=0,next=0,message=NULL WHERE id=? AND state != 'running'", arguments: [id])
        }
    }
    public func statuses() throws -> [WorkStatus] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM jobs WHERE state NOT IN ('done','superseded') ORDER BY stage,id").map {
                WorkStatus(id: $0["id"], stage: $0["stage"], state: $0["state"], attempts: $0["attempts"], message: $0["message"])
            }
        }
    }
    /// Keep obsolete retries as history, without displaying them as current work.
    public func supersede(prefix: String, keeping ids: Set<String>) throws {
        try queue.write { db in
            let candidates = try String.fetchAll(db, sql: "SELECT id FROM jobs WHERE state NOT IN ('done','superseded','running')")
            for id in candidates where id.hasPrefix(prefix) && !ids.contains(id) {
                try db.execute(sql: "UPDATE jobs SET state='superseded',next=0 WHERE id=?", arguments: [id])
            }
        }
    }
    public func progress(ids: Set<String>) throws -> ProcessingProgress {
        try queue.read { db in
            let done = Set(try String.fetchAll(db, sql: "SELECT id FROM jobs WHERE state='done'"))
            return ProcessingProgress(completed: ids.intersection(done).count, total: ids.count)
        }
    }
}

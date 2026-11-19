/// Durable job journal (SQLite). Replaces NE's in-server move registry.
/// Port of state.py.
///
/// Guarantees:
///  * at most one *active* job per account (partial UNIQUE index) == RegisterMailboxMoveOut
///  * every phase transition is committed before the next side effect -> resumable
///  * heartbeat + pid -> stale-job detection (crashed controller)
import CSQLite
import Foundation

public enum Phase: Int, Sendable, CaseIterable {
    case planned = 0
    case preflightOK = 10
    case reserved = 20
    case presync = 30
    case prestaged = 40
    case locked = 50
    case finalSynced = 60
    case dbFinal = 70
    case verified = 80
    case merged = 90
    case flipped = 100
    case cachesPurged = 110
    case unlocked = 120
    case done = 130
    case purged = 140
}

public let activeStatuses = ["running", "failed"]
public struct Job {
    public var id: String
    public var account: String
    public var accountId: String
    public var src: String
    public var dst: String
    public var phase: Phase
    public var status: String
    public var options: [String: Any]
    public var data: [String: Any]
    public var error: String?
    public var created: Double
    public var updated: Double
    public var owner: String?
    public var heartbeat: Double

    public init(id: String, account: String, accountId: String, src: String, dst: String,
                phase: Phase = .planned, status: String = "running",
                options: [String: Any] = [:], data: [String: Any] = [:],
                error: String? = nil, created: Double = 0, updated: Double = 0,
                owner: String? = nil, heartbeat: Double = 0) {
        self.id = id; self.account = account; self.accountId = accountId
        self.src = src; self.dst = dst; self.phase = phase; self.status = status
        self.options = options; self.data = data; self.error = error
        self.created = created; self.updated = updated
        self.owner = owner; self.heartbeat = heartbeat
    }
}

public struct AlreadyMoving: Error {
    public var message: String
    public init(_ message: String) { self.message = message }
}

private let schemaSQL = """
CREATE TABLE IF NOT EXISTS jobs (
  id TEXT PRIMARY KEY, account TEXT NOT NULL, account_id TEXT NOT NULL,
  src TEXT NOT NULL, dst TEXT NOT NULL, phase INTEGER NOT NULL, status TEXT NOT NULL,
  options TEXT NOT NULL, data TEXT NOT NULL, error TEXT,
  created REAL NOT NULL, updated REAL NOT NULL, owner TEXT, heartbeat REAL NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX IF NOT EXISTS u_active_account ON jobs(account_id)
  WHERE status IN ('running','failed');
CREATE TABLE IF NOT EXISTS events (
  job_id TEXT NOT NULL, ts REAL NOT NULL, phase INTEGER, level TEXT, msg TEXT, data TEXT
);
CREATE INDEX IF NOT EXISTS i_events_job ON events(job_id, ts);
CREATE TABLE IF NOT EXISTS purges (
  account_id TEXT NOT NULL, server TEXT NOT NULL, mailbox_id INTEGER NOT NULL, ts REAL NOT NULL,
  PRIMARY KEY (account_id, server)
);
"""

func jsonString(_ v: Any) -> String {
    guard JSONSerialization.isValidJSONObject(v),
          let d = try? JSONSerialization.data(withJSONObject: v, options: []) ,
          let s = String(data: d, encoding: .utf8) else { return "{}" }
    return s
}

func jsonObject(_ s: String?) -> [String: Any] {
    guard let s = s, let d = s.data(using: .utf8),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
    return o
}

final class SQLiteDB {
    var db: OpaquePointer?
    let path: String

    init(path: String) throws {
        self.path = path
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            throw SQLiteError.open(String(cString: sqlite3_errmsg(db)))
        }
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA busy_timeout=30000;")
        try exec(schemaSQL)
    }

    deinit { sqlite3_close(db) }

    func exec(_ sql: String, _ args: [Any?] = []) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw SQLiteError.prepare(String(cString: sqlite3_errmsg(db)) + " :: " + sql)
        }
        defer { sqlite3_finalize(s) }
        try bind(s, args)
        let rc = sqlite3_step(s)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            throw SQLiteError.step(String(cString: sqlite3_errmsg(db)) + " :: " + sql)
        }
    }

    func query(_ sql: String, _ args: [Any?] = []) throws -> [[Any?]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw SQLiteError.prepare(String(cString: sqlite3_errmsg(db)) + " :: " + sql)
        }
        defer { sqlite3_finalize(s) }
        try bind(s, args)
        var rows: [[Any?]] = []
        while sqlite3_step(s) == SQLITE_ROW {
            var row: [Any?] = []
            let n = sqlite3_column_count(s)
            for i in 0..<n {
                switch sqlite3_column_type(s, i) {
                case SQLITE_INTEGER: row.append(Int(sqlite3_column_int64(s, i)))
                case SQLITE_FLOAT: row.append(sqlite3_column_double(s, i))
                case SQLITE_TEXT:
                    if let c = sqlite3_column_text(s, i) {
                        row.append(String(cString: c))
                    } else { row.append(nil) }
                case SQLITE_NULL: row.append(nil)
                default:
                    if let c = sqlite3_column_text(s, i) {
                        row.append(String(cString: c))
                    } else { row.append(nil) }
                }
            }
            rows.append(row)
        }
        return rows
    }

    func changes() -> Int { Int(sqlite3_changes(db)) }

    private func bind(_ stmt: OpaquePointer, _ args: [Any?]) throws {
        for (i, v) in args.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case nil: sqlite3_bind_null(stmt, idx)
            case let n as Int: sqlite3_bind_int64(stmt, idx, Int64(n))
            case let n as Int64: sqlite3_bind_int64(stmt, idx, n)
            case let d as Double: sqlite3_bind_double(stmt, idx, d)
            case let s as String:
                s.withCString { sqlite3_bind_text(stmt, idx, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            default: throw SQLiteError.bind("unsupported arg type")
            }
        }
    }
}

public enum SQLiteError: Error {
    case open(String), prepare(String), step(String), bind(String)
}

private let jobCols = "id, account, account_id, src, dst, phase, status, options, data, error, created, updated, owner, heartbeat"

public final class State {
    public let path: String
    private let db: SQLiteDB
    private let lock = NSLock()

    public static let heartbeatInterval: Double = 30.0
    public static let heartbeatStale: Double = 120.0

     public init(path: String) throws {
         self.path = path
         self.db = try SQLiteDB(path: path)
         for stmt in schemaSQL.components(separatedBy: ";") {
             let s = stmt.trimmingCharacters(in: .whitespacesAndNewlines)
             if s.isEmpty { continue }
             try db.exec(s)
         }
     }

    public static func ownerTag() -> String {
        "\(ProcessInfo.processInfo.hostName):\(getpid())"
    }

    private func row(_ r: [Any?]) -> Job {
        Job(id: r[0] as? String ?? "", account: r[1] as? String ?? "",
            accountId: r[2] as? String ?? "", src: r[3] as? String ?? "",
            dst: r[4] as? String ?? "",
            phase: Phase(rawValue: (r[5] as? Int) ?? 0) ?? .planned,
            status: r[6] as? String ?? "running",
            options: jsonObject(r[7] as? String), data: jsonObject(r[8] as? String),
            error: r[9] as? String,
            created: r[10] as? Double ?? 0, updated: r[11] as? Double ?? 0,
            owner: r[12] as? String, heartbeat: r[13] as? Double ?? 0)
    }

    @discardableResult
    public func create(account: String, accountId: String, src: String, dst: String,
                       options: [String: Any]) throws -> Job {
        let now = Date().timeIntervalSince1970
        var job = Job(id: String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)),
                      account: account, accountId: accountId, src: src, dst: dst,
                      options: options, created: now, updated: now,
                      owner: Self.ownerTag(), heartbeat: now)
        lock.lock(); defer { lock.unlock() }
        do {
            try db.exec("INSERT INTO jobs (\(jobCols)) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                        [job.id, account, accountId, src, dst, job.phase.rawValue, job.status,
                         jsonString(options), "{}", nil, now, now, job.owner, now])
        } catch {
            let other = try? activeFor(accountId)
            throw AlreadyMoving("ALREADY_BEING_MOVED: \(account) has active job " +
                                "\(other?.id ?? "?") (\(other?.status ?? ""))")
        }
        return job
    }

    public func save(_ j: inout Job) throws {
        j.updated = Date().timeIntervalSince1970
        lock.lock(); defer { lock.unlock() }
        try db.exec("UPDATE jobs SET phase=?, status=?, options=?, data=?, error=?, updated=?, " +
                    "owner=?, heartbeat=? WHERE id=?",
                    [j.phase.rawValue, j.status, jsonString(j.options), jsonString(j.data),
                     j.error, j.updated, j.owner, j.heartbeat, j.id])
    }

    public func beat(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        try db.exec("UPDATE jobs SET heartbeat=? WHERE id=?", [Date().timeIntervalSince1970, id])
    }

    public func get(_ id: String) throws -> Job? {
        let rows = try db.query("SELECT \(jobCols) FROM jobs WHERE id=?", [id])
        return rows.first.map(row)
    }

    public func activeFor(_ accountId: String) throws -> Job? {
        let rows = try db.query("SELECT \(jobCols) FROM jobs WHERE account_id=? AND status IN " +
                                "('running','failed')", [accountId])
        return rows.first.map(row)
    }

    public func find(account: String? = nil, server: String? = nil,
                     status: String? = nil, limit: Int = 200) throws -> [Job] {
        var sql = "SELECT \(jobCols) FROM jobs WHERE 1=1"
        var args: [Any?] = []
        if let a = account { sql += " AND (account=? OR account_id=?)"; args += [a, a] }
        if let s = server { sql += " AND (src=? OR dst=?)"; args += [s, s] }
        if let st = status { sql += " AND status=?"; args.append(st) }
        sql += " ORDER BY created DESC LIMIT ?"
        args.append(limit)
        return try db.query(sql, args).map(row)
    }

    public func event(jobId: String, level: String, msg: String,
                      phase: Phase? = nil, data: [String: Any] = [:]) throws {
        lock.lock(); defer { lock.unlock() }
        try db.exec("INSERT INTO events VALUES (?,?,?,?,?,?)",
                    [jobId, Date().timeIntervalSince1970,
                     phase.map { $0.rawValue }, level, msg, jsonString(data)])
    }

    public func events(jobId: String) throws -> [[Any?]] {
        try db.query("SELECT ts, phase, level, msg, data FROM events WHERE job_id=? ORDER BY ts",
                     [jobId])
    }

    public func recordPurge(accountId: String, server: String, mailboxId: Int) throws {
        lock.lock(); defer { lock.unlock() }
        try db.exec("INSERT OR REPLACE INTO purges VALUES (?,?,?,?)",
                    [accountId, server, mailboxId, Date().timeIntervalSince1970])
    }

    public func purgeRecord(accountId: String, server: String) throws -> (Int, Double)? {
        let rows = try db.query("SELECT mailbox_id, ts FROM purges WHERE account_id=? AND server=?",
                                [accountId, server])
        guard let r = rows.first, r.count >= 2,
              let id = r[0] as? Int, let ts = r[1] as? Double else { return nil }
        return (id, ts)
    }

    public func clearPurge(accountId: String, server: String) throws {
        lock.lock(); defer { lock.unlock() }
        try db.exec("DELETE FROM purges WHERE account_id=? AND server=?", [accountId, server])
    }

    public func pruneEvents(maxAgeDays: Double = 30) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let cutoff = Date().timeIntervalSince1970 - maxAgeDays * 86400
        try db.exec("DELETE FROM events WHERE ts < ? AND job_id NOT IN " +
                    "(SELECT id FROM jobs WHERE status IN ('running','failed'))", [cutoff])
        return db.changes()
    }

    public func ownerAlive(_ j: Job) -> Bool {
        guard j.status == "running", let owner = j.owner, owner != Self.ownerTag() else {
            return false
        }
        let parts = owner.split(separator: ":", maxSplits: 1).map(String.init)
        if parts.count == 2, parts[0] == ProcessInfo.processInfo.hostName,
           let pid = Int32(parts[1]) {
            return kill(pid, 0) == 0
        }
        return (Date().timeIntervalSince1970 - j.heartbeat) < Self.heartbeatStale
    }
}

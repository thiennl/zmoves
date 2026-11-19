/// MySQL/MariaDB access on a mailstore (through SSH, using Zimbra's own binaries/credentials).
/// Port of db.py.
import Foundation

private let identRE = try! NSRegularExpression(pattern: "^[A-Za-z0-9_]+$")

/// Tables in the `zimbra` schema scoped per-mailbox (db.sql). Discovered tables
/// are intersected with this allowlist: deleted_account and volume_blobs
/// (dedupe work queue) are intentionally NOT moved.
public let zimbraMailboxTables = ["mailbox_metadata", "out_of_office", "scheduled_task",
                                  "mobile_devices", "pending_acl_push", "zmg_devices"]

/// Tables whose rows carry change numbers -> eligible for delta sync.
public let deltaTableNames = ["mail_item", "mail_item_dumpster"]

/// Column carrying a FileBlobStore locator (= volume id as string).
public let locatorColumn = "locator"

public func ident(_ name: String) throws -> String {
    let r = NSRange(name.startIndex..., in: name)
    if identRE.firstMatch(in: name, range: r) == nil {
        throw DbError.unsafeIdentifier(name)
    }
    return "`\(name)`"
}

public func shIdent(_ name: String) throws -> String {
    let r = NSRange(name.startIndex..., in: name)
    if identRE.firstMatch(in: name, range: r) == nil {
        throw DbError.unsafeIdentifier(name)
    }
    return name
}

/// Quote a string literal for SQL (values come from LDAP/DB; escape defensively).
public func q(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "'", with: "\\'") + "'"
}

public enum DbError: Error {
    case unsafeIdentifier(String)
}

public struct TableInfo: Sendable {
    public var schema: String
    public var name: String
    public var columns: [String]
    public var uniqueIndexes: [String]

    public var hasLocator: Bool { columns.contains(locatorColumn) }
}

public final class MySQL {
    public let host: Host
    public let mysqlBin: String
    public let mysqldumpBin: String
    public let myCnf: String

    public init(host: Host, mysqlBin: String, mysqldumpBin: String,
                myCnf: String = "/opt/zimbra/conf/my.cnf") {
        self.host = host; self.mysqlBin = mysqlBin; self.mysqldumpBin = mysqldumpBin
        self.myCnf = myCnf
    }

    private static var envPrefix: String {
        "export MYSQL_PWD=\"$(zmlocalconfig -s -m nokey mysql_root_password)\"; " +
        "SOCK=\"$(zmlocalconfig -m nokey mysql_socket)\"; "
    }

    public func clientCmd(db: String? = nil, batch: Bool = true, env: Bool = true) throws -> String {
        var args = [mysqlBin, "--defaults-file=\(myCnf)", "-S \"$SOCK\"", "-u root",
                    "--max_allowed_packet=1G"]
        if batch { args += ["--batch", "-N", "--raw"] }
        if let d = db { args.append(try shIdent(d)) }
        return (env ? Self.envPrefix : "") + args.joined(separator: " ")
    }

    public func dumpCmd(db: String, tables: [String], where whereClause: String,
                        replace: Bool = false) throws -> String {
        let tbls = try tables.map { try shIdent($0) }.joined(separator: " ")
        var opts = ["--defaults-file=\(myCnf)", "-S \"$SOCK\"", "-u root",
                    "--no-create-info", "--skip-triggers", "--complete-insert", "--skip-add-locks",
                    "--skip-disable-keys", "--single-transaction", "--quick", "--hex-blob",
                    "--skip-tz-utc", "--skip-comments", "--extended-insert", "--max_allowed_packet=1G",
                    "--where='\(whereClause.replacingOccurrences(of: "'", with: "'\"'\"'"))'"]
        if replace { opts.append("--replace") }
        return Self.envPrefix + "\(mysqldumpBin) \(opts.joined(separator: " ")) \(try shIdent(db)) \(tbls)"
    }

    public func query(_ sql: String, db: String? = nil,
                      timeout: Double? = nil) -> [[String?]] {
        guard let cmd = try? clientCmd(db: db) else { return [] }
        guard let out = try? host.run(cmd, input: sql, timeout: timeout, mutating: false).out else {
            return []
        }
        var rows: [[String?]] = []
        for line in out.components(separatedBy: .newlines) {
            if line.isEmpty { continue }
            rows.append(line.components(separatedBy: "\t").map { $0 == "NULL" ? nil : $0 })
        }
        return rows
    }

    public func scalar(_ sql: String, db: String? = nil,
                       timeout: Double? = nil) -> String? {
        let rows = query(sql, db: db, timeout: timeout)
        return rows.first?.first ?? nil
    }

    public func execute(_ sql: String, db: String? = nil,
                        timeout: Double? = nil) throws {
        let cmd = try clientCmd(db: db)
        try host.run(cmd, input: sql, timeout: timeout, mutating: true)
    }

    public func schemaExists(_ schema: String) -> Bool {
        scalar("SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name=\(q(schema))") == "1"
    }

    public func tables(withColumn column: String, in schema: String) -> [String] {
        query("SELECT table_name FROM information_schema.columns WHERE table_schema=\(q(schema)) " +
              "AND column_name=\(q(column)) ORDER BY table_name").compactMap { $0.first ?? nil }
    }

    public func allTables(_ schema: String) -> [String] {
        query("SELECT table_name FROM information_schema.tables WHERE table_schema=\(q(schema))")
            .compactMap { $0.first ?? nil }
    }

    public func tableInfo(schema: String, tables: [String]) -> [String: TableInfo] {
        guard !tables.isEmpty else { return [:] }
        let inlist = tables.map { q($0) }.joined(separator: ",")
        var out: [String: TableInfo] = Dictionary(
            uniqueKeysWithValues: tables.map { ($0, TableInfo(schema: schema, name: $0, columns: [], uniqueIndexes: [])) })
        for r in query("SELECT table_name, column_name FROM information_schema.columns " +
                       "WHERE table_schema=\(q(schema)) AND table_name IN (\(inlist)) " +
                       "ORDER BY table_name, ordinal_position") {
            if r.count >= 2, let t = r[0], let c = r[1] { out[t]?.columns.append(c) }
        }
        for r in query("SELECT DISTINCT table_name, index_name FROM information_schema.statistics " +
                       "WHERE table_schema=\(q(schema)) AND table_name IN (\(inlist)) " +
                       "AND non_unique=0 AND index_name<>'PRIMARY'") {
            if r.count >= 2, let t = r[0], let i = r[1] { out[t]?.uniqueIndexes.append(i) }
        }
        return out.filter { !$0.value.columns.isEmpty }
    }

    public func configValue(_ name: String) -> String? {
        scalar("SELECT value FROM zimbra.config WHERE name=\(q(name))")
    }
}

/// Order-independent table fingerprint for one mailbox: COUNT + BIT_XOR(64-bit MD5 prefix).
/// `locatorExpr` lets the *source* side apply the volume remap so both sides compare equal.
public func checksumSQL(schema: String, table: TableInfo, keyCol: String, keyVal: Int,
                        locatorExpr: String? = nil, exclude: [String] = []) -> String {
    var skip = Set([keyCol]); exclude.forEach { skip.insert($0) }
    var parts: [String] = []
    for c in table.columns where !skip.contains(c) {
        var expr = "`\(c)`"
        if c == locatorColumn, let loc = locatorExpr { expr = loc }
        parts.append("IFNULL(CAST(\(expr) AS BINARY), 0x00)")
    }
    let row = parts.isEmpty ? "''" : "CONCAT_WS(0x1f, \(parts.joined(separator: ", ")))"
    return "SELECT COUNT(*), COALESCE(BIT_XOR(CAST(CONV(SUBSTRING(MD5(\(row)),1,16),16,10) " +
        "AS UNSIGNED)),0) FROM `\(schema)`.`\(table.name)` " +
        "WHERE `\(keyCol)`=\(keyVal)"
}

/// INSERT INTO live.t (cols) SELECT <cols with key/overrides> FROM stage.t.
public func insertSelectSQL(dstSchema: String, stageSchema: String, table: TableInfo,
                            keyCol: String, newKey: Int,
                            overrides: [String: String] = [:]) -> String {
    var over = overrides
    over[keyCol] = String(newKey)
    let cols = table.columns.map { "`\($0)`" }.joined(separator: ", ")
    let sel = table.columns.map { over[$0] ?? "`\($0)`" }.joined(separator: ", ")
    return "INSERT INTO `\(dstSchema)`.`\(table.name)` (\(cols)) " +
        "SELECT \(sel) FROM `\(stageSchema)`.`\(table.name)`;"
}

/// Shell pipeline (run on source) emitting batched INSERTs of the item-id set.
public func idListToInsertsCmd(mysql: MySQL, schema: String, table: String,
                               mailboxId: Int, targetTable: String,
                               batch: Int = 5000) throws -> String {
    let sel = "SELECT id FROM `\(schema)`.`\(table)` WHERE mailbox_id=\(mailboxId)"
    let awk = "awk -v T='\(targetTable)' -v B=\(batch) " +
        "'{ if (n % B == 0) { if (n) print \";\"; printf \"INSERT INTO %s (id) VALUES (%s)\", T, $1 } " +
        "else printf \",(%s)\", $1; n++ } END { if (n) print \";\" }'"
    return try "\(mysql.clientCmd()) -e '\(sel)' | \(awk)"
}

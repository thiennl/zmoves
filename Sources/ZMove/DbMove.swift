/// Per-mailbox DB transfer: staging, delta sync, verification, merge, cleanup.
/// Port of dbmove.py.
///
/// Strategy (improvement over NE, which exports/imports the whole mailbox DB *while locked*):
///  1. PRESTAGE (account online): copy mail_item(+dumpster) rows into a staging schema on the
///     destination and remember watermark W = max(mod_metadata, mod_content).
///  2. FINAL (account locked): copy only rows with mod_metadata > W or mod_content > W, drop rows
///     whose id disappeared at the source, fully re-copy the small tables.
///  3. VERIFY: per-table COUNT + BIT_XOR(MD5) fingerprint, source vs stage. Mismatch -> automatic
///     fallback to a full copy of the delta tables (still under lock), then re-verify.
///  4. MERGE: one transaction remaps mailbox_id/group/locator and inserts into the live tables.
/// Change numbers are allocated under the per-mailbox lock (Mailbox.beginTransaction), so any
/// transaction not yet committed when W is read gets a number > W and is picked up by the delta.
import Foundation

/// Mailbox row columns that legitimately differ between source and destination.
public let mailboxRowLocalCols = ["id", "group_id", "index_volume_id", "itemcache_checkpoint"]

public struct SchemaMismatch: Error {
    public var message: String
    public init(_ message: String) { self.message = message }
}

public struct VerifyError: Error {
    public var message: String
    public init(_ message: String) { self.message = message }
}

public struct DbPlan: Sendable {
    public var account: String
    public var accountId: String
    public var srcId: Int
    public var srcGroup: Int
    public var dstId: Int
    public var dstGroup: Int
    public var dstIndexVolume: Int
    public var stage: String
    public var volMap: [Int: Int]
    public var excludeTables: [String]
    public var groupTables: [String: TableInfo]
    public var zimbraTables: [String: TableInfo]
    public var mailboxTable: TableInfo?

    public init(account: String, accountId: String, srcId: Int, srcGroup: Int,
                dstId: Int, dstGroup: Int, dstIndexVolume: Int, stage: String,
                volMap: [Int: Int], excludeTables: [String] = [],
                groupTables: [String: TableInfo] = [:],
                zimbraTables: [String: TableInfo] = [:],
                mailboxTable: TableInfo? = nil) {
        self.account = account; self.accountId = accountId
        self.srcId = srcId; self.srcGroup = srcGroup
        self.dstId = dstId; self.dstGroup = dstGroup
        self.dstIndexVolume = dstIndexVolume; self.stage = stage
        self.volMap = volMap; self.excludeTables = excludeTables
        self.groupTables = groupTables; self.zimbraTables = zimbraTables
        self.mailboxTable = mailboxTable
    }

    public var srcGdb: String { groupDb(srcGroup) }
    public var dstGdb: String { groupDb(dstGroup) }
}


public final class DbMove {
    public var p: DbPlan
    public let src: MySQL
    public let dst: MySQL
    public let dry: Bool

    public init(plan: DbPlan, src: MySQL, dst: MySQL, dryRun: Bool = false) {
        self.p = plan; self.src = src; self.dst = dst; self.dry = dryRun
    }

    // ------------------------------------------------------------------ discovery
    public func discover() throws {
        let srcG = Set(src.tables(withColumn: "mailbox_id", in: p.srcGdb))
        let tmpl: String
        if dstGroupReady() {
            tmpl = p.dstGdb
        } else {
            tmpl = try dstTemplateGroup()
        }
        let dstG = Set(dst.tables(withColumn: "mailbox_id", in: tmpl))
        let missing = srcG.subtracting(dstG)
        if !missing.isEmpty {
            throw SchemaMismatch("tables missing on destination: \(missing.sorted())")
        }
        let names = srcG.filter { !p.excludeTables.contains($0) }.sorted()
        let sInfo = src.tableInfo(schema: p.srcGdb, tables: names)
        let dInfo = dst.tableInfo(schema: tmpl, tables: names)
        try Self.compare(sInfo, dInfo, what: "group")
        p.groupTables = dInfo

        let srcZ = Set(src.tables(withColumn: "mailbox_id", in: "zimbra"))
        let dstZ = Set(dst.tables(withColumn: "mailbox_id", in: "zimbra"))
        let excluded = Set(p.excludeTables)
        let unknown = (srcZ.union(dstZ)).subtracting(Set(zimbraMailboxTables)).subtracting(excluded)
            .filter { $0 != "acl" }
        if !unknown.isEmpty {
            throw SchemaMismatch("unknown mailbox-scoped zimbra tables: \(unknown.sorted()); " +
                "update ZIMBRA_MAILBOX_TABLES or pass --exclude-tables")
        }
        let migrate = zimbraMailboxTables.filter { srcZ.contains($0) && dstZ.contains($0) && !excluded.contains($0) }.sorted()
        let dstOnly = zimbraMailboxTables.filter { dstZ.contains($0) && !srcZ.contains($0) && !excluded.contains($0) }.sorted()
        if !dstOnly.isEmpty {
            throw SchemaMismatch("destination has mailbox tables the source lacks " +
                "(\(dstOnly)); versions diverged, refusing silent drop")
        }
        let zn = migrate.filter { srcZ.contains($0) && dstZ.contains($0) }.sorted()
        let zs = src.tableInfo(schema: "zimbra", tables: zn)
        let zd = dst.tableInfo(schema: "zimbra", tables: zn)
        try Self.compare(zs, zd, what: "zimbra")
        p.zimbraTables = zd
        let ms = src.tableInfo(schema: "zimbra", tables: ["mailbox"])
        let md = dst.tableInfo(schema: "zimbra", tables: ["mailbox"])
        try Self.compare(ms, md, what: "zimbra")
        guard let mb = md["mailbox"] else {
            throw SchemaMismatch("destination lacks zimbra.mailbox")
        }
        p.mailboxTable = mb
    }

    private static func compare(_ s: [String: TableInfo], _ d: [String: TableInfo],
                                what: String) throws {
        for (t, si) in s {
            guard let di = d[t], si.columns == di.columns else {
                throw SchemaMismatch("\(what).\(t): column layout differs " +
                    "(src=\(si.columns) dst=\(d[t]?.columns ?? []) ; " +
                    "source and destination must run the same Zimbra version")
            }
        }
    }

    private func dstMissingGroupTables() -> [String]? {
        /// Tables a populated group has but the destination group lacks.
        /// nil = the destination group schema does not exist at all.
        if !dst.schemaExists(p.dstGdb) { return nil }
        let have = Set(dst.allTables(p.dstGdb))
        let tmpl: String
        do { tmpl = try dstTemplateGroup() }
        catch { return have.contains("mail_item") ? [] : ["mail_item"] }
        return Set(dst.allTables(tmpl)).subtracting(have).sorted()
    }

    private func dstGroupReady() -> Bool {
        /// The destination group schema exists AND holds every table a populated
        /// group has (an empty or half-created schema left by a crash does not count).
        return dstMissingGroupTables() == []
    }

    private func dstTemplateGroup() throws -> String {
        /// A populated mboxgroup schema on the destination, never the (maybe empty) target group.
        guard let r = dst.scalar("SELECT schema_name FROM information_schema.tables " +
            "WHERE table_schema LIKE 'mboxgroup%' AND table_name='mail_item' " +
            "AND table_schema<>\(q(p.dstGdb)) ORDER BY table_schema LIMIT 1"), !r.isEmpty else {
            throw SchemaMismatch("destination has no populated mboxgroup schema to use as template")
        }
        return r
    }

    public func estimateBytes() -> Int {
        let names = p.groupTables.keys.sorted()
        if names.isEmpty { return 0 }
        let inlist = names.map { q($0) }.joined(separator: ",")
        var stats: [String: (Int, Int)] = [:]
        for r in src.query("SELECT table_name, COALESCE(data_length,0)+COALESCE(index_length,0), " +
                           "COALESCE(table_rows,0) FROM information_schema.tables " +
                           "WHERE table_schema=\(q(p.srcGdb)) AND table_name IN (\(inlist))") {
            if r.count >= 3, let t = r[0] {
                stats[t] = (Int(r[1] ?? "") ?? 0, Int(r[2] ?? "") ?? 0)
            }
        }
        var total = 0
        for row in src.query(names.map {
            "SELECT \($0), COUNT(*) FROM `\(p.srcGdb)`.`\($0)` WHERE mailbox_id=\(p.srcId)"
        }.joined(separator: " UNION ALL ")) {
            if row.count >= 2, let t = row[0], let n = Int(row[1] ?? "") {
                let (size, rows) = stats[t] ?? (0, 0)
                total += n * (size / max(rows, 1))
            }
        }
        return total
    }

    public func ensureDstGroupDb() throws {
        /// DbMailbox.createMailboxDatabase equivalent: clone DDL from an existing group.
        /// SAFETY: a group schema is shared by every mailbox whose id maps to it, so an
        /// existing schema is NEVER dropped or altered.
        guard let missing = dstMissingGroupTables(), missing != [] else { return }
        let tmpl = try dstTemplateGroup()
        var need = missing
        if dstMissingGroupTables() == nil {
            zlog("creating \(p.dstGdb) on \(dst.host.name) from template \(tmpl)")
            try dst.execute("CREATE DATABASE IF NOT EXISTS `\(p.dstGdb)` DEFAULT CHARACTER SET utf8;")
            need = dst.allTables(tmpl).sorted()
        } else {
            zlog("\(p.dstGdb) on \(dst.host.name) lacks tables \(need); creating them from \(tmpl) (existing tables untouched)")
        }
        guard !need.isEmpty else { return }
        let tbls = need.map { "`\($0)`" }.joined(separator: " ")
        let ddl = "\(dst.mysqldumpBin) --defaults-file=\(dst.myCnf) -S \"$SOCK\" -u root " +
            "--no-data --skip-add-drop-table --skip-triggers --skip-comments " +
            "\(tmpl) \(tbls)"
        let mysqlEnv = "export MYSQL_PWD=\"$(zmlocalconfig -s -m nokey mysql_root_password)\"; " +
            "SOCK=\"$(zmlocalconfig -m nokey mysql_socket)\"; "
        let client = try dst.clientCmd(db: p.dstGdb, env: false)
        try dst.host.run("\(mysqlEnv)\(ddl) | \(client)")
    }

    // ------------------------------------------------------------------ staging
    public func createStage() throws {
        /// Idempotent: a crashed run resumes into the same stage instead of failing on CREATE.
        if dst.schemaExists(p.stage) {
            try discover()
            var have = Set(dst.tables(withColumn: "mailbox_id", in: p.stage))
            _ = have
            let want = Set(p.groupTables.keys).union(p.zimbraTables.keys).union(["mailbox"]).subtracting(["acl"])
            let missing = want.subtracting(Set(dst.tables(withColumn: "mailbox_id", in: p.stage)))
            for t in missing.sorted() { try createStageTable(t) }
            return
        }
        try dst.execute("DROP DATABASE IF EXISTS `\(p.stage)`; " +
                        "CREATE DATABASE `\(p.stage)` DEFAULT CHARACTER SET utf8;")
        for t in Array(p.groupTables.keys) + Array(p.zimbraTables.keys) + ["mailbox"] {
            try createStageTable(t)
        }
    }

    private func createStageTable(_ table: String) throws {
        let ti: TableInfo
        let like: String
        if table == "mailbox" {
            guard let m = p.mailboxTable else {
                throw SchemaMismatch("no mailbox table info")
            }
            ti = m
            like = "zimbra.`\(table)`"
        } else if let g = p.groupTables[table] {
            ti = g
            like = "`\(p.dstGdb)`.`\(table)`"
        } else if let z = p.zimbraTables[table] {
            ti = z
            like = "zimbra.`\(table)`"
        } else {
            throw SchemaMismatch("no table info for \(table)")
        }
        try dst.execute("CREATE TABLE IF NOT EXISTS `\(p.stage)`.`\(table)` LIKE \(like);")
        for i in ti.uniqueIndexes {
            try? dst.execute("ALTER TABLE `\(p.stage)`.`\(table)` DROP INDEX `\(i)`;")
        }
    }

    public func dropStage() throws {
        try dst.execute("DROP DATABASE IF EXISTS `\(p.stage)`;")
    }

    private func copy(_ schema: String, _ tables: [String], where whereClause: String,
                      replace: Bool = false, timeout: Double? = nil) throws -> Double {
        if tables.isEmpty { return 0.0 }
        return try remotePipe(src.host, try src.dumpCmd(db: schema, tables: tables,
                                                        where: whereClause, replace: replace),
                              dst.host, try dst.clientCmd(db: p.stage), dryRun: dry,
                              timeout: timeout) as Double
    }

    private func deltaTables() -> [String] {
        deltaTableNames.filter { p.groupTables[$0] != nil }
    }

    private func otherTables() -> [String] {
        p.groupTables.keys.filter { !deltaTableNames.contains($0) }
    }

    public func watermark() -> Int {
        let parts = deltaTables().map {
            "SELECT GREATEST(COALESCE(MAX(mod_metadata),0), COALESCE(MAX(mod_content),0)) AS w " +
            "FROM `\(p.srcGdb)`.`\($0)` WHERE mailbox_id=\(p.srcId)"
        }
        guard !parts.isEmpty else { return 0 }
        return Int(src.scalar("SELECT MAX(w) FROM (\(parts.joined(separator: " UNION ALL "))) x") ?? "") ?? 0
    }

    public func prestage(timeout: Double? = nil) throws -> [String: Any] {
        /// Online bulk copy. Watermark is read BEFORE the dump.
        try truncate(deltaTables())
        let w = watermark()
        let t0 = Date().timeIntervalSince1970
        try copy(p.srcGdb, deltaTables(), where: "mailbox_id=\(p.srcId)", timeout: timeout)
        let secs = Date().timeIntervalSince1970 - t0
        var rows = 0
        if !deltaTables().isEmpty && !dry {
            let q = deltaTables().map { "(SELECT COUNT(*) FROM `\(p.stage)`.`\($0)`)" }.joined(separator: " + ")
            rows = Int(dst.scalar("SELECT \(q)") ?? "") ?? 0
        }
        return ["watermark": w, "seconds": (round(secs * 100) / 100), "rows": rows]
    }

    private func truncate(_ tables: [String]) throws {
        if tables.isEmpty { return }
        try dst.execute(tables.map { "TRUNCATE TABLE `\(p.stage)`.`\($0)`;" }.joined(separator: "\n"))
    }

    public func final(strategy: String, watermark: Int?,
                      timeout: Double? = nil) throws -> [String: Any] {
        /// Runs while the source mailbox is locked.
        var info: [String: Any] = [:]
        let t0 = Date().timeIntervalSince1970
        let dts = deltaTables()
        if strategy == "delta", let w = watermark {
            try copy(p.srcGdb, dts, where: "mailbox_id=\(p.srcId) AND (mod_metadata>\(w) OR mod_content>\(w))",
                     replace: true, timeout: timeout)
            for t in dts {
                let ids = "_ids_\(t)"
                try dst.execute("DROP TABLE IF EXISTS `\(p.stage)`.`\(ids)`; " +
                                "CREATE TABLE `\(p.stage)`.`\(ids)` (id INT UNSIGNED PRIMARY KEY);")
                try remotePipe(src.host,
                               idListShellCmd(mysql: src, schema: p.srcGdb, table: t,
                                              mailboxId: p.srcId, target: ids),
                               dst.host, try dst.clientCmd(db: p.stage), dryRun: dry, timeout: timeout)
                try dst.execute("DELETE s FROM `\(p.stage)`.`\(t)` s " +
                                "LEFT JOIN `\(p.stage)`.`\(ids)` i ON s.id=i.id " +
                                "WHERE i.id IS NULL; DROP TABLE `\(p.stage)`.`\(ids)`;", db: p.stage)
            }
            info["mode"] = "delta"
        } else {
            try truncate(dts)
            try copy(p.srcGdb, dts, where: "mailbox_id=\(p.srcId)", timeout: timeout)
            info["mode"] = "full"
        }
        let others = otherTables()
        try truncate(others + Array(p.zimbraTables.keys) + ["mailbox"])
        try copy(p.srcGdb, others, where: "mailbox_id=\(p.srcId)", timeout: timeout)
        try copy("zimbra", Array(p.zimbraTables.keys), where: "mailbox_id=\(p.srcId)", timeout: timeout)
        try copy("zimbra", ["mailbox"], where: "id=\(p.srcId)", timeout: timeout)
        info["seconds"] = round((Date().timeIntervalSince1970 - t0) * 100) / 100
        return info
    }

    public func refullDeltaTables(timeout: Double? = nil) throws {
        let dts = deltaTables()
        try truncate(dts)
        try copy(p.srcGdb, dts, where: "mailbox_id=\(p.srcId)", timeout: timeout)
    }

    // ------------------------------------------------------------------ verification
    private func fingerprints(side: String, mode: String,
                             timeout: Double? = nil) throws -> [String: (String, String)] {
        var out: [String: (String, String)] = [:]
        for (t, ti) in p.groupTables {
            let schema: String, mid: Int
            var loc: String? = nil
            switch side {
            case "src": schema = p.srcGdb; mid = p.srcId
            case "stage": schema = p.stage; mid = p.srcId
            case "src_mapped":
                schema = p.srcGdb; mid = p.srcId
                loc = locatorCaseSQL(column: "`locator`", mapping: p.volMap)
            default: schema = p.dstGdb; mid = p.dstId
            }
            out[t] = try fp(side: side, schema: schema, ti: ti, key: "mailbox_id",
                            val: mid, loc: loc, mode: mode, timeout: timeout)
        }
        for (t, ti) in p.zimbraTables {
            let schema = side == "stage" ? p.stage : "zimbra"
            let mid = side == "live" ? p.dstId : p.srcId
            out["zimbra.\(t)"] = try fp(side: side, schema: schema, ti: ti,
                                        key: "mailbox_id", val: mid, loc: nil,
                                        mode: mode, timeout: timeout)
        }
        if let mb = p.mailboxTable {
            let schema = side == "stage" ? p.stage : "zimbra"
            let mid = side == "live" ? p.dstId : p.srcId
            out["zimbra.mailbox"] = try fp(side: side, schema: schema, ti: mb, key: "id",
                                           val: mid, loc: nil, mode: mode,
                                           exclude: mailboxRowLocalCols, timeout: timeout)
        }
        return out
    }

    private func fp(side: String, schema: String, ti: TableInfo, key: String, val: Int,
                    loc: String?, mode: String, exclude: [String] = [],
                    timeout: Double? = nil) throws -> (String, String) {
        let db = side.hasPrefix("src") ? src : dst
        if mode == "count" {
            return (db.scalar("SELECT COUNT(*) FROM `\(schema)`.`\(ti.name)` " +
                              "WHERE `\(key)`=\(val)", timeout: timeout) ?? "0", "-")
        }
        let rows = db.query(checksumSQL(schema: schema, table: ti, keyCol: key,
                                        keyVal: val, locatorExpr: loc, exclude: exclude),
                            timeout: timeout)
        if let r = rows.first, r.count >= 2 {
            return (r[0] as? String ?? "0", r[1] as? String ?? "0")
        }
        return ("0", "0")
    }

    public func compare(_ a: String, _ b: String, mode: String,
                        timeout: Double? = nil) throws -> [String] {
        if mode == "none" || dry { return [] }
        let fa = try fingerprints(side: a, mode: mode, timeout: timeout)
        let fb = try fingerprints(side: b, mode: mode, timeout: timeout)
        return fa.keys.sorted().compactMap { t -> String? in
            guard let va = fa[t] else { return nil }
            let same: Bool
            if let vb = fb[t] { same = va.0 == vb.0 && va.1 == vb.1 } else { same = false }
            guard !same else { return nil }
            let vb = fb[t].map { "\($0.0),\($0.1)" } ?? "(?,?)"
            return "\(t): \(a)=\(va.0),\(va.1) \(b)=\(vb)"
        }
    }

    // ------------------------------------------------------------------ merge / delete
    public func mergeSQL() -> String {
        let loc = locatorCaseSQL(column: "`locator`", mapping: p.volMap)
        var stmts = ["SET FOREIGN_KEY_CHECKS=0;", "START TRANSACTION;"]
        let mbOver = ["group_id": "\(p.dstGroup)", "index_volume_id": "\(p.dstIndexVolume)",
                      "itemcache_checkpoint": "`itemcache_checkpoint` + 1"]
        if let mb = p.mailboxTable {
            stmts.append(insertSelectSQL(dstSchema: "zimbra", stageSchema: p.stage, table: mb,
                                         keyCol: "id", newKey: p.dstId, overrides: mbOver))
        }
        for ti in p.zimbraTables.values {
            stmts.append(insertSelectSQL(dstSchema: "zimbra", stageSchema: p.stage, table: ti,
                                         keyCol: "mailbox_id", newKey: p.dstId))
        }
        for ti in p.groupTables.values {
            let over = ti.hasLocator ? ["locator": loc] : [:]
            stmts.append(insertSelectSQL(dstSchema: p.dstGdb, stageSchema: p.stage, table: ti,
                                         keyCol: "mailbox_id", newKey: p.dstId, overrides: over))
        }
        stmts.append("DELETE FROM zimbra.deleted_account WHERE email=\(q(p.account));")
        stmts += ["COMMIT;", "SET FOREIGN_KEY_CHECKS=1;"]
        return stmts.joined(separator: "\n")
    }

    public func merge(timeout: Double? = nil) throws {
        try dst.execute(mergeSQL(), timeout: timeout)
    }

    public static func deleteMailboxSQL(mailboxId: Int, gdb: String, groupTables: [String],
                                        zimbraTables: [String]) -> String {
        let mid = mailboxId
        var stmts = ["SET FOREIGN_KEY_CHECKS=0;", "START TRANSACTION;"]
        stmts += groupTables.map { "DELETE FROM `\(gdb)`.`\($0)` WHERE mailbox_id=\(mid);" }
        zimbraTables.forEach { stmts.append("DELETE FROM zimbra.`\($0)` WHERE mailbox_id=\(mid);") }
        stmts.append("DELETE FROM zimbra.mailbox WHERE id=\(mid);")
        stmts += ["COMMIT;", "SET FOREIGN_KEY_CHECKS=1;"]
        return stmts.joined(separator: "\n")
    }

    public func deleteLiveDst(timeout: Double? = nil) throws {
        try dst.execute(Self.deleteMailboxSQL(mailboxId: p.dstId, gdb: p.dstGdb,
                                              groupTables: Array(p.groupTables.keys),
                                              zimbraTables: Array(p.zimbraTables.keys)),
                        timeout: timeout)
    }

    /// Used by rollback to prove the destination copy is still untouched.
    public func liveMaxChange() throws -> Int { try liveState()[0] }

    public func liveState() throws -> [Int] {
        /// [max change number, row count] over the delta tables of the destination copy.
        /// The row count catches a hard delete of the newest item, which would bring MAX
        /// back down to its value at merge time and make the copy look untouched.
        let dts = p.groupTables.keys.filter { deltaTableNames.contains($0) }
        if dts.isEmpty { return [0, 0] }
        let parts = dts.map {
            "SELECT GREATEST(COALESCE(MAX(mod_metadata),0), COALESCE(MAX(mod_content),0)) AS w, " +
            "COUNT(*) AS n FROM `\(p.dstGdb)`.`\($0)` WHERE mailbox_id=\(p.dstId)"
        }
        let r = dst.query("SELECT COALESCE(MAX(w),0), COALESCE(SUM(n),0) FROM (\(parts.joined(separator: " UNION ALL "))) x")
        if let row = r.first, row.count >= 2 {
            return [Int(row[0] as? String ?? "") ?? 0, Int(row[1] as? String ?? "") ?? 0]
        }
        return [0, 0]
    }
}

public func reserveMailboxId(_ dst: MySQL, explicit: Int? = nil) throws -> Int {
    /// DbMailbox.getNextMailboxId equivalent, atomic in one transaction (row lock on
    /// current_volumes serialises with mailboxd's own allocations).
    if let e = explicit {
        let sql = "START TRANSACTION; UPDATE zimbra.current_volumes SET next_mailbox_id=" +
            "GREATEST(next_mailbox_id, \(e + 1)); " +
            "SELECT COUNT(*) FROM zimbra.mailbox WHERE id=\(e); COMMIT;"
        let rows = dst.query(sql)
        if let last = rows.last, last.first as? String != "0" {
            throw EngineMoveError("mailbox id \(e) already in use on \(dst.host.name)")
        }
        return e
    }
    let rows = dst.query("START TRANSACTION; UPDATE zimbra.current_volumes SET next_mailbox_id=" +
                         "next_mailbox_id + 1; SELECT next_mailbox_id - 1 FROM zimbra.current_volumes; COMMIT;")
    guard let last = rows.last, let v = last.first as? String, let id = Int(v) else {
        throw EngineMoveError("could not allocate mailbox id")
    }
    return id
}

private func idListShellCmd(mysql: MySQL, schema: String, table: String,
                            mailboxId: Int, target: String) throws -> String {
    let sel = "SELECT id FROM `\(schema)`.`\(table)` WHERE mailbox_id=\(mailboxId)"
    let awk = "awk -v T='\(target)' -v B=5000 " +
        "'{ if (n % B == 0) { if (n) print \";\"; printf \"INSERT INTO %s (id) VALUES (%s)\", T, $1 } " +
        "else printf \",(%s)\", $1; n++ } END { if (n) print \";\" }'"
    return try "\(mysql.clientCmd()) -e '\(sel)' | \(awk)"
}

private func remotePipe(_ src: Host, _ srcCmd: String, _ dst: Host, _ dstCmd: String,
                        dryRun: Bool, timeout: Double?) throws -> Double {
    try pipe(from: src, srcCmd, to: dst, dstCmd, timeout: timeout, dryRun: dryRun)
}

/// Move state machine (the part NE keeps closed-source in its MoveMailbox coordinator).
/// Port of engine.py: types, options, preflight planning.
import Foundation
import Glibc

private var reservedLock = NSLock()
private var reservedSpace: [String: [String: Int]] = [:]

private func reserveKey(_ host: String, _ mount: String) -> String { "\(host)\n\(mount)" }

public func reservedByOthers(key: (String, String), jobId: String) -> Int {
    reservedLock.lock(); defer { reservedLock.unlock() }
    return (reservedSpace[reserveKey(key.0, key.1)] ?? [:]).filter { $0.key != jobId }.values.reduce(0, +)
}

public func reserveSpace(jobId: String, needs: [String: Int]) {
    reservedLock.lock(); defer { reservedLock.unlock() }
    for (key, n) in needs { reservedSpace[key, default: [:]][jobId] = n }
}

public func releaseSpace(jobId: String) {
    reservedLock.lock(); defer { reservedLock.unlock() }
    for k in reservedSpace.keys { reservedSpace[k]?.removeValue(forKey: jobId) }
}

public let defaultOptions: [String: Any] = [
    "max_syncs": NSNull(),
    "sync_finish_threshold_ms": NSNull(),
    "blobs": "config",
    "secondary_blobs": "config",
    "search_index": "config",
    "skip_lockout": false,
    "skip_memcache_purge": false,
    "overwrite": false,
    "db_strategy": NSNull(),
    "verify": NSNull(),
    "cutover_window": NSNull(),
    "max_lock_seconds": NSNull(),
    "exclude_tables": [String](),
    "reindex_after": false,
    "flush_mta": true,
    "force": false,
    "keep_stage": false,
    "confirm_steps": false,
]

public struct EngineMoveError: Error, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { "MoveError: \(message)" }
}

public struct LockTimeout: Error, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { "LockTimeout: \(message)" }
}

public struct StepDeclined: Error, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { "StepDeclined: \(message)" }
}


public let confirmSteps = ["reserve", "online-sync", "lock", "final-sync",
                           "merge", "flip", "post-flip"]

public func stdinConfirm(prompt: String) -> Bool {
    if isatty(STDIN_FILENO) == 0 {
        fputs("declined: stdin is not a TTY; run interactively or drop --confirm-steps\n", stderr)
        return false
    }
    print(prompt, terminator: "")
    guard let line = readLine(strippingNewline: true) else { return false }
    let v = line.trimmingCharacters(in: .whitespaces).lowercased()
    return v == "y" || v == "yes"
}

public func parseWindow(_ window: String) throws -> (Int, Int) {
    let parts = window.split(separator: "-")
    guard parts.count == 2 else { throw EngineMoveError("bad cutover window \(window), want HH:MM-HH:MM") }
    func hm(_ s: Substring) throws -> (Int, Int) {
        let p = s.split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]),
              (0...23).contains(h), (0...59).contains(m) else {
            throw EngineMoveError("bad cutover window \(window), want HH:MM-HH:MM")
        }
        return (h, m)
    }
    let (ha, ma) = try hm(parts[0])
    let (hb, mb) = try hm(parts[1])
    return (ha * 60 + ma, hb * 60 + mb)
}

public func inWindow(_ window: String, now: Date = Date()) throws -> Bool {
    let (start, end) = try parseWindow(window)
    let comps = Calendar.current.dateComponents([.hour, .minute], from: now)
    let t = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    if start <= end { return start <= t && t < end }
    return t >= start || t < end
}

public func preMoveSnapshot(rep: [String: Any]) -> [String: Any] {
    let acct = rep["account"] as? [String: Any] ?? [:]
    return [
        "taken_at": Date().timeIntervalSince1970,
        "mail_host": acct["mail_host"] as? String ?? "",
        "status": acct["status"] as? String ?? "",
        "transport": acct["mail_transport"] as? String ?? "",
        "mailbox": rep["src_mailbox"] ?? [:],
        "volume_map": rep["volume_map"] ?? [:],
        "copy": rep["copy"] ?? [:],
    ]
}

public final class Engine {
    public var settings: Settings
    public var state: State
    public var dry: Bool
    public var progress: (String) -> Void
    public var confirm: (String) -> Bool
     internal var hosts: [String: Host] = [:]
     internal var servers: [String: ServerInfo] = [:]
     public var lockSemaphore: DispatchSemaphore? = nil
     /// Test hooks (monkeypatch equivalents): consulted first when set.
     internal var ctxHook: ((Job, Bool) throws -> Ctx)? = nil
     internal var planHook: ((Job) throws -> [String: Any])? = nil
     internal var lockoutHook: ((String, String, String) throws -> Void)? = nil

    public init(settings: Settings, state: State, dryRun: Bool = false,
                progress: ((String) -> Void)? = nil,
                confirm: ((String) -> Bool)? = nil) {
        self.settings = settings; self.state = state; self.dry = dryRun
        self.progress = progress ?? { _ in }
        self.confirm = confirm ?? stdinConfirm
    }

    // ------------------------------------------------------------------ helpers
    public func host(_ name: String) -> Host {
        if hosts[name] == nil {
            hosts[name] = Host(name: name, settings: settings, dryRun: dry)
        }
        return hosts[name]!
    }

    public func mysql(_ name: String) -> MySQL {
        MySQL(host: host(name), mysqlBin: settings.mysqlBin,
              mysqldumpBin: settings.mysqldumpBin,
              myCnf: settings.zimbraHome.hasSuffix("/")
                ? settings.zimbraHome + "conf/my.cnf"
                : settings.zimbraHome + "/conf/my.cnf")
    }

    public func soap(_ name: String) -> AdminSoap {
        AdminSoap(host: host(name), port: settings.adminPort,
                  user: settings.adminUser, password: settings.adminPassword,
                  verifyTLS: settings.verifyTLS, tlsCA: settings.tlsCa)
    }

    public func server(_ name: String, refresh: Bool = false) throws -> ServerInfo {
        if refresh || servers[name] == nil {
            servers[name] = try serverInfo(host: host(name), mysql: mysql(name))
        }
        return servers[name]!
    }

    public func opt(_ job: Job, _ key: String) -> Any? {
        if let v = job.options[key], !(v is NSNull) { return v }
        switch key {
        case "max_syncs": return settings.maxSyncs
        case "sync_finish_threshold_ms": return settings.syncFinishThresholdMs
        case "blobs": return "config"
        case "secondary_blobs": return "config"
        case "search_index": return "config"
        case "skip_lockout": return settings.skipLockout
        case "skip_memcache_purge": return settings.skipMemcachePurge
        case "overwrite": return false
        case "db_strategy": return settings.dbStrategy
        case "verify": return settings.verify
        case "cutover_window": return settings.cutoverWindow
        case "max_lock_seconds": return settings.maxLockSeconds
        case "exclude_tables": return settings.excludeTables
        case "reindex_after": return settings.reindexAfter
        case "flush_mta": return settings.flushMta
        case "force": return settings.force
        case "keep_stage": return settings.keepStage
        case "confirm_steps": return settings.confirmSteps
        case "rsync_timeout": return settings.rsyncTimeout
        case "db_timeout": return settings.dbTimeout
        default: return defaultOptions[key]
        }
    }

    public func optBool(_ job: Job, _ key: String) -> Bool {
        (opt(job, key) as? Bool) ?? false
    }

    public func optInt(_ job: Job, _ key: String) -> Int? {
        if let i = opt(job, key) as? Int { return i }
        if let d = opt(job, key) as? Double { return Int(d) }
        return nil
    }

    public func optString(_ job: Job, _ key: String) -> String? {
        opt(job, key) as? String
    }

    public func say(_ job: Job, _ msg: String, level: String = "info",
                    data: [String: Any] = [:]) {
        fputs("[zmove.engine] [\(job.id) \(job.account)] \(msg)\n", stderr)
        try? state.event(jobId: job.id, level: level, msg: msg, phase: job.phase, data: data)
        progress("[\(job.account)] \(msg)")
    }

    public func sayLite(account: String, msg: String) {
        fputs("[zmove.engine] [\(account)] \(msg)\n", stderr)
        progress("[\(account)] \(msg)")
    }

    public func setPhase(_ job: inout Job, _ ph: Phase, data: [String: Any] = [:]) throws {
        job.phase = ph
        for (k, v) in data { job.data[k] = v }
        try state.beat(job.id)
        try state.save(&job)
        say(job, "phase -> \(ph)")
    }

    public func deadlinePassed(job: Job) -> Bool {
        if let dl = job.data["lock_deadline"] as? Double {
            return Date().timeIntervalSince1970 > dl
        }
        return false
    }

    public func checkDeadline(job: Job) throws {
        if deadlinePassed(job: job) {
            throw LockTimeout("lock held longer than max_lock_seconds=\(optInt(job, "max_lock_seconds") ?? 0)")
        }
    }

    public func boundedTimeout(job: Job, base: Double?) -> Double? {
        guard let dl = job.data["lock_deadline"] as? Double else { return base }
        let left = max(0.0, dl - Date().timeIntervalSince1970)
        if let b = base { return min(b, left) }
        return left
    }

    public func deleteDstLive(dbm: DbMove, job: Job) throws {
        let rows = dbm.dst.query("SELECT account_id FROM zimbra.mailbox WHERE id=\(dbm.p.dstId)")
        if let r = rows.first, r.count > 0, let owner = r[0] as? String, owner != job.accountId {
            throw EngineMoveError("refusing to delete destination mailbox \(dbm.p.dstId): owned by another account")
        }
        try dbm.deleteLiveDst()
    }

    public func confirmStep(_ job: Job, step: String, detail: String) throws {
        guard optBool(job, "confirm_steps") else { return }
        guard let n = confirmSteps.firstIndex(of: step) else { return }
        var budget = ""
        if let dl = job.data["lock_deadline"] as? Double {
            budget = " (lock budget left: \(max(0, Int(dl - Date().timeIntervalSince1970)))s)"
        }
        let prompt = "[\(job.account) \(job.src)->\(job.dst)] step \(n + 1)/\(confirmSteps.count): \(step)\(budget)\n  \(detail)\nproceed? [y/N] "
        if !confirm(prompt) {
            throw StepDeclined("operator declined step '\(step)'; job saved at \(job.phase); resume to continue or abort to roll back")
        }
    }

    public func newJob(account: String, src: String, dst: String,
                       options: [String: Any]) throws -> Job {
        if src == dst { throw EngineMoveError("source and destination are the same server") }
        let acct = try accountInfo(host: host(dst), account: account)
        var opts = defaultOptions
        for (k, v) in options { opts[k] = v }
        return try state.create(account: acct.name, accountId: acct.id, src: src, dst: dst, options: opts)
    }

    public func resolve(_ mode: String?, cfgSkip: Bool) -> Bool {
        if mode == "include" { return true }
        if mode == "exclude" { return false }
        return !cfgSkip
    }

    public func dbPlan(jobId: String, accountName: String, accountId: String,
                       srcId: Int, srcGroup: Int,
                       dstIndexVolume: Int, dstId: Int, numGroups: Int,
                       vmap: [Int: Int], excludeTables: [String]) -> DbPlan {
        let dstGroup = (try? mailboxGroupId(dstId, numGroups: numGroups)) ?? 1
        return DbPlan(account: accountName, accountId: accountId, srcId: srcId,
                      srcGroup: srcGroup, dstId: dstId, dstGroup: dstGroup,
                      dstIndexVolume: dstIndexVolume, stage: "zmove_stage_\(jobId)",
                      volMap: vmap, excludeTables: excludeTables)
    }

    // ------------------------------------------------------------------ planning
     public func plan(job: Job) throws -> [String: Any] {
         if let h = planHook { return try h(job) }
         let srcH = host(job.src), dstH = host(job.dst)
        let srcI = try server(job.src, refresh: true)
        let dstI = try server(job.dst, refresh: true)
        let acct = try accountInfo(host: dstH, account: job.account)
        var errors: [String] = [], warnings: [String] = []

        if acct.mailHost != job.src && job.phase.rawValue < Phase.flipped.rawValue {
            errors.append("zimbraMailHost is \(acct.mailHost), not \(job.src) (NE 'src' safety check)")
        }
        for k in ["version", "db_version", "index_version"] {
            let a: String, b: String
            switch k {
            case "version": a = srcI.version; b = dstI.version
            case "db_version": a = srcI.dbVersion; b = dstI.dbVersion
            default: a = srcI.indexVersion; b = dstI.indexVersion
            }
            if a != b { errors.append("\(k) differs: \(job.src)=\(a) \(job.dst)=\(b)") }
        }
        if !dstI.hasMailClient {
            errors.append("specified targetHost does not correspond to a valid mailclient server " +
                          "with service webapp enabled: \(job.dst) (NE hasMailClient gate)")
        }
        let adminUser = (settings.adminUser ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if !adminUser.isEmpty && adminUser == acct.name.lowercased() {
            errors.append("Account being moved is the same as the one used for authentication. " +
                          "Administrators may not move themselves directly (NE MoveMailbox gate); " +
                          "rerun with another admin account")
        } else if adminUser.isEmpty {
            warnings.append("admin_user is not configured; NE self-move gate cannot be verified")
        }
        for h in [srcH, dstH] {
            if (try? h.run("zmmailboxdctl status", check: false, mutating: false).rc) ?? 1 != 0 {
                errors.append("mailboxd not running on \(h.name)")
            }
        }
        for (peer, pname) in [("src", job.src), ("dst", job.dst)] {
            var moves: [[String: Any]]? = nil
            do { moves = try soap(pname).queryMoves(job.account) } catch { moves = nil }
            if let m = moves, !m.isEmpty {
                warnings.append("NE reports an active move for \(job.account) on \(peer) \(pname): \(m) " +
                                "(zmove does not coordinate with it; wait or abort one side)")
            }
        }
        for pname in [job.src, job.dst] {
            do { _ = try soap(pname).token() }
            catch { errors.append("admin SOAP auth failed on \(pname): \(error)") }
        }
        guard let smb = mailboxRow(mysql: mysql(job.src), accountId: acct.id) else {
            errors.append("no mailbox for \(acct.name) on \(job.src)")
            return ["errors": errors, "warnings": warnings]
        }
        let dmb = mailboxRow(mysql: mysql(job.dst), accountId: acct.id, withStats: false)
        if let d = dmb, (job.data["dst_mailbox_id"] as? Int) != d.id {
            if (job.options["overwrite"] as? Bool) == true {
                warnings.append("destination already has mailbox id \(d.id) for this account; will be removed")
            } else {
                errors.append("destination already has a mailbox (id \(d.id)) for this account; use --overwrite")
            }
        }
        // stale JVM cache checks
        if let olds = try? state.find(account: acct.id, server: job.dst, limit: 1000) {
            for old in olds where old.id != job.id {
                var leftAt: Double? = nil
                if old.src == job.dst, old.phase.rawValue >= Phase.flipped.rawValue,
                   let f = old.data["flipped_at"] as? Double { leftAt = f }
                if old.dst == job.dst, let r = old.data["rolled_back_at"] as? Double { leftAt = r }
                guard let la = leftAt, !(job.options["force"] as? Bool ?? false) else { continue }
                let fix = "run: ssh zimbra@\(job.dst) 'zmmailboxdctl restart' " +
                    "(JVM holds stale accountId->mailboxId), then re-run preflight"
                if dstI.mailboxdStarted == nil {
                    errors.append("\(acct.name) was homed on \(job.dst) before (job \(old.id)) and mailboxd start time " +
                                  "is unknown; \(fix) or use --force")
                } else if la > Double(dstI.mailboxdStarted ?? 0) {
                    errors.append("\(acct.name) left \(job.dst) (job \(old.id)) after its mailboxd started; \(fix) or use --force")
                }
            }
        }
        if let dt = opt(job, "db_strategy") as? String, dt == "delta",
           (opt(job, "verify") as? String) != "full", !optBool(job, "force") {
            errors.append("db_strategy=delta needs verify=full: rows changed without a new change number are only " +
                          "caught by the full fingerprint (use --verify full, --db-strategy full or --force)")
        }
        let copyBlobs = resolve(optString(job, "blobs"), cfgSkip: dstI.moveSkipBlobs)
        let copySec = resolve(optString(job, "secondary_blobs"), cfgSkip: dstI.moveSkipHsmBlobs)
        let copyIdx = resolve(optString(job, "search_index"), cfgSkip: dstI.moveSkipIndex)
        let shared = settings.sharedVolumes
        let srcMsg = srcI.volumes.filter { $0.isMessage }
        for v in srcMsg {
            let wantsCopy = copyBlobs && (copySec || v.type != typeMessageSecondary)
            if !wantsCopy && shared[v.id] == nil {
                errors.append("blobs on volume \(v.id) excluded but no shared_volumes mapping for it " +
                              "(exclude is only valid when the destination sees the same storage)")
            }
        }
        guard let idxVol = (try? srcI.volume(smb.indexVolumeId)) else {
            errors.append("source index volume \(smb.indexVolumeId) missing")
            return ["errors": errors, "warnings": warnings]
        }
        for v in srcMsg + [idxVol] {
            if shared[v.id] != nil && v.storeType == storeInternal &&
                !(srcI.blobDirServerId && dstI.blobDirServerId) {
                errors.append("shared_volumes maps internal volume \(v.id), but " +
                              "zimbraConfiguredServerIDForBlobDirEnabled is not TRUE on both servers: " +
                              "mailbox dirs of the two servers would collide on the shared storage")
            }
        }
        let vmap: [Int: Int]
        do {
            vmap = try mapVolumes(srcVols: srcMsg + [idxVol], dstVols: dstI.volumes,
                                  dstCurrentMsg: dstI.currentMsg,
                                  dstCurrentSecondary: dstI.currentSecondary,
                                  dstCurrentIndex: dstI.currentIndex, explicit: shared)
        } catch {
            errors.append("\(error)")
            return ["errors": errors, "warnings": warnings]
        }
        let dstId = job.data["dst_mailbox_id"] as? Int ?? 0
        let bs = BlobSync(settings, src: srcH, dst: dstH)
        var need: [Int: Int] = [:]
        var externalVols = Set<Int>()
        var plans: [DirPlan] = []
        do {
            plans = try dirPlans(srcI: srcI, dstI: dstI, srcId: smb.id,
                                 dstId: dstId != 0 ? dstId : 999999999,
                                 vmap: vmap, copyIdx: copyIdx, srcIdxVol: idxVol.id)
        } catch {
            errors.append("\(error)")
            return ["errors": errors, "warnings": warnings]
        }
        for p in plans {
            if p.shared || p.external { continue }
            let srcs = (try? bs.existingSrcDirs(p)) ?? []
            let sz = (try? bs.du(host: srcH, dirs: srcs)) ?? 0
            need[p.dstVolume, default: 0] += sz
            for s in p.srcVolumes where (try? srcI.volume(s)).map({ $0.storeType }) != storeInternal {
                externalVols.insert(s)
            }
        }
        var fsNeed: [String: Int] = [:]
        var fsFree: [String: Int] = [:]
        var fsWhat: [String: [String]] = [:]
        func addNeed(path: String, n: Int, what: String) {
            guard let info = try? bs.fsFree(host: dstH, path: path) else {
                warnings.append("cannot determine free space for \(path) on \(job.dst)")
                return
            }
            let key = "\(job.dst):\(info.mount)"
            fsNeed[key, default: 0] += n
            fsFree[key] = info.free
            fsWhat[key, default: []].append(what)
        }
        for (vid, n) in need {
            if let vol = try? dstI.volume(vid) { addNeed(path: vol.path, n: n, what: "volume \(vid)") }
        }
        let r = try? srcH.run("ssh -p \(settings.nodeSshPort) \(settings.nodeSshOptions) " +
                              "\(shellQuote(settings.nodeSshUser + "@" + job.dst)) true",
                              check: false, mutating: false)
        if (r?.rc ?? 1) != 0 {
            errors.append("node SSH \(job.src) -> \(settings.nodeSshUser)@\(job.dst):\(settings.nodeSshPort) failed " +
                          "(rsync needs it); fix keys/known_hosts or node_ssh_* settings")
        }
        var dbm = DbMove(plan: dbPlan(jobId: job.id, accountName: acct.name, accountId: acct.id,
                                      srcId: smb.id, srcGroup: smb.groupId,
                                      dstIndexVolume: dstI.currentIndex, dstId: dstId != 0 ? dstId : 1,
                                      numGroups: dstI.numGroups, vmap: vmap,
                                      excludeTables: opt(job, "exclude_tables") as? [String] ?? []),
                         src: mysql(job.src), dst: mysql(job.dst), dryRun: dry)
        var dbBytes = 0
        do {
            try dbm.discover()
            dbBytes = dbm.estimateBytes()
        } catch {
            errors.append("\(error)")
        }
        if dbBytes > 0 {
            let datadir = (try? dstH.out("zmlocalconfig -m nokey mysql_data_directory")) ?? ""
            let dd = datadir.isEmpty ? "\(settings.zimbraHome.hasSuffix("/") ? String(settings.zimbraHome.dropLast()) : settings.zimbraHome)/db/data" : datadir
            addNeed(path: dd, n: 2 * dbBytes, what: "MySQL datadir (stage + live)")
        }
        var reserve: [String: Int] = [:]
        for (key, n) in fsNeed {
            let want = Int(Double(n) * 1.1) + (1 << 30)
            let others = reservedByOthers(key: (job.dst, String(key.split(separator: ":", maxSplits: 1).last ?? "")), jobId: job.id)
            let free = fsFree[key] ?? 0
            if free - others < want {
                errors.append("not enough space on \(job.dst):\(key) (\(fsWhat[key]?.joined(separator: ", ") ?? "")): need ~\(want)B, " +
                              "free \(free)B" + (others > 0 ? " minus \(others)B promised to running moves" : ""))
            }
            reserve[key] = want
        }
        var rep: [String: Any] = [
            "account": ["name": acct.name, "id": acct.id, "mail_host": acct.mailHost,
                        "mail_transport": acct.mailTransport, "status": acct.status,
                        "aliases": acct.aliases],
            "src_mailbox": ["id": smb.id, "group_id": smb.groupId,
                            "index_volume_id": smb.indexVolumeId,
                            "items": smb.items, "size": smb.size],
            "dst_mailbox": dmb.map { ["id": $0.id] as [String: Any] } ?? NSNull(),
            "copy": ["blobs": copyBlobs, "secondary_blobs": copySec, "search_index": copyIdx],
            "volume_map": vmap.mapValues { $0 },
            "bytes_to_copy": need.values.reduce(0, +),
            "db_bytes": dbBytes,
            "reserve": Dictionary(uniqueKeysWithValues: reserve.map { kv -> (String, Int) in
                let parts = kv.key.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                return ("\(parts[0]):\(parts.count > 1 ? parts[1] : "")", kv.value) }),
            "external_volumes": externalVols.sorted(),
            "group_tables": dbm.p.groupTables.keys.sorted(),
            "zimbra_tables": dbm.p.zimbraTables.keys.sorted(),
        ]
        if dstId != 0 {
            rep["dst_group_exists"] = mysql(job.dst).schemaExists(dbm.p.dstGdb)
        } else {
            rep["dst_group_exists"] = NSNull()
        }
        rep["errors"] = errors
        rep["warnings"] = warnings
        return rep
    }
    public func dirPlans(srcI: ServerInfo, dstI: ServerInfo, srcId: Int, dstId: Int,
                         vmap: [Int: Int], copyIdx: Bool, srcIdxVol: Int) throws -> [DirPlan] {
        // NOTE: blobs/index land directly under the *reserved* dst mailbox id (no TempDir
        // staging). Safe: the destination zimbra.mailbox row is INSERTed only at merge time,
        // so mailboxd has no mailbox object for dst_id and never serves the directory.
        let shared = settings.sharedVolumes
        var byDst: [Int: DirPlan] = [:]
        for sv in srcI.volumes where sv.isMessage {
            guard let mapped = vmap[sv.id] else { continue }
            let dv = try dstI.volume(mapped)
            let external = sv.storeType != storeInternal || dv.storeType != storeInternal
            var p = byDst[dv.id] ?? DirPlan(kind: "msg", dstVolume: dv.id,
                                            dstDir: dv.mailboxDir(dstId, serverIdPrefix: dstI.pathPrefix),
                                            shared: shared[sv.id] != nil, external: external)
            if p.shared != (shared[sv.id] != nil) {
                throw EngineMoveError("volumes mapped to dst \(dv.id) mix shared and non-shared storage")
            }
            p.external = p.external || external
            p.srcDirs.append(sv.mailboxDir(srcId, serverIdPrefix: srcI.pathPrefix))
            p.srcVolumes.append(sv.id)
            byDst[dv.id] = p
        }
        var plans = Array(byDst.values)
        if copyIdx {
            let sv = try srcI.volume(srcIdxVol)
            guard let mapped = vmap[sv.id] else {
                throw EngineMoveError("index volume \(sv.id) has no destination mapping")
            }
            let dv = try dstI.volume(mapped)
            plans.append(DirPlan(kind: "index", dstVolume: dv.id,
                                 dstDir: dv.mailboxDir(dstId, serverIdPrefix: dstI.pathPrefix),
                                 srcDirs: [sv.mailboxDir(srcId, serverIdPrefix: srcI.pathPrefix)],
                                 srcVolumes: [sv.id], shared: shared[sv.id] != nil))
        }
        for p in plans where p.shared && !p.external {
            let dst = p.dstDir.hasSuffix("/") ? String(p.dstDir.dropLast()) : p.dstDir
            let srcs = p.srcDirs.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
            if srcs.contains(dst) {
                throw EngineMoveError("source and destination mailbox dir are the same on shared storage " +
                                      "(\(p.dstDir)); enable zimbraConfiguredServerIDForBlobDirEnabled")
            }
        }
        return plans
    }

    public struct Ctx {
        public var dbm: DbMove
        public var plans: [DirPlan]
        public var bs: BlobSync
    }

     public func ctx(job: Job, prepare: Bool = true) throws -> Ctx {
         if let h = ctxHook { return try h(job, prepare) }
         /// Rebuild DB/blob plans from the journal. prepare=true also makes sure the
         /// destination group schema and the stage exist (needed to copy); cleanup
         /// paths pass prepare=false.
         let srcI = try server(job.src), dstI = try server(job.dst)
        let d = job.data
        let vmapRaw = d["volume_map"] as? [String: Int] ?? [:]
        let vmap = Dictionary(uniqueKeysWithValues: vmapRaw.compactMap { k, v in Int(k).map { ($0, v) } })
        func iv(_ v: Any?) -> Int { (v as? Int) ?? Int((v as? Double) ?? 0) }
        let smbId = iv(d["src_mailbox_id"]), smbGroup = iv(d["src_group"])
        let smbIdx = iv(d["src_index_volume"])
        let dstId = iv(d["dst_mailbox_id"])
        let copy = d["copy"] as? [String: Any] ?? [:]
        let copySearch = copy["search_index"] as? Bool ?? true
        let plan = DbPlan(account: job.account, accountId: job.accountId,
                          srcId: smbId, srcGroup: smbGroup, dstId: dstId,
                          dstGroup: (try? mailboxGroupId(dstId, numGroups: dstI.numGroups)) ?? 1,
                          dstIndexVolume: dstI.currentIndex, stage: "zmove_stage_\(job.id)",
                          volMap: vmap,
                          excludeTables: opt(job, "exclude_tables") as? [String] ?? [])
        let dbm = DbMove(plan: plan, src: mysql(job.src), dst: mysql(job.dst), dryRun: dry)
        try dbm.discover()
        if prepare {
            try dbm.ensureDstGroupDb()
            try dbm.createStage()
        }
        let plans = try dirPlans(srcI: srcI, dstI: dstI, srcId: smbId, dstId: dstId,
                                 vmap: vmap, copyIdx: copySearch, srcIdxVol: smbIdx)
        return Ctx(dbm: dbm, plans: plans,
                   bs: BlobSync(settings, src: host(job.src), dst: host(job.dst)))
    }

    public func rsyncTimeout(job: Job) -> Double? {
        let t = optInt(job, "rsync_timeout") ?? 0
        return t > 0 ? Double(t) : nil
    }

    public func dbTimeout(job: Job) -> Double? {
        let t = opt(job, "db_timeout") as? Int ?? 0
        return t > 0 ? Double(t) : nil
    }

     public func ma(_ host: Host, _ account: String, attrs: [String: String], check: Bool = true) throws {
         /// zmprov -l ma; sorted keys keep multi-attr commands deterministic.
         let args = attrs.sorted { $0.key < $1.key }.map { "\($0.key) \(shellQuote($0.value))" }.joined(separator: " ")
         try host.run("zmprov -l ma \(shellQuote(account)) \(args)", check: check)
     }

    @discardableResult
    public func restoreStatus(_ h: Host, job: Job, status: String) throws -> Bool {
        /// Put zimbraAccountStatus back, but ONLY if the account is still in the
        /// maintenance state zmove itself set.
        var cur = "maintenance"
        do { cur = try accountInfo(host: h, account: job.account).status } catch {}
        if cur != "maintenance" {
            say(job, "zimbraAccountStatus is '\(cur)' (changed outside zmove); leaving it", level: "warning")
            return false
        }
        try ma(h, job.account, attrs: ["zimbraAccountStatus": status])
        flushAccountCache(host: h, account: job.account)
        return true
    }

    public func dstClaimedElsewhere(job: Job, dbm: DbMove) throws -> String? {
        guard let dstId = job.data["dst_mailbox_id"] as? Int else { return nil }
        let others = try state.find(account: job.accountId, server: job.dst, limit: 1000)
            .filter { $0.id != job.id }
        for o in others {
            if o.dst != job.dst || (o.data["dst_mailbox_id"] as? Int) != dstId { continue }
            if !["running", "failed", "done"].contains(o.status) { continue }
            var purged = false
            for p in others where p.src == job.dst {
                if let pm = p.data["src_mailbox_id"] as? Int, pm == dstId,
                   p.phase.rawValue >= Phase.purged.rawValue, p.created > o.created { purged = true }
            }
            if !purged {
                return "mailbox id \(dstId) on \(job.dst) belongs to job \(o.id) (\(o.status))"
            }
        }
        if job.phase.rawValue < Phase.flipped.rawValue {
            do {
                let home = try accountInfo(host: host(job.dst), account: job.account).mailHost
                if home == job.dst { return "\(job.account) is homed on \(job.dst)" }
            } catch {
                return "cannot verify zimbraMailHost of \(job.account) (\(error))"
            }
        }
        return nil
    }

    public func cleanupDst(job: Job, dbm: DbMove, plans: [DirPlan], bs: BlobSync) throws {
        if let reason = try dstClaimedElsewhere(job: job, dbm: dbm) {
            say(job, "keeping destination mailbox \(dbm.p.dstId): \(reason)", level: "warning")
        } else {
            let live = dbm.dst.query("SELECT COUNT(*) FROM zimbra.mailbox WHERE id=\(dbm.p.dstId)")
            if live.first?.first as? String != "0" { try deleteDstLive(dbm: dbm, job: job) }
            let still = dbm.dst.query("SELECT COUNT(*) FROM zimbra.mailbox WHERE id=\(dbm.p.dstId)")
            if (still.first?.first as? String) != "0" && !dry {
                say(job, "mailbox id \(dbm.p.dstId) still in use on \(job.dst); not removing its blob dirs", level: "warning")
            } else {
                try bs.removeDirs(host(job.dst), plans.filter { !$0.external }.map { $0.dstDir })
            }
        }
        try dbm.dropStage()
    }

}

/// Engine run loop and mutating phases. Port of engine.py run paths.
import Foundation

private final class AtomicBool {
    private let lock = NSLock()
    private var _v: Bool
    init(_ v: Bool) { _v = v }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _v }
        set { lock.lock(); defer { lock.unlock() }; _v = newValue }
    }
}

extension Engine {
     public func checkRunnable(job: Job) throws {
         if job.data["rolled_back_at"] != nil {
             throw EngineMoveError("job \(job.id) was rolled back; start a new move instead")
         }
         if job.phase.rawValue >= Phase.purged.rawValue {
             throw EngineMoveError("job \(job.id) is purged; nothing to resume")
         }
         if job.status == "done" {
             throw EngineMoveError("job \(job.id) is already done")
         }
         if job.status == "aborted" && job.phase.rawValue >= Phase.flipped.rawValue {
             throw EngineMoveError("job \(job.id) was aborted after cutover; start a new move instead")
         }
         if state.ownerAlive(job) && !optBool(job, "force") {
             let age = Int(Date().timeIntervalSince1970 - job.heartbeat)
             throw EngineMoveError("job \(job.id) is still being run by \(job.owner ?? "?") " +
                 "(heartbeat \(age)s ago); wait for it, or use --force if that process is really gone")
         }
         if job.status == "aborted" {
             if let other = try? state.activeFor(job.accountId), other.id != job.id {
                 throw AlreadyMoving("ALREADY_BEING_MOVED: \(job.account) has active job \(other.id)")
             }
         }
     }

    @discardableResult
    public func run(_ job: inout Job) throws -> Job {
        try checkRunnable(job: job)
        job.status = "running"; job.error = nil; job.owner = State.ownerTag()
        try state.save(&job)
        defer { releaseSpace(jobId: job.id) }
        // heartbeat while long rsync/DB steps run
        let stop = AtomicBool(false)
        let jid = job.id, st = state
        let hb = Thread {
            while !stop.value {
                Thread.sleep(forTimeInterval: State.heartbeatStale / 4)
                if stop.value { break }
                try? st.beat(jid)
            }
        }
        hb.name = "zmove-hb-\(job.id)"
        hb.qualityOfService = .background
        hb.start()
        defer { stop.value = true }
        do {
            try _run(&job)
        } catch {
            if error is StepDeclined { throw error }
            throw error
        }
        return job
    }

    private func fail(job: inout Job, _ e: Error) throws {
        job.error = "\(type(of: e))(\(e))"
        job.status = job.phase.rawValue < Phase.reserved.rawValue ? "aborted" : "failed"
        try state.save(&job)
        say(job, "FAILED in \(job.phase): \(job.error ?? "")", level: "error")
        if (job.phase.rawValue >= Phase.locked.rawValue && job.phase.rawValue < Phase.flipped.rawValue)
            || job.data["locking"] != nil {
            say(job, "account is still LOCKED on source; run `zmove resume \(job.id)` or `zmove abort \(job.id)`", level: "error")
        } else if job.phase.rawValue >= Phase.flipped.rawValue && job.phase.rawValue < Phase.unlocked.rawValue {
            say(job, "account is in maintenance on \(job.dst); run `zmove resume \(job.id)` to finish the cutover", level: "error")
        }
    }

    private func onLockTimeout(job: inout Job, _ e: Error) {
        say(job, "watchdog: \(e); aborting and unlocking", level: "error")
        job.error = "\(e)"
        do {
            var jj = job
            _ = try abort(job: &jj, reason: "lock watchdog")
            job = jj
        } catch {
            say(job, "watchdog abort incomplete: \(error)", level: "error")
        }
    }

    private func _run(_ job: inout Job) throws {
        do {
            if job.phase.rawValue < Phase.preflightOK.rawValue { try preflight(job: &job) }
            if job.phase.rawValue < Phase.reserved.rawValue { try reserve(job: &job) }
            let c = try ctx(job: job, prepare: job.phase.rawValue < Phase.flipped.rawValue)
            if job.phase.rawValue < Phase.flipped.rawValue {
                let fresh = job.phase.rawValue < Phase.locked.rawValue
                if fresh { try onlinePhase(job: &job, dbm: c.dbm, plans: c.plans, bs: c.bs) }
                if lockSemaphore != nil { lockSemaphore!.wait() }
                do {
                    defer { lockSemaphore?.signal() }
                    if fresh {
                        try lock(job: &job)
                    } else {
                        try relock(job: &job)
                    }
                    if job.phase.rawValue < Phase.flipped.rawValue {
                        try lockedPhase(job: &job, dbm: c.dbm, plans: c.plans, bs: c.bs)
                    }
                }
            }
            try postFlip(job: &job, dbm: c.dbm)
        } catch let e as LockTimeout {
            onLockTimeout(job: &job, e)
            throw e
        } catch let e as TimeoutError where job.phase.rawValue < Phase.flipped.rawValue && deadlinePassed(job: job) {
            let lt = LockTimeout("lock budget exhausted during a long command (\(Int(e.seconds))s cap)")
            onLockTimeout(job: &job, lt)
            throw lt
        } catch let e as StepDeclined {
            job.status = job.phase.rawValue < Phase.reserved.rawValue ? "aborted" : "failed"
            try? state.save(&job)
            say(job, "PAUSED in \(job.phase): \(e.message)", level: "warning")
            if job.phase.rawValue >= Phase.locked.rawValue && job.phase.rawValue < Phase.flipped.rawValue {
                say(job, "account is still LOCKED on source; run `zmove resume \(job.id)` or `zmove abort \(job.id)`", level: "warning")
            }
            throw e
        } catch {
            try fail(job: &job, error)
            throw error
        }
    }

    // ------------------------------------------------------------------ phases
    public func preflight(job: inout Job) throws {
        if let dt = opt(job, "db_strategy") as? String, dt == "delta",
           (opt(job, "verify") as? String) != "full", !optBool(job, "force") {
            throw EngineMoveError("db_strategy=delta needs verify=full: rows changed without a new change number are only " +
                                  "caught by the full fingerprint (use --verify full, --db-strategy full or --force)")
        }
        let rep = try plan(job: job)
        if let warns = rep["warnings"] as? [String] {
            for w in warns { say(job, "warning: \(w)", level: "warning") }
        }
        if let errs = rep["errors"] as? [String], !errs.isEmpty {
            throw EngineMoveError("preflight failed:\n  - " + errs.joined(separator: "\n  - "))
        }
        if let reserve = rep["reserve"] as? [String: Int] {
            var needs: [String: Int] = [:]
            for (k, v) in reserve {
                if let c = k.firstIndex(of: ":") {
                    needs["\(k[..<c])\n\(k[k.index(after: c)...])"] = v
                }
            }
            reserveSpace(jobId: job.id, needs: needs)
        }
        guard let smb = rep["src_mailbox"] as? [String: Any],
              let acct = rep["account"] as? [String: Any] else {
            throw EngineMoveError("preflight report missing account/mailbox")
        }
        func iv(_ v: Any?) -> Int { (v as? Int) ?? Int((v as? Double) ?? 0.0) }
        try setPhase(&job, .preflightOK, data: [
            "volume_map": rep["volume_map"] as Any,
            "copy": rep["copy"] as Any,
            "src_mailbox_id": iv(smb["id"]), "src_group": iv(smb["group_id"]),
            "src_index_volume": iv(smb["index_volume_id"]),
            "items": iv(smb["items"]), "size": iv(smb["size"]),
            "orig_status": acct["status"] as? String ?? "active",
            "orig_transport": acct["mail_transport"] as? String ?? "",
            "stray_dst_mailbox": (rep["dst_mailbox"] as? [String: Any])?["id"] as Any? as Any,
            "aliases": acct["aliases"] ?? [],
            "snapshot": preMoveSnapshot(rep: rep),
        ])
    }

    public func reserve(job: inout Job) throws {
        let stray = job.data["stray_dst_mailbox"] as? Int
        var detail = "allocate a mailbox id on \(job.dst) + create stage schema zmove_stage_\(job.id)"
        if let s = stray, (job.options["overwrite"] as? Bool) == true {
            detail += "; DELETE stray mailbox \(s) on \(job.dst)"
        }
        try confirmStep(job, step: "reserve", detail: detail)
        let dst = mysql(job.dst)
        if let stray = stray, (job.options["overwrite"] as? Bool) == true {
            let row = dst.query("SELECT account_id, group_id FROM zimbra.mailbox WHERE id=\(stray)")
            guard let r = row.first, r.count >= 2, let owner = r[0] as? String,
                  owner == job.accountId, let gid = r[1] as? String else {
                throw EngineMoveError("refusing to remove stray destination mailbox \(stray): not owned by \(job.account)")
            }
            let gdb = "mboxgroup\(gid)"
            let gt = dst.tables(withColumn: "mailbox_id", in: gdb)
            let zt = dst.tables(withColumn: "mailbox_id", in: "zimbra").filter { zimbraMailboxTables.contains($0) }
            try dst.execute(DbMove.deleteMailboxSQL(mailboxId: stray, gdb: gdb, groupTables: gt, zimbraTables: zt))
            say(job, "removed stray destination mailbox \(stray)", level: "warning")
        }
        var explicit: Int? = nil
        if let rec = try? state.purgeRecord(accountId: job.accountId, server: job.dst), !dry {
            let rows = dst.query("SELECT COUNT(*) FROM zimbra.mailbox WHERE id=\(rec.0)")
            if rows.first?.first as? String == "0" { explicit = rec.0 }
        }
        let dstId: Int
        if dry {
            dstId = explicit ?? 999999
        } else {
            dstId = try reserveMailboxId(dst, explicit: explicit)
        }
        let dstI = try server(job.dst)
        try setPhase(&job, .reserved,
                     data: ["dst_mailbox_id": dstId,
                            "dst_group": (try? mailboxGroupId(dstId, numGroups: dstI.numGroups)) ?? 1])
        _ = try ctx(job: job, prepare: true)
    }

    public func onlinePhase(job: inout Job, dbm: DbMove, plans: [DirPlan], bs: BlobSync) throws {
        var detail = "rsync \(plans.count) blob/index dirs"
        let strategy = (opt(job, "db_strategy") as? String) ?? "delta"
        detail += " + DB prestage (\(strategy)); account stays online"
        try confirmStep(job, step: "online-sync", detail: detail)
        let maxs = optInt(job, "max_syncs") ?? 10
        let thr = optInt(job, "sync_finish_threshold_ms") ?? 180000
        let jid = job.id, jacct = job.account
        let passes = try bs.converge(plans: plans, maxSyncs: maxs, thresholdMs: thr,
                                     onPass: { [self] i, st in
                                         try? self.state.beat(jid)
                                         self.sayLite(account: jacct,
                                                      msg: "presync pass \(i): \(st.files) files, \(st.bytes) B, " +
                                                      String(format: "%.1f", st.seconds) + "s")
                                     },
                                     timeout: boundedTimeout(job: job, base: rsyncTimeout(job: job).map(Double.init(_:))))
        let lastSecs: Double
        if let last = passes.last { lastSecs = round(last.seconds * 100) / 100 } else { lastSecs = 0 }
        try setPhase(&job, .presync, data: ["presync_passes": passes.count, "last_pass_seconds": lastSecs])
        if strategy == "delta" {
            let w = dbm.watermark()
            let info = try dbm.final(strategy: "delta", watermark: w,
                                     timeout: boundedTimeout(job: job, base: dbTimeout(job: job).map(Double.init(_:))))
            try setPhase(&job, .prestaged, data: ["watermark": w, "prestage": info])
        } else {
            try setPhase(&job, .prestaged, data: ["watermark": NSNull()])
        }
        if let window = opt(job, "cutover_window") as? String {
            say(job, "waiting for cutover window \(window) (keeping replicas warm)")
            var last = Date().timeIntervalSince1970
            while !(try inWindow(window)) {
                Thread.sleep(forTimeInterval: 30)
                try state.beat(job.id)
                if Date().timeIntervalSince1970 - last > 1800 {
                    _ = try bs.syncOnce(plans: plans, timeout: boundedTimeout(job: job, base: rsyncTimeout(job: job).map(Double.init(_:))))
                    last = Date().timeIntervalSince1970
                }
            }
            _ = try bs.converge(plans: plans, maxSyncs: maxs, thresholdMs: thr,
                                timeout: boundedTimeout(job: job, base: rsyncTimeout(job: job).map(Double.init(_:))))
        }
    }

    public func checkHome(job: Job) throws -> AccountInfo {
        let info = try accountInfo(host: host(job.dst), account: job.account)
        if info.mailHost != job.src {
            throw EngineMoveError("zimbraMailHost is now \(info.mailHost), not \(job.src); refusing to lock (re-run preflight)")
        }
        return info
    }

    public func startLockBudget(job: Job) -> Double? {
        let mx = optInt(job, "max_lock_seconds") ?? 0
        return mx > 0 ? Date().timeIntervalSince1970 + Double(mx) : nil
    }

    public func lock(job: inout Job) throws {
        try confirmStep(job, step: "lock",
                        detail: "set \(job.account) maintenance + LockoutMailbox(start) on \(job.src); user-visible outage starts")
        _ = try checkHome(job: job)
        if job.data["orig_status"] as? String != "maintenance" {
            job.data["orig_status"] = (try? accountInfo(host: host(job.dst), account: job.account).status) ?? "active"
        }
        job.data["locking"] = true
        try state.save(&job)
        let anyH = host(job.dst)
        try ma(anyH, job.account, attrs: ["zimbraAccountStatus": "maintenance"])
        flushAccountCache(host: anyH, account: job.account)
        if !optBool(job, "skip_lockout") {
            try lockout(server: job.src, account: job.account, op: "start")
        }
        job.data.removeValue(forKey: "locking")
        var extra: [String: Any] = ["locked_at": Date().timeIntervalSince1970]
        if let dl = startLockBudget(job: job) { extra["lock_deadline"] = dl }
        try setPhase(&job, .locked, data: extra)
    }

    public func relock(job: inout Job) throws {
        if job.phase == .merged {
            let home = (try? accountInfo(host: host(job.dst), account: job.account).mailHost) ?? ""
            if home == job.dst {
                say(job, "zimbraMailHost already \(job.dst): committing FLIPPED", level: "warning")
                let port = (try? server(job.dst).lmtpPort) ?? 7025
                try setPhase(&job, .flipped,
                             data: ["flipped_at": Date().timeIntervalSince1970,
                                    "new_transport": replaceHostInTransport(job.data["orig_transport"] as? String ?? "", job.dst, port: port)])
                return
            }
        }
        try confirmStep(job, step: "lock",
                        detail: "re-assert maintenance + LockoutMailbox(start) on \(job.src) (resume a locked job)")
        _ = try checkHome(job: job)
        let anyH = host(job.dst)
        try ma(anyH, job.account, attrs: ["zimbraAccountStatus": "maintenance"])
        flushAccountCache(host: anyH, account: job.account)
        if !optBool(job, "skip_lockout") {
            try lockout(server: job.src, account: job.account, op: "start")
        }
        if let dl = startLockBudget(job: job) { job.data["lock_deadline"] = dl }
        if job.data["locked_at"] == nil { job.data["locked_at"] = Date().timeIntervalSince1970 }
        try state.save(&job)
        if job.phase.rawValue > Phase.locked.rawValue {
            try setPhase(&job, .locked)
        }
    }

 
     public func lockout(server: String, account: String, op: String) throws {
         if let h = lockoutHook { try h(server, account, op); return }
         do {
             try soap(server).lockout(account: account, op: op)
         } catch let e as SoapFault {
            let benign = (op == "start" && e.code.uppercased().contains("MAINTENANCE")) ||
                (op == "end" && (e.code == "service.NOT_FOUND" || e.code == "account.NO_SUCH_ACCOUNT"))
            if !benign { throw e }
        }
    }

    public func lockedPhase(job: inout Job, dbm: DbMove, plans: [DirPlan], bs: BlobSync) throws {
        let verify = (opt(job, "verify") as? String) ?? "full"
        func dbt() -> Double? { boundedTimeout(job: job, base: dbTimeout(job: job).map(Double.init(_:))) }
        if job.phase.rawValue < Phase.finalSynced.rawValue {
            try confirmStep(job, step: "final-sync", detail: "final rsync --checksum while locked")
            let st = try bs.syncOnce(plans: plans, final: true,
                                     timeout: boundedTimeout(job: job, base: rsyncTimeout(job: job).map(Double.init(_:))))
            try checkDeadline(job: job)
            try setPhase(&job, .finalSynced, data: ["final_sync": ["files": st.files, "bytes": st.bytes, "seconds": st.seconds]])
        }
        if job.phase.rawValue < Phase.verified.rawValue {
            let strategy = (opt(job, "db_strategy") as? String) ?? "delta"
            let wm = job.data["watermark"] as? Int
            var info = try dbm.final(strategy: strategy, watermark: wm, timeout: dbt())
            _ = info
            try setPhase(&job, .dbFinal, data: ["db_final": info])
            try checkDeadline(job: job)
            var diff = try dbm.compare("src", "stage", mode: verify, timeout: dbt())
            if !diff.isEmpty && (info["mode"] as? String) == "delta" {
                say(job, "delta verification mismatch -> full re-copy of item tables", level: "warning")
                try dbm.refullDeltaTables(timeout: dbt())
                diff = try dbm.compare("src", "stage", mode: verify, timeout: dbt())
            }
            if !diff.isEmpty { throw VerifyError("stage != source: " + diff.joined(separator: "; ")) }
            for p in plans where !p.external {
                let srcs = try bs.existingSrcDirs(p)
                let a = try bs.inventory(host: p.shared ? host(job.dst) : host(job.src), dirs: srcs)
                let b = try bs.inventory(host: host(job.dst), dirs: [p.dstDir])
                if a != b && !dry {
                    throw VerifyError("\(p.kind) inventory differs for \(p.dstDir): src=\(a) dst=\(b)")
                }
            }
            try checkDeadline(job: job)
            try setPhase(&job, .verified)
        }
        if job.phase.rawValue < Phase.merged.rawValue {
            try confirmStep(job, step: "merge",
                            detail: "insert stage into live tables on \(job.dst) as mailbox \(dbm.p.dstId)")
            let cnt = dbm.dst.query("SELECT COUNT(*) FROM zimbra.mailbox WHERE id=\(dbm.p.dstId)")
            if cnt.first?.first as? String != "0" { try deleteDstLive(dbm: dbm, job: job) }
            try checkDeadline(job: job)
            try dbm.merge(timeout: dbTimeout(job: job).map(Double.init(_:)))
            let diff = try dbm.compare("src_mapped", "live", mode: verify, timeout: dbt())
            if !diff.isEmpty {
                try dbm.deleteLiveDst()
                throw VerifyError("live != source after merge (rolled back): " + diff.joined(separator: "; "))
            }
            try checkDeadline(job: job)
            let st = (try? dbm.liveState()) ?? [0, 0]
            try setPhase(&job, .merged, data: ["merged_max_change": st[0], "merged_state": st])
        }
        try flip(job: &job)
    }

    public func flip(job: inout Job) throws {
        try confirmStep(job, step: "flip", detail: "set zimbraMailHost=\(job.dst) -- POINT OF NO RETURN")
        try checkDeadline(job: job)
        let h = host(job.dst)
        let origTransport = job.data["orig_transport"] as? String ?? ""
        let port = (try? server(job.dst).lmtpPort) ?? 7025
        let transport = replaceHostInTransport(origTransport, job.dst, port: port)
        if !origTransport.isEmpty && transport == origTransport && !origTransport.lowercased().hasPrefix("lmtp") {
            say(job, "keeping non-LMTP mailTransport \(origTransport); verify it routes to \(job.dst)", level: "warning")
        }
        try ma(h, job.account, attrs: ["zimbraMailHost": job.dst, "zimbraMailTransport": transport])
        try setPhase(&job, .flipped, data: ["flipped_at": Date().timeIntervalSince1970, "new_transport": transport])
    }

    public func postFlip(job: inout Job, dbm: DbMove) throws {
        if job.phase == .done { return }
        try confirmStep(job, step: "post-flip", detail: "purge caches, restore account status, drop stage")
        let h = host(job.dst)
        if job.phase.rawValue < Phase.cachesPurged.rawValue {
            flushAccountCache(host: h, account: job.account)
            if !optBool(job, "skip_memcache_purge") {
                let aliases = job.data["aliases"] as? [String] ?? []
                purgeProxyRoutes(host: h, account: job.account, aliases: aliases)
                let n = (try? deleteMemcachedKeys(host: h, accountId: job.accountId)) ?? 0
                say(job, "memcached account keys deleted: \(n)")
            }
            try setPhase(&job, .cachesPurged)
        }
        if job.phase.rawValue < Phase.unlocked.rawValue {
            _ = try restoreStatus(h, job: job, status: job.data["orig_status"] as? String ?? "active")
            let locked = Date().timeIntervalSince1970 - (job.data["locked_at"] as? Double ?? Date().timeIntervalSince1970)
            try setPhase(&job, .unlocked, data: ["lock_seconds": round(locked * 100) / 100])
        }
        if job.phase.rawValue < Phase.done.rawValue {
            let copySearch = ((job.data["copy"] as? [String: Any])?["search_index"] as? Bool) ?? true
            if !copySearch || optBool(job, "reindex_after") {
                _ = try? h.run("zmprov rim \(shellQuote(job.account)) start", check: false)
                say(job, "re-index started on destination")
            }
            if optBool(job, "flush_mta") {
                var mta = settings.mtaHosts
                if mta.isEmpty { mta = (try? mtaServers(host: h)) ?? [] }
                if !mta.isEmpty {
                    let aliases = job.data["aliases"] as? [String] ?? []
                    let n = flushMtaQueues(hosts: mta.map { host($0) }, account: job.account,
                                           zimbraHome: settings.zimbraHome, aliases: aliases)
                    say(job, "rescheduled \(n) deferred message(s) for this account")
                } else {
                    say(job, "no MTA hosts configured or discovered; deferred mail will retry on normal schedule", level: "warning")
                }
            }
            if !optBool(job, "keep_stage") { try dbm.dropStage() }
            job.status = "done"
            if dry { job.data["dry_run"] = true }
            try setPhase(&job, .done)
            say(job, "move complete; user-visible lock \(job.data["lock_seconds"] ?? "?")s; " +
                     "run `zmove purge` later to reclaim \(job.src)")
            writeMetrics(job: job)
        }
    }

    // ------------------------------------------------------------------ abort / rollback
     public func restoreSource(job: Job) -> [String] {
         var errors: [String] = []
         if !optBool(job, "skip_lockout") {
             do {
                 try lockout(server: job.src, account: job.account, op: "end")
             } catch {
                 errors.append("LockoutMailbox(end) on \(job.src): \(error)")
             }
         }
         let status = job.data["orig_status"] as? String ?? "active"
         var ordered: [String] = []
         for hn in [job.src, job.dst] where !ordered.contains(hn) { ordered.append(hn) }
         var restored = false
         for hn in ordered {
             do {
                 _ = try restoreStatus(host(hn), job: job, status: status)
                 restored = true
                 break
             } catch {
                 errors.append("restore zimbraAccountStatus=\(status) via \(hn): \(error)")
             }
         }
         if restored {
             return errors.filter { !$0.hasPrefix("restore zimbraAccountStatus") }
         }
         return errors
     }

    @discardableResult
    public func abort(job: inout Job, reason: String = "manual") throws -> Job {
        if job.phase.rawValue >= Phase.flipped.rawValue {
            throw EngineMoveError("job \(job.id) is past the point of no return (FLIPPED); use `zmove rollback`")
        }
         if job.status == "running" && state.ownerAlive(job) {
             throw EngineMoveError("job \(job.id) is still being run by \(job.owner ?? "?"); stop it first")
         }
        if job.phase.rawValue >= Phase.reserved.rawValue {
            do {
                let c = try ctx(job: job, prepare: false)
                do {
                    try cleanupDst(job: job, dbm: c.dbm, plans: c.plans, bs: c.bs)
                } catch {
                    say(job, "abort: destination cleanup error \(error)", level: "warning")
                }
            } catch {
                say(job, "abort: cannot rebuild context (\(error)); dropping stage only, run `zmove gc` later for destination leftovers", level: "warning")
                do {
                    try mysql(job.dst).execute("DROP DATABASE IF EXISTS `zmove_stage_\(job.id)`;")
                } catch {
                    say(job, "abort: stage drop error \(error)", level: "warning")
                }
            }
        }
        var errors: [String] = []
        if job.phase.rawValue >= Phase.locked.rawValue || job.data["locking"] != nil {
            errors = restoreSource(job: job)
        }
        job.error = (job.error ?? "") + " [aborted: \(reason)]"
        if job.phase.rawValue > Phase.reserved.rawValue { job.phase = .reserved }
        for k in ["watermark", "prestage", "merged_max_change", "merged_state", "lock_deadline"] {
            job.data.removeValue(forKey: k)
        }
        if !errors.isEmpty {
            job.status = "failed"
            job.data["locking"] = true
            job.error = (job.error ?? "") + " [source NOT restored: " + errors.joined(separator: "; ") + "]"
            try state.save(&job)
            say(job, "abort incomplete, source still locked: \(errors.joined(separator: "; "))", level: "error")
            throw EngineMoveError("abort could not restore \(job.account) on \(job.src); fix and run `zmove abort \(job.id)` or `zmove unlock \(job.account) -s <server>`")
        }
        job.data.removeValue(forKey: "locking")
        job.data.removeValue(forKey: "locked_at")
        job.status = "aborted"
        try state.save(&job)
        say(job, "aborted (\(reason)); source restored", level: "warning")
        return job
    }

    public func gcJob(job: inout Job) -> String {
        if job.phase.rawValue >= Phase.flipped.rawValue { return "skipped (past cutover)" }
        if job.status == "failed" {
            do { _ = try abort(job: &job, reason: "gc") } catch { return "abort failed: \(error)" }
            return "aborted"
        }
        if job.data["gc_at"] != nil { return "skipped (already cleaned)" }
        if job.phase.rawValue >= Phase.reserved.rawValue, job.data["dst_mailbox_id"] != nil {
            if let c = try? ctx(job: job, prepare: false) {
                try? cleanupDst(job: job, dbm: c.dbm, plans: c.plans, bs: c.bs)
            }
        } else {
            try? mysql(job.dst).execute("DROP DATABASE IF EXISTS `zmove_stage_\(job.id)`;")
        }
        if !dry {
            job.data["gc_at"] = Date().timeIntervalSince1970
            try? state.save(&job)
        }
        return "cleaned"
    }

    @discardableResult
    public func rollback(job: inout Job, force: Bool = false) throws -> Job {
        if job.data["dry_run"] != nil {
            throw EngineMoveError("job \(job.id) is a dry run; nothing was moved")
        }
        if job.data["rolled_back_at"] != nil {
            throw EngineMoveError("job \(job.id) is already rolled back")
        }
        if job.phase.rawValue < Phase.flipped.rawValue {
            return try abort(job: &job, reason: "rollback before flip")
        }
        if job.phase.rawValue >= Phase.purged.rawValue {
            throw EngineMoveError("source copy already purged; do a reverse move instead")
        }
        let c = try ctx(job: job, prepare: false)
        let h = host(job.dst)
        let before = (try? accountInfo(host: h, account: job.account).status) ?? "active"
        let origStatus = (job.data["orig_status"] as? String) ?? "active"
        let target = before == "maintenance" ? origStatus : before
        try ma(h, job.account, attrs: ["zimbraAccountStatus": "maintenance"])
        flushAccountCache(host: h, account: job.account)
        let cur = (try? c.dbm.liveState()) ?? [0, 0]
        let changed: Bool
        if let mm = job.data["merged_state"] as? [Int], mm.count == 2 {
            changed = cur != mm
        } else {
            changed = cur[0] != (job.data["merged_max_change"] as? Int ?? -1)
        }
        if changed && !force {
            try ma(h, job.account, attrs: ["zimbraAccountStatus": target])
            flushAccountCache(host: h, account: job.account)
            throw EngineMoveError("destination mailbox changed since cutover (change \(cur) vs " +
                                  "\(job.data["merged_state"] ?? job.data["merged_max_change"] as Any); do a reverse move or --force")
        }
        try ma(h, job.account, attrs: ["zimbraMailHost": job.src,
                                       "zimbraMailTransport": job.data["orig_transport"] as? String ?? ""])
        let aliases = job.data["aliases"] as? [String] ?? []
        purgeProxyRoutes(host: h, account: job.account, aliases: aliases)
        _ = try? deleteMemcachedKeys(host: h, accountId: job.accountId)
        if !optBool(job, "skip_lockout") {
            try lockout(server: job.src, account: job.account, op: "end")
        }
        try ma(h, job.account, attrs: ["zimbraAccountStatus": target])
        flushAccountCache(host: h, account: job.account)
        job.data["rolled_back_at"] = Date().timeIntervalSince1970
        job.status = "aborted"
        job.error = "rolled back after cutover"
        try state.save(&job)
        do {
            try cleanupDst(job: job, dbm: c.dbm, plans: c.plans, bs: c.bs)
        } catch {
            say(job, "rollback: destination cleanup error \(error)", level: "warning")
        }
        say(job, "rolled back: account served from source again; restart mailboxd on " +
                 "\(job.dst) before moving this account there again", level: "warning")
        return job
    }

    // ------------------------------------------------------------------ purge / unlock
    @discardableResult
    public func purge(job: inout Job, keepBlobs: Bool = false) throws -> Job {
        guard job.phase == .done, job.status == "done" else {
            throw EngineMoveError("job \(job.id) is not a finished move (phase=\(job.phase), status=\(job.status))")
        }
        if job.data["rolled_back_at"] != nil {
            throw EngineMoveError("job \(job.id) was rolled back; its source copy is live")
        }
        if job.data["dry_run"] != nil {
            throw EngineMoveError("job \(job.id) is a dry run; refusing to purge a live mailbox")
        }
        let acct = try accountInfo(host: host(job.dst), account: job.account)
        if acct.mailHost == job.src {
            throw EngineMoveError("\(job.account) is homed on \(job.src) again; refusing to purge it")
        }
        if let later = try state.find(account: job.accountId, limit: 1000).first(where: {
            $0.id != job.id && $0.created > job.created && ["running", "failed"].contains($0.status)
        }) {
            throw EngineMoveError("\(job.account) has an unfinished later move (job \(later.id)); finish or abort it first")
        }
        let srcI = try server(job.src, refresh: true)
        guard let mid = job.data["src_mailbox_id"] as? Int,
              let gid = job.data["src_group"] as? Int else {
            throw EngineMoveError("job \(job.id) has no recorded source mailbox")
        }
        let src = mysql(job.src)
        guard let cur = mailboxRow(mysql: src, accountId: job.accountId, withStats: false),
              cur.id == mid else {
            throw EngineMoveError("mailbox \(mid) for \(job.account) not found on \(job.src) (already purged?)")
        }
        let gdb = "mboxgroup\(gid)"
        let gt = src.tables(withColumn: "mailbox_id", in: gdb)
        let zt = src.tables(withColumn: "mailbox_id", in: "zimbra").filter { zimbraMailboxTables.contains($0) }
        try src.execute(DbMove.deleteMailboxSQL(mailboxId: mid, gdb: gdb, groupTables: gt, zimbraTables: zt))
        if !keepBlobs {
            let idxVol = job.data["src_index_volume"] as? Int ?? -1
            let dirs = srcI.volumes.filter {
                ($0.isMessage || $0.id == idxVol) && $0.storeType == storeInternal
            }.map { $0.mailboxDir(mid, serverIdPrefix: srcI.pathPrefix) }
            try BlobSync(settings, src: host(job.src), dst: host(job.src)).removeDirs(host(job.src), dirs)
        }
        try state.recordPurge(accountId: job.accountId, server: job.src, mailboxId: mid)
        job.phase = .purged
        job.data["purged_at"] = Date().timeIntervalSince1970
        try state.save(&job)
        say(job, "purged old mailbox \(mid) on \(job.src)")
        return job
    }

    public func unlock(account: String, server: String?) throws {
        guard let server = server, !server.isEmpty else {
            throw EngineMoveError("--server is required")
        }
        let anyH = host(server)
        let acct = try accountInfo(host: anyH, account: account)
        if let j = try state.activeFor(acct.id), j.phase.rawValue < Phase.flipped.rawValue {
            var jj = j
            do { _ = try abort(job: &jj, reason: "unlocked manually") }
            catch { say(jj, "unlock: abort of job \(jj.id) failed: \(error)", level: "warning") }
        }
        let last = try state.find(account: acct.id, limit: 1).first
        var status = "active"
        if let s = last?.data["orig_status"] as? String { status = s }
        let cur = (try? accountInfo(host: anyH, account: acct.name).status) ?? ""
        if cur == "maintenance" {
            try ma(anyH, acct.name, attrs: ["zimbraAccountStatus": status])
            flushAccountCache(host: anyH, account: acct.name)
        } else {
            fputs("[zmove] unlock: \(acct.name) status is '\(cur)' (not maintenance); left unchanged\n", stderr)
        }
        try lockout(server: acct.mailHost, account: account, op: "end")
    }

    // ------------------------------------------------------------------ metrics
    private func label(_ v: String) -> String {
        v.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    public func writeMetrics(job: Job) {
        _ = try? state.pruneEvents(maxAgeDays: 30)
        guard let path = settings.metricsTextfile,
              let jobs = try? state.find(status: "done", limit: 500) else { return }
        var lines: [String] = []
        for j in jobs {
            let lab = [("account", j.account), ("src", j.src), ("dst", j.dst), ("job", j.id)]
                .map { "\($0.0)=\"\(label($0.1))\"" }.joined(separator: ",")
            func num(_ k: String) -> Any { j.data[k] ?? 0 }
            lines.append("zmove_lock_seconds{\(lab)} \(num("lock_seconds"))")
            lines.append("zmove_items{\(lab)} \(num("items"))")
            lines.append("zmove_bytes{\(lab)} \(num("bytes"))")
            let pre = j.data["prestage"] as? [String: Any] ?? [:]
            let dbf = j.data["db_final"] as? [String: Any] ?? [:]
            let fins = j.data["final_sync"] as? [String: Any] ?? [:]
            lines.append("zmove_db_prestage_seconds{\(lab)} \(pre["seconds"] ?? 0)")
            lines.append("zmove_db_final_seconds{\(lab)} \(dbf["seconds"] ?? 0)")
            lines.append("zmove_blob_final_bytes{\(lab)} \(fins["bytes"] ?? 0)")
            lines.append("zmove_presync_passes{\(lab)} \(j.data["presync_passes"] ?? 0)")
        }
        let header = ["zmove_lock_seconds", "zmove_items", "zmove_bytes",
                      "zmove_db_prestage_seconds", "zmove_db_final_seconds",
                      "zmove_blob_final_bytes", "zmove_presync_passes"]
            .map { "# TYPE \($0) gauge" }.joined(separator: "\n")
        let tmp = path + ".tmp"
        do {
            try (header + "\n" + lines.joined(separator: "\n") + "\n")
                .write(toFile: tmp, atomically: true, encoding: .utf8)
            _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path),
                                                      withItemAt: URL(fileURLWithPath: tmp))
        } catch {
            fputs("[zmove] metrics write failed: \(error)\n", stderr)
        }
    }
}

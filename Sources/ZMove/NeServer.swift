/// NE-faithful server-side move coordinator (MoveMailbox.handleNetworkRequest/moveIt).
/// Runs the destination-side task: checks, RegisterMailboxMoveOut, unlocked rsync
/// rounds, source lock, final sync, full DB copy while locked, cutover, cache
/// purge, unregister. No journal (like MailboxMoveThread); a crash needs operator
/// cleanup (drop stage schema + dst blob dirs, unlock source).
///
/// Differences from `zmove move` (engine.py): no delta prestage, no
/// verify-after-copy beyond what NE does, direct-to-live import via merge.
import Foundation

public let neDefaultMaxSyncs = 10
public let neDefaultSyncThresholdMs = 180000

public struct NeMoveError: Error, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { "NeMoveError: \(message)" }
}

public final class NeServerMove {
    public let settings: Settings
    public let lockSemaphore: DispatchSemaphore?

    public init(settings: Settings, lockSemaphore: DispatchSemaphore? = nil) {
        self.settings = settings
        self.lockSemaphore = lockSemaphore
    }

    private func say(_ msg: String, level: String = "info") {
        _ = level
        fputs("[zmove.ne] \(msg)\n", stderr)
    }

    public func resolve(_ mode: String?, cfgSkip: Bool) -> Bool {
        if mode == "include" { return true }
        if mode == "exclude" { return false }
        return !cfgSkip
    }

     internal var hosts: [String: Host] = [:]
     internal var soapFactory: ((String) -> AdminSoap)? = nil
 
     internal func host(_ name: String) -> Host {
         if hosts[name] == nil { hosts[name] = Host(name: name, settings: settings) }
         return hosts[name]!
     }
 
     internal func soap(_ name: String) -> AdminSoap {
         if let f = soapFactory { return f(name) }
         return AdminSoap(host: host(name), port: settings.adminPort,
                   user: settings.adminUser, password: settings.adminPassword,
                   verifyTLS: settings.verifyTLS, tlsCA: settings.tlsCa)
     }

    private func mysql(_ name: String) -> MySQL {
        MySQL(host: host(name), mysqlBin: settings.mysqlBin,
              mysqldumpBin: settings.mysqldumpBin,
              myCnf: settings.zimbraHome.hasSuffix("/") ? settings.zimbraHome + "conf/my.cnf" : settings.zimbraHome + "/conf/my.cnf")
    }

    private func server(_ name: String, refresh: Bool = false) throws -> ServerInfo {
        try serverInfo(host: host(name), mysql: mysql(name))
    }

    // ------------------------------------------------------------------ input
    public struct NeInputs {
        public var account: AccountInfo
        public var srcInfo: ServerInfo
        public var dstInfo: ServerInfo
        public var srcMailboxId: Int
        public var srcGroupId: Int
        public var srcIndexVolumeId: Int
    }

    public func check(account: String, src: String, dst: String,
                      options: [String: Any]) throws -> NeInputs {
        for h in [src, dst] { _ = try soap(h).token() }
        let acct = try accountInfo(host: host(dst), account: account)
        guard acct.mailHost == src else {
            throw NeMoveError("Account \(acct.name) is not on server \(src); source server should be \(acct.mailHost)")
        }
        let srcI = try server(src, refresh: true)
        let dstI = try server(dst, refresh: true)
        if !dstI.hasMailClient {
            throw NeMoveError("specified targetHost does not correspond to a valid mailclient server " +
                              "with service webapp enabled: \(dst) (NE hasMailClient gate)")
        }
        guard let smb = mailboxRow(mysql: mysql(src), accountId: acct.id, withStats: true) else {
            throw NeMoveError("no mailbox for \(acct.name) on \(src)")
        }
        let dmb = mailboxRow(mysql: mysql(dst), accountId: acct.id, withStats: false)
        if dmb != nil {
            throw NeMoveError("A mailbox already exists (id=\(dmb!.id)) on this server for account \(acct.name); " +
                              "purge it with zmpurgeoldmbox first")
        }
        return NeInputs(account: acct, srcInfo: srcI, dstInfo: dstI,
                        srcMailboxId: smb.id, srcGroupId: smb.groupId, srcIndexVolumeId: smb.indexVolumeId)
    }

    // ------------------------------------------------------------------ plan
    public struct NePlan {
        public var dbm: DbMove
        public var plans: [DirPlan]
        public var bs: BlobSync
        public var volMap: [Int: Int]
        public var copyBlobs: Bool
        public var copySecondary: Bool
        public var copyIndex: Bool
    }

    public func build(account: AccountInfo, src: String, dst: String,
                      options: [String: Any], inp: NeInputs) throws -> NePlan {
        let srcI = inp.srcInfo, dstI = inp.dstInfo
        let copyBlobs = resolve(options["blobs"] as? String, cfgSkip: dstI.moveSkipBlobs)
        let copySec = resolve(options["secondary_blobs"] as? String, cfgSkip: dstI.moveSkipHsmBlobs)
        let copyIdx = resolve(options["search_index"] as? String, cfgSkip: dstI.moveSkipIndex)
        let shared = settings.sharedVolumes
        let srcVolumes = srcI.volumes
        let srcMsg = srcVolumes.filter { $0.isMessage }
        for v in srcMsg {
            let wantsCopy = copyBlobs && (copySec || v.type != typeMessageSecondary)
            if !wantsCopy && shared[v.id] == nil {
                throw NeMoveError("blobs on volume \(v.id) excluded but no shared_volumes mapping for it " +
                                  "(exclude is only valid when the destination sees the same storage)")
            }
        }
        guard let idxVol = (try? srcI.volume(inp.srcIndexVolumeId)) else {
            throw NeMoveError("source index volume \(inp.srcIndexVolumeId) missing")
        }
        let vmap: [Int: Int]
        do {
            vmap = try mapVolumes(srcVols: srcMsg + [idxVol], dstVols: dstI.volumes,
                                  dstCurrentMsg: dstI.currentMsg,
                                  dstCurrentSecondary: dstI.currentSecondary,
                                  dstCurrentIndex: dstI.currentIndex, explicit: shared)
        } catch {
            throw NeMoveError("\(error)")
        }
        let dstId = try reserveMailboxId(mysql(dst))
        let plan = DbPlan(account: acctName(account), accountId: account.id,
                          srcId: inp.srcMailboxId, srcGroup: inp.srcGroupId,
                          dstId: dstId,
                          dstGroup: (try? mailboxGroupId(dstId, numGroups: dstI.numGroups)) ?? 1,
                          dstIndexVolume: dstI.currentIndex,
                          stage: "zmove_stage_ne_\(UUID().uuidString.prefix(8).lowercased())",
                          volMap: vmap,
                          excludeTables: options["exclude_tables"] as? [String] ?? [])
        let dbm = DbMove(plan: plan, src: mysql(src), dst: mysql(dst))
        try dbm.discover()
        try dbm.ensureDstGroupDb()
        try dbm.createStage()
        var byDst: [Int: DirPlan] = [:]
        for sv in srcMsg where vmap[sv.id] != nil {
            let dv = try dstI.volume(vmap[sv.id]!)
            let external = sv.storeType != storeInternal || dv.storeType != storeInternal
            var p = byDst[dv.id] ?? DirPlan(kind: "msg", dstVolume: dv.id,
                                            dstDir: dv.mailboxDir(dstId, serverIdPrefix: dstI.pathPrefix),
                                            shared: shared[sv.id] != nil, external: external)
            p.external = p.external || external
            p.srcDirs.append(sv.mailboxDir(inp.srcMailboxId, serverIdPrefix: srcI.pathPrefix))
            p.srcVolumes.append(sv.id)
            byDst[dv.id] = p
        }
        var plans = Array(byDst.values)
        if copyIdx {
            let dv = try dstI.volume(vmap[idxVol.id] ?? -1)
            plans.append(DirPlan(kind: "index", dstVolume: dv.id,
                                 dstDir: dv.mailboxDir(dstId, serverIdPrefix: dstI.pathPrefix),
                                 srcDirs: [idxVol.mailboxDir(inp.srcMailboxId, serverIdPrefix: srcI.pathPrefix)],
                                 srcVolumes: [idxVol.id],
                                 shared: shared[idxVol.id] != nil))
        }
        return NePlan(dbm: dbm, plans: plans, bs: BlobSync(settings, src: host(src), dst: host(dst)),
                      volMap: vmap, copyBlobs: copyBlobs, copySecondary: copySec, copyIndex: copyIdx)
    }

    private func acctName(_ a: AccountInfo) -> String { a.name }

    // ------------------------------------------------------------------ run
    @discardableResult
    public func run(account: String, src: String, dst: String,
                    options: [String: Any], sync: Bool = true) throws -> [String: Any] {
        if !sync {
            let settings = self.settings
            let opts = options
            let th = Thread {
                do {
                    let m = NeServerMove(settings: settings)
                    _ = try m.run(account: account, src: src, dst: dst, options: opts, sync: true)
                } catch {
                    fputs("[zmove.ne] background move failed: \(error)\n", stderr)
                }
            }
            th.name = "ne-move-\(account)"
            th.qualityOfService = .utility
            th.start()
            print("Mailbox move started"); fflush(stdout)
            return ["thread": true, "account": account, "src": src, "dst": dst]
        }
        return try runGuarded(account: account, src: src, dst: dst, options: options)
    }

    public func runGuarded(account: String, src: String, dst: String,
                           options: [String: Any]) throws -> [String: Any] {
        let inp = try check(account: account, src: src, dst: dst, options: options)
        let acct = inp.account
        let pl = try build(account: acct, src: src, dst: dst, options: options, inp: inp)
         try register(account: acct.name, src: src, dst: dst)
        let maxSyncs = (options["max_syncs"] as? Int) ?? neDefaultMaxSyncs
        let threshold = (options["sync_finish_threshold_ms"] as? Int) ?? neDefaultSyncThresholdMs
        let skipLockout = (options["skip_lockout"] as? Bool) ?? false
        let skipMemcache = (options["skip_memcache_purge"] as? Bool) ?? false
        let verify = (options["verify"] as? String) ?? "full"
        let started = Date().timeIntervalSince1970
        say("unlocked sync: up to \(maxSyncs) passes")
        for rnd in 1...max(1, maxSyncs) {
            let st = try pl.bs.syncOnce(plans: pl.plans)
            say("rsync round \(rnd): \(st.files) files, \(st.bytes) B, " +
                String(format: "%.1f", st.seconds) + "s")
            if st.seconds * 1000 <= Double(threshold) || st.files == 0 { break }
        }
        try lock(account: acct.name, src: src, dst: dst, skipLockout: skipLockout)
        defer { unlockAndUnregister(account: acct.name, src: src, dst: dst, skipLockout: skipLockout) }
        let fs = try pl.bs.syncOnce(plans: pl.plans, final: true)
        say("final rsync: \(fs.files) files, \(fs.bytes) B, " +
            String(format: "%.1f", fs.seconds) + "s")
        let info = try pl.dbm.final(strategy: "full", watermark: nil)
        say("database copied while locked: \(info)")
        var diff = try pl.dbm.compare("src", "stage", mode: verify, timeout: nil)
        if !diff.isEmpty {
            throw VerifyError("stage != source: " + diff.joined(separator: "; "))
        }
        try pl.dbm.merge()
        diff = try pl.dbm.compare("src_mapped", "live", mode: verify, timeout: nil)
        if !diff.isEmpty {
            try? pl.dbm.deleteLiveDst()
            throw VerifyError("live != source after merge: " + diff.joined(separator: "; "))
        }
        try flip(account: acct, dst: dst, origTransport: acct.mailTransport)
        postFlip(account: acct, dst: dst, skipMemcache: skipMemcache)
        if !(options["keep_stage"] as? Bool ?? false) { try? pl.dbm.dropStage() }
        say("Mailbox move completed successfully (\(Int(Date().timeIntervalSince1970 - started))s)")
        return ["account": acct.name, "src": src, "dst": dst,
                "dst_mailbox_id": pl.dbm.p.dstId,
                "seconds": Date().timeIntervalSince1970 - started]
    }

     /// RegisterMailboxMoveOut on the source (ALREADY_BEING_MOVED_OUT aborts;
     /// absent handler (FOSS) degrades to a warning so the same flow runs FOSS-to-FOSS).
     internal func register(account: String, src: String, dst: String) throws {
         do {
             try soap(src).call("RegisterMailboxMoveOutRequest",
                                payload: ["account": ["name": account, "target": dst]])
         } catch let e as SoapFault where e.code.hasSuffix("UNKNOWN_DOCUMENT")
                                         || e.code.hasSuffix("UNKNOWN_SERVICE") {
             say("source has no move-out registry (FOSS); continuing without it")
         } catch let e as SoapFault {
             throw NeMoveError("register move-out on \(src) failed: \(e.code): \(e.reason)")
         }
     }
 
     internal func unregister(account: String, src: String, dst: String) {
         do {
             try soap(src).call("UnregisterMailboxMoveOutRequest",
                                payload: ["account": ["name": account, "target": dst]])
         } catch {
             say("unregister move-out on \(src) failed: \(error)", level: "warning")
         }
     }
 
     internal func lock(account: String, src: String, dst: String, skipLockout: Bool) throws {
        let h = host(dst)
        let acct = try accountInfo(host: h, account: account)
        if acct.mailHost != src {
            throw NeError("zimbraMailHost is now \(acct.mailHost), not \(src); refusing to lock")
        }
        try ma(h, account: account, attrs: ["zimbraAccountStatus": "maintenance"])
        flushAccountCache(host: h, account: account)
        if !skipLockout {
            try soap(src).lockout(account: account, op: "start")
        }
    }

    private func flip(account: AccountInfo, dst: String, origTransport: String) throws {
        let h = host(dst)
        let port = (try? server(dst).lmtpPort) ?? 7025
        let transport = replaceHostInTransport(origTransport, dst, port: port)
        try ma(h, account: account.name,
               attrs: ["zimbraMailHost": dst, "zimbraMailTransport": transport])
    }

    private func postFlip(account: AccountInfo, dst: String, skipMemcache: Bool) {
        let h = host(dst)
        flushAccountCache(host: h, account: account.name)
        if !skipMemcache {
            purgeProxyRoutes(host: h, account: account.name, aliases: account.aliases)
            let n = (try? deleteMemcachedKeys(host: h, accountId: account.id)) ?? 0
            say("memcached account keys deleted: \(n)")
        }
        try? ma(h, account: account.name, attrs: ["zimbraAccountStatus": account.status])
        flushAccountCache(host: h, account: account.name)
    }

    private func unlockAndUnregister(account: String, src: String, dst: String,
                                     skipLockout: Bool) {
        if !skipLockout {
            do { try soap(src).lockout(account: account, op: "end") }
            catch { say("lockout(end) on \(src) failed: \(error)", level: "warning") }
        }
        unregister(account: account, src: src, dst: dst)
    }

    private func ma(_ h: Host, account: String, attrs: [String: String]) throws {
        try h.run("zmprov -l ma \(shellQuote(account)) " +
                  attrs.map { "\($0.key) \(shellQuote($0.value))" }.joined(separator: " "))
    }

}

public struct NeError: Error, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { "NeError: \(message)" }
}

extension FileHandle: @retroactive TextOutputStream {
    public func write(_ string: String) {
        write(Data(string.utf8))
    }
}

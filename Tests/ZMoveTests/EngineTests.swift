/// Port of tests/test_engine.py: flip/abort/cleanup/relock/unlock flows,
/// ensure-group DDL, reservations, preflight — all against FakeHost.
import Foundation
import Testing
@testable import ZMove

private struct Boom: Error {}

@Suite("engine")
struct EngineTests {
    private func dstCmds(_ env: Env) -> String {
        env.hosts["dst"]!.cmds.joined(separator: "\n")
    }

    @Test func flipAndPostFlipComplete() throws {
        let env = try makeEnv()
        var job = env.job
        job.phase = .merged
        try env.eng.flip(job: &job)
        #expect(job.phase == .flipped)
        let cmds = dstCmds(env)
         #expect(cmds.contains("lmtp:dst:7026"))
         #expect(cmds.contains("zimbraMailHost dst"))
         #expect(env.hosts["dst"]!.cmds.contains(where: { $0.contains("'o'\"'\"'brien@x'") }))
         let dbm = FakeDbMove()
         try env.eng.postFlip(job: &job, dbm: dbm)
         #expect(job.phase == .done && job.status == "done" && dbm.dropped == 1)
         let after = dstCmds(env)
         #expect(after.contains(" -l ma ") && after.contains("zimbraAccountStatus") && after.contains("closed"))
    }

    @Test func abortRestoresSourceEvenWithoutContext() throws {
        let env = try makeEnv()
        var job = env.job
        job.phase = .verified
        job.data["lock_deadline"] = Date().timeIntervalSince1970 - 1
        job.data["locked_at"] = 1.0
        job.data["watermark"] = 5
        env.eng.ctxHook = { _, _ in throw Boom() }
        try env.eng.abort(job: &job, reason: "test")
        #expect(env.lockouts.items.contains(where: { $0 == ("src", "o'brien@x", "end") }))
         #expect(env.hosts["src"]!.cmds.contains(where: {
             $0.contains(" -l ma ") && $0.contains("zimbraAccountStatus") && $0.contains("closed")
         }))
        let j = try env.st.get(job.id)
        #expect(j?.status == "aborted" && j?.phase == .reserved)
        #expect(j?.data["lock_deadline"] == nil && j?.data["watermark"] == nil)
    }

    @Test func abortReportsUnrestoredSource() throws {
        let env = try makeEnv()
        var job = env.job
        job.phase = .locked
        env.eng.ctxHook = { _, _ in throw Boom() }
        for h in env.hosts.values { h.fail = ["zimbraAccountStatus"] }
        #expect(throws: EngineMoveError.self) { try env.eng.abort(job: &job) }
        let j = try env.st.get(job.id)
        #expect(j?.status == "failed" && (j?.data["locking"] as? Bool == true))
    }

    @Test func abortBeforeLockDoesNotTouchStatus() throws {
        let env = try makeEnv()
        var job = env.job
        job.phase = .prestaged
        env.eng.ctxHook = { _, _ in throw Boom() }
        try env.eng.abort(job: &job)
        #expect(env.lockouts.items.isEmpty)
         #expect(!env.hosts["src"]!.cmds.contains(where: { $0.contains(" -l ma ") }))
    }

    @Test func cleanupKeepsCopyClaimedByLaterJob() throws {
        let env = try makeEnv()
        var job = env.job
        job.status = "aborted"; job.phase = .reserved
        try env.st.save(&job)
        var later = try env.st.create(account: "o'brien@x", accountId: "id1",
                                      src: "src", dst: "dst", options: [:])
        later.status = "done"; later.phase = .done
        later.data = ["dst_mailbox_id": 42]
        try env.st.save(&later)
        let dbm = FakeDbMove()
        let reason = try env.eng.dstClaimedElsewhere(job: job, dbm: dbm)
        #expect((reason ?? "").contains("belongs to job"))
        let bs = BlobSync(env.eng.settings, src: env.hosts["src"]!, dst: env.hosts["dst"]!)
        try env.eng.cleanupDst(job: job, dbm: dbm, plans: [], bs: bs)
        #expect(dbm.deleted == 0 && dbm.dropped == 1)
    }

    @Test func cleanupRefusesWhenAccountHomedOnDst() throws {
        var env = try makeEnv()
        env.setGa(mailHost: "dst")
        let reason = try env.eng.dstClaimedElsewhere(job: env.job, dbm: FakeDbMove())
        #expect((reason ?? "").contains("homed on dst"))
    }

    @Test func checkRunnable() throws {
        let env = try makeEnv()
        var job = env.job
        job.data["rolled_back_at"] = 1.0
        #expect(throws: EngineMoveError.self) { try env.eng.checkRunnable(job: job) }
        job.data.removeValue(forKey: "rolled_back_at")
        job.owner = "elsewhere:1"
        job.heartbeat = Date().timeIntervalSince1970
        #expect(throws: (any Error).self) { try env.eng.checkRunnable(job: job) }
        job.options["force"] = true
        try env.eng.checkRunnable(job: job)
    }

    @Test func boundedTimeout() throws {
        let env = try makeEnv()
        let job = env.job
        #expect(env.eng.boundedTimeout(job: job, base: 50.0) == 50.0)
        var j2 = job
        j2.data["lock_deadline"] = Date().timeIntervalSince1970 + 10
        let capped = env.eng.boundedTimeout(job: j2, base: nil) ?? -1
        #expect(capped <= 10 && capped >= 0)
        #expect(env.eng.boundedTimeout(job: j2, base: 3.0) == 3.0)
    }

    private func dbm(dst: FakeMySQL) -> DbMove {
        let p = DbPlan(account: "a", accountId: "id", srcId: 1, srcGroup: 1,
                       dstId: 7, dstGroup: 7, dstIndexVolume: 3,
                       stage: "zmove_stage_x", volMap: [:])
        return DbMove(plan: p, src: FakeMySQL(), dst: dst)
    }

     @Test func ensureGroupFillsEmptySchema() throws {
         let dst = FakeMySQL(schemas: ["mboxgroup1": ["mail_item", "tombstone"],
                                       "mboxgroup7": []])
         try dbm(dst: dst).ensureDstGroupDb()
         let cmds = ((dst.host as? FakeHost)?.cmds.joined(separator: "\n") ?? "")
         #expect(cmds.contains("mysqldump") && cmds.contains("mboxgroup1"))
     }
 
     @Test func ensureGroupFillsHalfImportedSchemaWithoutDropping() throws {
         let dst = FakeMySQL(schemas: ["mboxgroup1": ["mail_item", "tombstone"],
                                       "mboxgroup7": ["mail_item"]])
         try dbm(dst: dst).ensureDstGroupDb()
         #expect(!dst.executed.contains(where: { $0.contains("DROP") || $0.contains("CREATE DATABASE") }))
     }

    @Test func ensureGroupReadyIsNoop() throws {
        let dst = FakeMySQL(schemas: ["mboxgroup1": ["mail_item", "tombstone"],
                                      "mboxgroup7": ["mail_item", "tombstone"]])
        try dbm(dst: dst).ensureDstGroupDb()
        #expect(((dst.host as? FakeHost)?.cmds ?? []).isEmpty && dst.executed.isEmpty)
    }

    @Test func resumeAfterUnjournaledFlipCommitsFlipped() throws {
        let env = try makeEnv()
        env.setGa(mailHost: "dst")
        var job = env.job
        job.phase = .merged
        try env.eng.relock(job: &job)
        #expect(job.phase == .flipped && env.lockouts.items.isEmpty)
        #expect(!dstCmds(env).contains("maintenance"))
    }

    @Test func relockResetsToLocked() throws {
        let env = try makeEnv()
        var job = env.job
        job.phase = .verified
        try env.eng.relock(job: &job)
        #expect(job.phase == .locked)
        #expect(env.lockouts.items.contains(where: { $0 == ("src", "o'brien@x", "start") }))
        #expect((job.data["lock_deadline"] as? Double ?? 0) > Date().timeIntervalSince1970)
        #expect(dstCmds(env).contains("zimbraAccountStatus") && dstCmds(env).contains("maintenance"))
    }

    @Test func restoreStatusRespectsAdminChange() throws {
        let env = try makeEnv()
        env.setGa(status: "locked")
        let h = env.hosts["dst"]!
         #expect(try env.eng.restoreStatus(h, job: env.job, status: "active") == false)
         #expect(!h.cmds.contains(where: { $0.contains(" -l ma ") }))
        env.setGa(status: "maintenance")
        #expect(try env.eng.restoreStatus(h, job: env.job, status: "active") == true)
    }

    @Test func unlockLeavesNonMaintenanceStatus() throws {
        let env = try makeEnv()
        var job = env.job
        job.status = "aborted"
        try env.st.save(&job)
        env.setGa(status: "closed")
        try env.eng.unlock(account: "o'brien@x", server: "dst")
         #expect(!dstCmds(env).contains(" -l ma "))
    }

    @Test func diskReservationsAreSharedBetweenJobs() throws {
         reserveSpace(jobId: "a", needs: ["dst\n/opt": 100])
         reserveSpace(jobId: "b", needs: ["dst\n/opt": 50])
         #expect(reservedByOthers(key: ("dst", "/opt"), jobId: "a") == 50)
        #expect(reservedByOthers(key: ("dst", "/opt"), jobId: "c") == 150)
        releaseSpace(jobId: "a")
        releaseSpace(jobId: "b")
        #expect(reservedByOthers(key: ("dst", "/opt"), jobId: "c") == 0)
    }

    @Test func lockCapturesCurrentStatus() throws {
        let env = try makeEnv()
        env.setGa(status: "locked")
        var job = env.job
        job.phase = .prestaged
        try env.eng.lock(job: &job)
        #expect((job.data["orig_status"] as? String) == "locked" && job.phase == .locked)
    }

    @Test func preflightReservationRoundtrip() throws {
        let env = try makeEnv()
        let rep: [String: Any] = ["errors": [] as [Any], "warnings": [] as [Any],
                                  "reserve": ["dst:/opt/zimbra": 123],
                                  "src_mailbox": ["id": 1, "group_id": 1, "index_volume_id": 2,
                                                  "items": 0, "size": 0],
                                  "account": ["status": "active", "mail_transport": "",
                                              "aliases": [] as [Any]],
                                  "volume_map": [1: 1], "copy": [:], "dst_mailbox": NSNull()]
        env.eng.planHook = { _ in rep }
        var job = env.job
        try env.eng.preflight(job: &job)
        #expect(reservedByOthers(key: ("dst", "/opt/zimbra"), jobId: "other") == 123)
        releaseSpace(jobId: job.id)
     }
 
     @Test func dirPlansRejectSameSharedDir() throws {
         let env = try makeEnv()
         env.eng.settings.sharedVolumes = [1: 1]
         let v = Volume(id: 1, type: 1, name: "v", path: "/nfs",
                        fileBits: 12, fileGroupBits: 8, mailboxBits: 12,
                        mailboxGroupBits: 8)
         var s = ServerInfo(name: "s", numGroups: 100)
         s.volumes = [v]
         var d = ServerInfo(name: "d", numGroups: 100)
         d.volumes = [v]
         #expect(throws: EngineMoveError.self) {
             try env.eng.dirPlans(srcI: s, dstI: d, srcId: 5, dstId: 5,
                                  vmap: [1: 1], copyIdx: false, srcIdxVol: 1)
         }
     }
 }

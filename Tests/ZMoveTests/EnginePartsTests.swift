/// Port of tests/test_engine_parts.py: rsync command building, NE server
/// fault paths, snapshot/window helpers. Host objects only, no SSH traffic.
import Foundation
import Testing
@testable import ZMove

@Suite("engine-parts")
struct EnginePartsTests {
    private func sync() -> BlobSync {
        let s = Settings()
        return BlobSync(s, src: FakeHost(name: "src", settings: s),
                        dst: FakeHost(name: "dst", settings: s))
    }

    private func plan(shared: Bool = false) -> DirPlan {
        DirPlan(kind: "msg", dstVolume: 10, dstDir: "/d/0/5",
                srcDirs: ["/s/0/5"], srcVolumes: [1], shared: shared)
    }

    @Test func parsesCommaNumbers() {
        let out = "Number of files: 1,300\n" +
            "Number of regular files transferred: 1,234\n" +
            "Total transferred file size: 56,789 bytes\n"
        #expect(parseStats(out) == (1234, 56789))
    }

    @Test func missingIsZero() {
        #expect(parseStats("") == (0, 0))
        #expect(parseStats("Number of regular files transferred: 7") == (7, 0))
    }

    @Test func finalAddsChecksumFullSpeed() {
        let bs = sync()
        let (_, online) = bs.cmd(plan: plan(), srcs: ["/s/0/5"], final: false)
        #expect(!online.contains("--checksum"))
        #expect(online.contains("ionice"))
        let (_, final) = bs.cmd(plan: plan(), srcs: ["/s/0/5"], final: true)
        #expect(final.contains("--checksum"))
        #expect(!final.contains("ionice"))
    }

    @Test func bwlimitOnlyOnline() {
        var s = Settings()
        s.rsyncBwlimitKbps = 1000
        let bs = BlobSync(s, src: FakeHost(name: "src", settings: s),
                          dst: FakeHost(name: "dst", settings: s))
        let (_, online) = bs.cmd(plan: plan(), srcs: ["/s/0/5"], final: false)
        #expect(online.contains("--bwlimit=1000"))
        let (_, final) = bs.cmd(plan: plan(), srcs: ["/s/0/5"], final: true)
        #expect(!final.contains("--bwlimit"))
    }

    @Test func sharedUsesLinkDestOnDst() {
        let bs = sync()
        let (host, cmd) = bs.cmd(plan: plan(shared: true), srcs: ["/s/0/5"], final: false)
        #expect(cmd.contains("--link-dest="))
        #expect(host.name == "dst")
    }

     @Test func neDefaultsMatch() {
         #expect(neDefaultMaxSyncs == 10)
         #expect(neDefaultSyncThresholdMs == 180000)
     }
     private func neMove(soap: FakeSoap) -> NeServerMove {
         let m = NeServerMove(settings: Settings())
         m.soapFactory = { _ in soap }
         return m
     }
 
     @Test func fossUnknownDocumentTolerated() throws {
         let soap = FakeSoap()
         soap.callEffect = SoapFault(code: "service.UNKNOWN_DOCUMENT", reason: "unknown document")
         let m = neMove(soap: soap)
         try m.register(account: "a@b", src: "src", dst: "dst")
     }

    @Test func neConflictStillAborts() {
        let soap = FakeSoap()
        soap.callEffect = SoapFault(code: "mail.ALREADY_BEING_MOVED_OUT", reason: "already moved")
        let m = neMove(soap: soap)
        #expect(throws: NeMoveError.self) {
            try m.register(account: "a@b", src: "src", dst: "dst")
        }
    }

    @Test func resolveModes() {
        let m = NeServerMove(settings: Settings())
        #expect(m.resolve("include", cfgSkip: true) == true)
        #expect(m.resolve("exclude", cfgSkip: false) == false)
        #expect(m.resolve("config", cfgSkip: true) == false)
        #expect(m.resolve("config", cfgSkip: false) == true)
        #expect(m.resolve(nil, cfgSkip: false) == true)
    }

    @Test func snapshotKeys() {
        let rep: [String: Any] = [
            "account": ["mail_host": "s1", "status": "active",
                        "mail_transport": "lmtp:s1:7025"],
            "src_mailbox": ["id": 7, "group_id": 2, "items": 10, "size": 100],
            "volume_map": [1: 10],
            "copy": ["blobs": true],
        ]
        let snap = preMoveSnapshot(rep: rep)
        #expect((snap["mail_host"] as? String) == "s1")
        #expect(((snap["mailbox"] as? [String: Any])?["id"] as? Int) == 7)
        #expect((snap["volume_map"] as? [Int: Int]) == [1: 10])
        #expect(snap["taken_at"] != nil)
    }

    @Test func inWindowNoon() throws {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 12; comps.minute = 0
        let noon = Calendar.current.date(from: comps)!
        #expect(try inWindow("11:00-13:00", now: noon))
        #expect(!(try inWindow("13:00-14:00", now: noon)))
    }

    @Test func neLockDelegatesToSoap() throws {
        let dst = FakeHost(name: "dst",
                           answers: ["zmprov -l ga": gaText(name: "a@b", mailHost: "src",
                                                           status: "active")])
        let soap = FakeSoap(host: dst)
        let m = NeServerMove(settings: Settings())
        m.hosts = ["dst": dst]
        m.soapFactory = { _ in soap }
        try m.lock(account: "a@b", src: "src", dst: "dst", skipLockout: false)
        #expect(soap.calls.contains("LockoutMailboxRequest"))
    }

    @Test func neSkipLockout() throws {
        let dst = FakeHost(name: "dst",
                           answers: ["zmprov -l ga": gaText(name: "a@b", mailHost: "src",
                                                           status: "active")])
        let soap = FakeSoap(host: dst)
        let m = NeServerMove(settings: Settings())
        m.hosts = ["dst": dst]
        m.soapFactory = { _ in soap }
        try m.lock(account: "a@b", src: "src", dst: "dst", skipLockout: true)
        #expect(!soap.calls.contains("LockoutMailboxRequest"))
    }
}

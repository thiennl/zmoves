/// Port of tests/test_caches.py: MTA queue parsing/flushing, proxy purge,
/// memcached deletes, and canonical account lookup — all on FakeHost.
import Testing
@testable import ZMove

private let queueJSON = [
    #"{"queue_name": "deferred", "queue_id": "A1", "recipients": [{"address": "User@X"}]}"#,
    #"{"queue_name": "deferred", "queue_id": "B2", "recipients": [{"address": "other@x"}]}"#,
    #"{"queue_name": "active", "queue_id": "C3", "recipients": [{"address": "user@x"}]}"#,
    #"{"queue_name": "deferred", "queue_id": "D4", "recipients": [{"address": "alias@x"}, {"address": "other@x"}]}"#,
].joined(separator: "\n")

@Suite("caches")
struct CachesTests {
    @Test func queueIdsOnlyForThisAccount() {
        #expect(queueIds(for: queueJSON, recipients: ["user@x", "alias@x"]) == ["A1", "D4"])
        #expect(queueIds(for: "garbage\n", recipients: ["user@x"]) == [])
    }

    @Test func flushNeverFlushesWholeQueue() {
        let h = FakeHost(name: "mta", answers: ["postqueue -j": queueJSON])
        #expect(flushMtaQueues(hosts: [h], account: "user@x", aliases: ["alias@x"]) == 2)
        #expect(!h.cmds.contains(where: { $0.hasSuffix(" -f") || $0.contains(" -f;") }))
        #expect(h.cmds.contains(where: { $0.contains("-i A1") && $0.contains("-i D4") && !$0.contains("B2") }))
    }

    @Test func flushSkipsWhenQueueListingUnsupported() {
        let h = FakeHost(name: "mta", fail: ["postqueue -j"])
        #expect(flushMtaQueues(hosts: [h], account: "user@x") == 0)
        #expect(h.cmds.count == 1)
    }

    @Test func proxyPurgeCoversAliasesAndMemcachedHasTimeout() throws {
        let h = FakeHost(name: "d",
                         answers: ["gcf": "zimbraMemcachedClientServerList: m1:11211"])
        purgeProxyRoutes(host: h, account: "user@x", aliases: ["alias@x", "user@x"])
        #expect(h.cmds.filter { $0.contains("zmproxypurge") }.count == 2)
        #expect(try deleteMemcachedKeys(host: h, accountId: "id1") >= 0)
        #expect(h.cmds.filter { $0.contains("/dev/tcp") }.allSatisfy { $0.hasPrefix("timeout ") })
    }

    @Test func accountInfoCanonicalNameAndAliases() throws {
        let out = "# name user@x\nzimbraId: id1\nzimbraMailHost: s\nzimbraAccountStatus: active\n" +
            "mail: user@x\nmail: alias@x\nzimbraMailAlias: alias@x\nzimbraMailDeliveryAddress: user@x\n"
        let h = FakeHost(name: "d", answers: ["zmprov -l ga": out])
        let a = try accountInfo(host: h, account: "alias@x")
        #expect(a.name == "user@x" && a.aliases == ["alias@x"])
    }
}

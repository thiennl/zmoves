/// Ports of tests/test_state.py (owner liveness, one-active-per-account
/// with abort) plus a heartbeat beat() check.
import Foundation
import Testing
@testable import ZMove

private func stateTmp() throws -> State {
    let p = FileManager.default.temporaryDirectory
        .appendingPathComponent("zmove-test-\(UUID().uuidString).db").path
    return try State(path: p)
}

@Suite("state-extra")
struct StateExtraTests {
    @Test func oneActiveJobPerAccount() throws {
        let st = try stateTmp()
        var j = try st.create(account: "a@x", accountId: "id1", src: "s", dst: "d", options: [:])
        #expect(throws: AlreadyMoving.self) {
            try st.create(account: "a@x", accountId: "id1", src: "s", dst: "d2", options: [:])
        }
        j.status = "aborted"
        try st.save(&j)
        _ = try st.create(account: "a@x", accountId: "id1", src: "s", dst: "d2", options: [:])
    }

    @Test func ownerAlive() throws {
        let st = try stateTmp()
        var j = try st.create(account: "a@x", accountId: "id1", src: "s", dst: "d", options: [:])
        #expect(!st.ownerAlive(j)) // it is us
        j.owner = "\(ProcessInfo.processInfo.hostName):\(Int32((1 << 22) + 12345))"
        #expect(!st.ownerAlive(j)) // same host, dead pid
        j.owner = "\(ProcessInfo.processInfo.hostName):1"
        #expect(st.ownerAlive(j)) // pid 1 always exists
        j.owner = "otherhost:1"
        j.heartbeat = Date().timeIntervalSince1970
        #expect(st.ownerAlive(j))
        j.heartbeat = Date().timeIntervalSince1970 - 3600
        #expect(!st.ownerAlive(j))
    }

    @Test func beatRefreshesHeartbeat() throws {
        let st = try stateTmp()
        let j = try st.create(account: "a@x", accountId: "id1", src: "s", dst: "d", options: [:])
        try st.beat(j.id)
        let got = try st.get(j.id)
        #expect((got?.heartbeat ?? 0) >= j.heartbeat)
    }
}

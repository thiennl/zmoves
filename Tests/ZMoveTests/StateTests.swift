import Testing
import Foundation
@testable import ZMove

private func tempDB() throws -> String {
    let p = FileManager.default.temporaryDirectory
        .appendingPathComponent("zmove-test-\(UUID().uuidString).db").path
    return p
}

@Suite("state")
struct StateTests {
    @Test func createGetFindEvents() throws {
        let st = try State(path: try tempDB())
        let job = try st.create(account: "a@example.com", accountId: "id-1",
                                src: "m1", dst: "m2", options: ["verify": "full"])
        #expect(job.phase == .planned)
        let got = try st.get(job.id)
        #expect(got?.account == "a@example.com")
        #expect(try st.find(account: "a@example.com").count == 1)
        #expect(try st.find(account: "id-1").count == 1)
        #expect(try st.find(account: "nobody").isEmpty)
        try st.event(jobId: job.id, level: "info", msg: "hello")
        let evs = try st.events(jobId: job.id)
        #expect(evs.count == 1)
        #expect((evs[0][3] as? String) == "hello")
        // Failed-job events prune only when old; a future cutoff prunes done jobs.
        var done = job
        done.status = "done"
        done.phase = .done
        try st.save(&done)
        #expect(try st.pruneEvents(maxAgeDays: -1) == 1)
        #expect(try st.events(jobId: job.id).isEmpty)
    }

    @Test func doubleCreateIsAlreadyMoving() throws {
        let st = try State(path: try tempDB())
        _ = try st.create(account: "a@example.com", accountId: "id-1",
                          src: "m1", dst: "m2", options: [:])
        #expect(throws: AlreadyMoving.self) {
            try st.create(account: "a@example.com", accountId: "id-1",
                          src: "m1", dst: "m2", options: [:])
        }
    }
}

@Suite("config")
struct ConfigTests {
    @Test func loadKeyValues() throws {
        let p = FileManager.default.temporaryDirectory
            .appendingPathComponent("zmove-test-\(UUID().uuidString).conf").path
        try "[zmove]\nadmin_port = 7072\nrun_as_zimbra = TRUE\n".write(toFile: p, atomically: true, encoding: .utf8)
        let s = try loadConfig(path: p)
        #expect(s.adminPort == 7072)
        #expect(s.runAsZimbra == true)
    }
}

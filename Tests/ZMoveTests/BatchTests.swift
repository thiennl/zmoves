/// Port of tests/test_batch.py: canary flows with stubbed workers.
import Testing
@testable import ZMove

@Suite("batch")
struct BatchTests {
    private func batch() -> Batch {
         return Batch(settings: Settings(), parallel: 1, dryRun: true)
    }

    private func items(_ n: Int) -> [BatchItem] {
        (0..<n).map { BatchItem(account: "u\($0)@x", src: "s", dst: "d") }
    }

    @Test func noCanaryRunsAll() {
        let b = batch()
        b.oneHook = { it, _ in (it, "j", nil) }
        #expect(b.run(items(3), options: [:], canary: 0).count == 3)
    }

    @Test func canaryFailureStopsRest() {
        let b = batch()
        var calls: [String] = []
        b.oneHook = { it, _ in
            calls.append(it.account)
            if it.account == "u0@x" { return (it, nil, "MoveError: boom") }
            return (it, "j", nil)
        }
        let res = b.run(items(3), options: [:], canary: 1)
        #expect(res.map { $0.0.account } == ["u0@x"])
        #expect(calls == ["u0@x"])
    }

    @Test func canaryPauseNonTTY() {
        let b = batch()
        b.oneHook = { it, _ in (it, "j", nil) }
        b.askContinue = { _ in false }
        #expect(b.run(items(3), options: [:], canary: 1).count == 1)
    }

    @Test func canaryApprovedContinues() {
        let b = batch()
        b.oneHook = { it, _ in (it, "j", nil) }
        b.askContinue = { _ in true }
        #expect(b.run(items(3), options: [:], canary: 2).count == 3)
    }

    @Test func canaryGeLenRunsAll() {
        let b = batch()
        b.oneHook = { it, _ in (it, "j", nil) }
        var asked = false
        b.askContinue = { _ in asked = true; return true }
        #expect(b.run(items(2), options: [:], canary: 5).count == 2)
        #expect(!asked)
    }
}

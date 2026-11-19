/// Port of tests/test_safety.py: purge requires retyping the account email.
import Testing
@testable import ZMove

private func purgeJob() -> Job {
    Job(id: "j", account: "u@x", accountId: "id", src: "s1", dst: "d",
        data: ["src_mailbox_id": 7])
}

@Suite("safety")
struct SafetyTests {
    @Test func nonTTYDeclines() {
        #expect(confirmPurge(job: purgeJob(), isTTY: false, readInput: {
            fatalError("must not prompt without a TTY")
        }) == false)
    }

    @Test func exactEmailApproves() {
        #expect(confirmPurge(job: purgeJob(), isTTY: true, readInput: { "u@x" }) == true)
    }

    @Test func wrongTextDeclines() {
        #expect(confirmPurge(job: purgeJob(), isTTY: true, readInput: { "y" }) == false)
    }

    @Test func eofDeclines() {
        #expect(confirmPurge(job: purgeJob(), isTTY: true, readInput: { nil }) == false)
    }
}

import Testing
@testable import ZMove

@Suite("cli-parse")
struct CLIParseTests {
    private func moveParser() -> ArgParser {
        var p = ArgParser(prog: "zmove move")
        p.addPositional("account")
        p.addOption("from", short: "f")
        p.addOption("to", short: "t")
        addMoveArgs(to: &p)
        return p
    }

    @Test func flagsValuesShortsAndTerminator() throws {
        let p = moveParser()
        let a = try p.parse(["a@x", "-f", "m1", "--to=m2", "--max-syncs", "3",
                             "--skip-lockout", "-y", "--", "--not-an-opt"])
        #expect(a.positionals == ["a@x", "--not-an-opt"])
        #expect(a.opt("from") == "m1")
        #expect(a.opt("to") == "m2")
        #expect(a.opt("max-syncs") == "3")
        #expect(a.flag("skip-lockout"))
        #expect(a.flag("yes"))
        #expect(throws: (any Error).self) { try p.parse(["--bogus"]) }
        #expect(throws: (any Error).self) { try p.parse(["-Z"]) }
    }

    @Test func moveOptsValidation() throws {
        let p = moveParser()
        #expect(throws: (any Error).self) {
            try moveOpts(p.parse(["a", "--ng-migration"]))
        }
        #expect(throws: (any Error).self) {
            try moveOpts(p.parse(["a", "--confirm-steps", "--yes"]))
        }
        #expect(throws: (any Error).self) {
            try moveOpts(p.parse(["a", "--blobs", "sometimes"]))
        }
        #expect(throws: (any Error).self) {
            try moveOpts(p.parse(["a", "--max-syncs", "many"]))
        }
        let ok = try moveOpts(p.parse(["a", "--blobs", "config",
                                       "--exclude-tables", "event,foo",
                                       "--skip-lockout", "--no-flush-mta"]))
        #expect((ok["blobs"] as? String) == "config")
        #expect((ok["exclude_tables"] as? [String]) == ["event", "foo"])
        #expect((ok["skip_lockout"] as? Bool) == true)
        #expect((ok["flush_mta"] as? Bool) == false)
        #expect(ok["confirm_steps"] == nil)
    }

    @Test func neOptsKeys() throws {
        var p = ArgParser(prog: "zmove ne-move")
        addNeMoveArgs(to: &p)
        let o = try neOpts(p.parse(["a@x", "-f", "m1", "-t", "m2", "--verify", "count"]))
        #expect((o["verify"] as? String) == "count")
        #expect(o["keep_stage"] == nil)
    }

    @Test func phaseNames() {
        #expect(phaseName(.planned) == "PLANNED")
        #expect(phaseName(.flipped) == "FLIPPED")
        #expect(phaseName(.done) == "DONE")
    }
}

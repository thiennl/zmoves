/// Port of tests/test_compat.py: parser contract, authtoken reading, and
/// run_mboxmove flows with faked transport. No SSH, no servers.
import Foundation
import Testing
@testable import ZMove

private let gsOut = "# name dst\nzimbraId: id-1\nzimbraServiceEnabled: mailbox\n"

private func runFlow(moveEffect: Error? = nil) -> (Int32, FakeSoap, FakeHost) {
    let host = FakeHost(name: "dst", answers: ["zmprov -l gs": gsOut])
    let soap = FakeSoap(host: host)
    soap.moveEffect = moveEffect
    let rc = runMboxMove(settings: Settings(), account: "a@b", src: "s", dst: "d",
                         hostFactory: { _ in host }, soapFactory: { _ in soap })
    return (rc, soap, host)
}

@Suite("compat")
struct CompatTests {
    private func parser(prog: String = "zmmboxmove") -> ArgParser {
        var p = ArgParser(prog: prog)
        addMboxmoveArgs(to: &p)
        return p
    }

     @Test func progAndRequiredFlags() throws {
         let p = parser()
        #expect(p.prog == "zmmboxmove")
        let a = try p.parse(["-a", "u@x", "-f", "s", "-t", "d"])
        #expect(a.opt("account") == "u@x" && a.opt("from") == "s" && a.opt("to") == "d")
        #expect(!a.flag("sync"))
        let b = try p.parse(["--account", "u@x", "--from", "s", "--to", "d",
                             "--sync", "--force", "--ng-migration"])
         #expect(b.flag("sync") && b.flag("force") && b.flag("ng-migration"))
    }

    @Test func missingArgsSurfaceAsNil() throws {
        let a = try parser().parse([])
        #expect(a.opt("account") == nil && a.opt("from") == nil && a.opt("to") == nil)
    }

    @Test func authtokenRawPassthrough() throws {
        #expect(try readAuthtoken(value: "tok123", path: nil) == "tok123")
        #expect(try readAuthtoken(value: nil, path: nil) == nil)
    }

    @Test func authtokenJsonPeel() throws {
        #expect(try readAuthtoken(value: #"{"authtoken": "X"}"#, path: nil) == "X")
        #expect(try readAuthtoken(value: #"{"id": "Y"}"#, path: nil) == "Y")
    }

    @Test func authtokenFile() throws {
        let p = FileManager.default.temporaryDirectory
            .appendingPathComponent("tok-\(UUID().uuidString).json").path
        try #"{"token": "Z"}"#.write(toFile: p, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: p) }
        #expect(try readAuthtoken(value: nil, path: p) == "Z")
    }

    @Test func unknownDocumentHintsFoss() {
        let (rc, _, _) = runFlow(moveEffect: SoapFault(code: "service.UNKNOWN_DOCUMENT",
                                                       reason: "unknown document"))
        #expect(rc == 1)
        let msg = compatFaultMessage(SoapFault(code: "service.UNKNOWN_DOCUMENT", reason: "x"))
        #expect(msg.contains("FOSS server?"))
    }

    @Test func otherFaultHasNoHint() {
        let (rc, _, _) = runFlow(moveEffect: SoapFault(code: "service.INVALID_REQUEST",
                                                       reason: "already on this server"))
        #expect(rc == 1)
        let msg = compatFaultMessage(SoapFault(code: "service.INVALID_REQUEST", reason: "x"))
        #expect(!msg.contains("FOSS server?"))
    }

    @Test func successAsyncMessage() {
        let (rc, soap, _) = runFlow()
        #expect(rc == 0)
        #expect(soap.tokenText == "T")
    }
}

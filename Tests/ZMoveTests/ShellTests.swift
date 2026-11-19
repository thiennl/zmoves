/// Port of tests/test_shell.py: real local shell snippets (no SSH).
/// LocalHost/PipeHost subclass the real Host with local execution.
import Foundation
import Testing
@testable import ZMove

final class LocalHost: ZMove.Host {
    override func sshArgv() -> [String] { [] }
    override func wrap(_ cmd: String) -> String { cmd }
    override func run(_ cmd: String, input: String? = nil, check: Bool = true,
                      timeout: Double? = nil, mutating: Bool = true) throws -> CommandResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "set -o pipefail; " + cmd]
        let outP = Pipe(), errP = Pipe()
        p.standardOutput = outP
        p.standardError = errP
        var inP: Pipe? = nil
        if input != nil { inP = Pipe(); p.standardInput = inP }
        try p.run()
        if let data = input?.data(using: .utf8) {
            inP!.fileHandleForWriting.write(data)
            inP!.fileHandleForWriting.closeFile()
        }
        if let t = timeout {
            let deadline = Date().addingTimeInterval(t)
            while p.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if p.isRunning {
                p.terminate(); p.waitUntilExit()
                throw TimeoutError(host: name, cmd: cmd, seconds: t)
            }
        }
        p.waitUntilExit()
        let rc = p.terminationStatus
        let out = String(data: outP.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        let err = String(data: errP.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        if check && rc != 0 { throw RemoteError(host: name, cmd: cmd, rc: rc, stderr: err) }
        return CommandResult(rc: rc, out: out, err: err, seconds: 0)
    }
}

final class PipeHost: ZMove.Host {
    override func sshArgv() -> [String] { ["bash", "-c"] }
    override func wrap(_ cmd: String) -> String { "set -o pipefail; " + cmd }
}

private func sudoOK(_ user: String) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
    p.arguments = ["-n", "-u", user, "true"]
    return (try? p.run()) != nil && { p.waitUntilExit(); return p.terminationStatus == 0 }()
}

@Suite("shell")
struct ShellTests {
    @Test func inventoryDedupesMergedSources() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zmove-test-\(UUID().uuidString)").path
        let a = (dir as NSString).appendingPathComponent("a/msg/0")
        let b = (dir as NSString).appendingPathComponent("b/msg/0")
        try FileManager.default.createDirectory(atPath: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: b, withIntermediateDirectories: true)
        try "abc".write(toFile: (a as NSString).appendingPathComponent("1-1.msg"),
                        atomically: true, encoding: .utf8)
        try "abc".write(toFile: (b as NSString).appendingPathComponent("1-1.msg"),
                        atomically: true, encoding: .utf8)
        try "hello".write(toFile: (b as NSString).appendingPathComponent("2-1.msg"),
                          atomically: true, encoding: .utf8)
        let h = LocalHost(name: "local", settings: Settings())
        let bs = BlobSync(Settings(), src: h, dst: h)
        let (n, s) = try bs.inventory(host: h, dirs: [
            (dir as NSString).appendingPathComponent("a"),
            (dir as NSString).appendingPathComponent("b")])
        #expect(n == 2 && s == 8)
        #expect(try bs.inventory(host: h, dirs: []) == (0, 0))
    }

    @Test func removeDirsGuard() {
        let h = LocalHost(name: "local", settings: Settings())
        #expect(throws: BlobError.self) {
            try BlobSync(Settings(), src: h, dst: h).removeDirs(h, ["/opt/zimbra/store"])
        }
    }

    @Test func pipeOkAndFailingProducer() throws {
        let s = Settings()
        let src = PipeHost(name: "s", settings: s)
        let dst = PipeHost(name: "d", settings: s)
        let o = FileManager.default.temporaryDirectory
            .appendingPathComponent("o-\(UUID().uuidString)").path
        try pipe(from: src, "echo hi", to: dst, "cat > \(o)")
        #expect(try String(contentsOfFile: o, encoding: .utf8) == "hi\n")
        #expect(throws: RemoteError.self) {
            try pipe(from: src, "echo x; exit 3", to: dst, "cat >/dev/null")
        }
    }

    @Test func pipeChattyStderrDoesNotDeadlock() throws {
        let s = Settings()
        let src = PipeHost(name: "s", settings: s)
        let dst = PipeHost(name: "d", settings: s)
        try pipe(from: src, #"head -c 1000000 /dev/zero | tr '\0' x >&2; echo ok"#,
                 to: dst, "cat >/dev/null", timeout: 30)
    }

     @Test func pipeTimeoutReaps() {
         let s = Settings()
         let src = PipeHost(name: "s", settings: s)
         let dst = PipeHost(name: "d", settings: s)
         #expect(throws: TimeoutError.self) {
             try pipe(from: src, "sleep 30", to: dst, "cat >/dev/null", timeout: 0.5)
         }
     }
 
     @Test func sudoWrapKeepsDollarQuotesStdinAndErrors() throws {
         let user = NSUserName()
         guard sudoOK(user) else { return }
         var s = Settings()
         s.sshUser = "someone-else"
         s.runAsZimbra = true
         s.zimbraUser = user
         let h = ZMove.Host(name: "x", settings: s)
         let cmd = #"export MYSQL_PWD="$(printf %s "s3cr'et")"; SOCK="$(echo /tmp/my.sock)"; "# +
             #"echo "sock=$SOCK pwd=$MYSQL_PWD"; tr a-z A-Z | awk '{print "in:" $1}'; "# +
             #"printf '%s\n' 'o'"'"'brien@x'"#
         let w = h.wrap(cmd)
         #expect(w.contains("sudo -n -u") && w.contains("-H bash -lc"))
         #expect(!w.components(separatedBy: "bash")[0].contains(" -i"))
         let p = Process()
         p.executableURL = URL(fileURLWithPath: "/bin/bash")
         p.arguments = ["-c", w]
         let outP = Pipe(), errP = Pipe()
         p.standardOutput = outP
         p.standardError = errP
         let inPipe = Pipe()
         p.standardInput = inPipe
         try p.run()
         inPipe.fileHandleForWriting.write("hello stdin\n".data(using: .utf8)!)
         inPipe.fileHandleForWriting.closeFile()
         p.waitUntilExit()
        let out = String(data: outP.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        #expect(p.terminationStatus == 0)
        #expect(out.components(separatedBy: "\n").prefix(3).joined(separator: "\n") ==
            "sock=/tmp/my.sock pwd=s3cr'et\nin:HELLO\no'brien@x")
    }

    @Test func wrapDirectZimbraUserHasNoSudo() {
        var s = Settings()
        s.sshUser = "zimbra"
        s.runAsZimbra = true
        #expect(ZMove.Host(name: "x", settings: s).wrap("true").hasPrefix("bash -lc "))
    }
}

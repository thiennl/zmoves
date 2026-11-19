/// SSH execution layer (OpenSSH client, multiplexed via ControlMaster).
/// Port of remote.py. All commands run on the named mailstore as zimbra.
import Foundation

public struct RemoteError: Error, CustomStringConvertible {
    public let host: String
    public let cmd: String
    public let rc: Int32
    public let stderr: String

    public init(host: String, cmd: String, rc: Int32, stderr: String) {
        self.host = host; self.cmd = cmd; self.rc = rc; self.stderr = stderr
    }

    public var description: String {
        "[\(host)] rc=\(rc): \(stderr.suffix(2000))\n  cmd: \(cmd.prefix(500))"
    }
}

public struct CommandResult: Sendable {
    public var rc: Int32
    public var out: String
    public var err: String
    public var seconds: Double
}

public struct TimeoutError: Error {
    public var host: String
    public var cmd: String
    public var seconds: Double
}

private let ctrlDir: String = {
    let dir = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("zmove-ssh-\(NSUserName())")
    try? FileManager.default.createDirectory(atPath: dir,
        withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return dir
}()

/// Run a local command, capturing stdout/stderr. Used for ssh itself.
@discardableResult
func runLocal(_ argv: [String], input: String? = nil,
              timeout: Double? = nil) throws -> (out: String, err: String, rc: Int32, seconds: Double) {
    let t0 = Date()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = argv
    let outPipe = Pipe(), errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    var stdinPipe: Pipe? = nil
    if input != nil { stdinPipe = Pipe(); p.standardInput = stdinPipe }
    try p.run()
    if let data = input?.data(using: .utf8) {
        stdinPipe?.fileHandleForWriting.write(data)
        stdinPipe?.fileHandleForWriting.closeFile()
    }
    var timedOut = false
    if let timeout = timeout {
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate(); timedOut = true }
    } else {
        p.waitUntilExit()
    }
    let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if timedOut {
        throw TimeoutError(host: "localhost", cmd: argv.joined(separator: " "), seconds: timeout ?? 0)
    }
    return (out, err, p.terminationStatus, Date().timeIntervalSince(t0))
}

 open class Host: @unchecked Sendable {
    public let name: String
    public let settings: Settings
    public let dryRun: Bool

    public init(name: String, settings: Settings, dryRun: Bool = false) {
        self.name = name
        self.settings = settings
        self.dryRun = dryRun
    }

     open func sshArgv() -> [String] {
         var argv = ["ssh", "-p", String(settings.sshPort),
                     "-o", "BatchMode=yes",
                     "-o", "ServerAliveInterval=30",
                     "-o", "ControlMaster=auto",
                     "-o", "ControlPath=\(ctrlDir)/%r@%h:%p",
                     "-o", "ControlPersist=600"]
         if let key = settings.sshKey { argv += ["-i", key] }
         argv += settings.sshOptions
         argv.append("\(settings.sshUser)@\(name)")
         return argv
     }
 
     /// Run as the zimbra user with a login shell (PATH includes /opt/zimbra/bin).
     /// NOT `sudo -i`: it re-joins argv for the target login shell without
     /// escaping `$`, so `$(...)` and awk `$1` would expand too early.
     open func wrap(_ cmd: String) -> String {
         let inner = "set -o pipefail; \(cmd)"
         if settings.runAsZimbra && settings.sshUser != settings.zimbraUser {
             return "sudo -n -u \(shellQuote(settings.zimbraUser)) -H bash -lc " +
                 shellQuote("cd ~ 2>/dev/null; \(inner)")
         }
         return "bash -lc \(shellQuote(inner))"
     }

     @discardableResult
     open func run(_ cmd: String, input: String? = nil, check: Bool = true,
                    timeout: Double? = nil, mutating: Bool = true) throws -> CommandResult {
        let full = wrap(cmd)
        if dryRun && mutating {
            print("[dry-run][\(name)] \(cmd.prefix(300))")
            return CommandResult(rc: 0, out: "", err: "", seconds: 0)
        }
        let (out, err, rc, seconds) = try runLocal(sshArgv() + [full],
                                                   input: input, timeout: timeout)
        if check && rc != 0 {
            throw RemoteError(host: name, cmd: cmd, rc: rc, stderr: err)
        }
        return CommandResult(rc: rc, out: out, err: err, seconds: seconds)
    }

     open func out(_ cmd: String, timeout: Double? = nil) throws -> String {
        try run(cmd, timeout: timeout, mutating: false).out
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Stream stdout of srcCmd (on src) into stdin of dstCmd (on dst) through the
/// control node. Both exit codes are checked. With compress (default) the
/// source gzips and the destination gunzips, so multi-GB dumps do not
/// saturate the control node's links uncompressed.
@discardableResult
public func pipe(from src: Host, _ srcCmd: String, to dst: Host, _ dstCmd: String,
                 timeout: Double? = nil, dryRun: Bool = false,
                 compress: Bool = true) throws -> Double {
    if dryRun {
        print("[dry-run] \(src.name):\(srcCmd.prefix(200)) | \(dst.name):\(dstCmd.prefix(200))")
        return 0
    }
    let t0 = Date()
    let sc = compress ? "\(srcCmd) | gzip -1" : srcCmd
    let dc = compress ? "gzip -dc | \(dstCmd)" : dstCmd
    let p1 = Process(), p2 = Process()
    p1.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p1.arguments = src.sshArgv() + [src.wrap(sc)]
     let mid = Pipe()
     p1.standardOutput = mid
     p2.executableURL = URL(fileURLWithPath: "/usr/bin/env")
     p2.arguments = dst.sshArgv() + [dst.wrap(dc)]
     p2.standardInput = mid
     // Drain both stderr pipes concurrently: a chatty producer (1 MB on
     // stderr) would block forever if we only read after waitUntilExit.
     let err1 = Pipe(); p1.standardError = err1
     var e1data = Data()
     err1.fileHandleForReading.readabilityHandler = { e1data.append($0.availableData) }
     let err2 = Pipe(); p2.standardError = err2
     var e2data = Data()
     err2.fileHandleForReading.readabilityHandler = { e2data.append($0.availableData) }
     try p1.run()
     try p2.run()
     // Deadline watchdog; outputs are small (mysqldump streams data via stdout).
     let deadline = timeout.map { Date().addingTimeInterval($0) }
     var timedOut = false
     while p1.isRunning || p2.isRunning {
         if let dl = deadline, Date() > dl {
             p1.terminate(); p2.terminate(); timedOut = true; break
         }
         Thread.sleep(forTimeInterval: 0.05)
     }
     p1.waitUntilExit(); p2.waitUntilExit()
     err1.fileHandleForReading.readabilityHandler = nil
     err2.fileHandleForReading.readabilityHandler = nil
     e1data.append(err1.fileHandleForReading.readDataToEndOfFile())
     e2data.append(err2.fileHandleForReading.readDataToEndOfFile())
     let e1 = String(data: e1data, encoding: .utf8) ?? ""
     let e2 = String(data: e2data, encoding: .utf8) ?? ""
     if timedOut {
         throw TimeoutError(host: "\(src.name)->\(dst.name)", cmd: "\(srcCmd) | \(dstCmd)",
                            seconds: timeout ?? 0)
     }
    if p1.terminationStatus != 0 {
        throw RemoteError(host: src.name, cmd: srcCmd,
                          rc: p1.terminationStatus, stderr: e1)
    }
    if p2.terminationStatus != 0 {
        throw RemoteError(host: dst.name, cmd: dstCmd,
                          rc: p2.terminationStatus, stderr: e2)
    }
    return Date().timeIntervalSince(t0)
}

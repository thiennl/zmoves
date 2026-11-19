/// Port of cli.py + compat entry: argument parsing and subcommand dispatch.
/// Faithful port: same subcommands, flags, JSON shapes, exit codes (0 ok,
/// 1 operational failure, 2 usage/config errors, 130 on Ctrl-C where applicable).
import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public let zmoveVersion = "1.0.0"

public struct CLIError: Error, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

// ------------------------------------------------------------------ arg parsing

/// Parsed invocation: flags present, valued options, positional arguments.
public struct ParsedArgs {
    public var positionals: [String] = []
    public var flags: Set<String> = []
    public var values: [String: String] = [:]

    public func flag(_ name: String) -> Bool { flags.contains(name) }
    public func opt(_ name: String) -> String? { values[name] }
    public func intOpt(_ name: String) throws -> Int? {
        guard let v = values[name] else { return nil }
        guard let n = Int(v) else { throw CLIError("option --\(name) needs an integer, got '\(v)'") }
        return n
    }
    public func floatOpt(_ name: String) throws -> Double? {
        guard let v = values[name] else { return nil }
        guard let n = Double(v) else { throw CLIError("option --\(name) needs a number, got '\(v)'") }
        return n
    }
}

public struct OptDef {
    public var long: String
    public var short: Character?
    public var takesValue: Bool
    public var metavar: String?
    public var help: String
}

/// Minimal argparse-shaped parser: --opt value | --opt=value | --flag,
/// -s value, combined short flags, -- terminator. Unknown options are errors.
public struct ArgParser {
    public var prog: String
    public var description: String
    public var positionalsHelp: [(String, String)] = []
    public var defs: [OptDef] = []

    public init(prog: String, description: String = "") {
        self.prog = prog; self.description = description
    }

    public mutating func addFlag(_ long: String, short: Character? = nil, help: String = "") {
        defs.append(OptDef(long: long, short: short, takesValue: false, metavar: nil, help: help))
    }

    public mutating func addOption(_ long: String, short: Character? = nil,
                                   metavar: String? = nil, help: String = "") {
        defs.append(OptDef(long: long, short: short, takesValue: true, metavar: metavar, help: help))
    }

    public mutating func addPositional(_ name: String, help: String = "") {
        positionalsHelp.append((name, help))
    }

    public func parse(_ argv: [String]) throws -> ParsedArgs {
        var out = ParsedArgs()
        var i = 0
        var positionalOnly = false
        while i < argv.count {
            let tok = argv[i]
            if positionalOnly {
                out.positionals.append(tok); i += 1; continue
            }
            if tok == "--" { positionalOnly = true; i += 1; continue }
            if tok.hasPrefix("--") && tok.count > 2 {
                let body = String(tok.dropFirst(2))
                let parts = body.split(separator: "=", maxSplits: 1).map(String.init)
                guard let def = defs.first(where: { $0.long == parts[0] }) else {
                    throw CLIError("unknown option --\(parts[0])")
                }
                if def.takesValue {
                    if parts.count == 2 { out.values[def.long] = parts[1] }
                    else {
                        guard i + 1 < argv.count else {
                            throw CLIError("option --\(def.long) needs a value")
                        }
                        out.values[def.long] = argv[i + 1]; i += 1
                    }
                } else {
                    if parts.count == 2 { throw CLIError("option --\(def.long) takes no value") }
                    out.flags.insert(def.long)
                }
                i += 1; continue
            }
            if tok.hasPrefix("-") && tok.count > 1 && tok != "-" {
                var j = tok.index(after: tok.startIndex)
                while j < tok.endIndex {
                    let ch = tok[j]
                    guard let def = defs.first(where: { $0.short == ch }) else {
                        throw CLIError("unknown option -\(ch)")
                    }
                    if def.takesValue {
                        let rest = String(tok[tok.index(after: j)...])
                        if !rest.isEmpty { out.values[def.long] = rest }
                        else {
                            guard i + 1 < argv.count else {
                                throw CLIError("option --\(def.long) needs a value")
                            }
                            out.values[def.long] = argv[i + 1]; i += 1
                        }
                        break
                    } else {
                        out.flags.insert(def.long)
                    }
                    j = tok.index(after: j)
                }
                i += 1; continue
            }
            out.positionals.append(tok); i += 1
        }
        return out
    }

    public func usage(subcommand: String? = nil) -> String {
        var lines: [String] = []
        let head = subcommand.map { "\(prog) \($0)" } ?? prog
        lines.append("usage: \(head) [options]\(positionalsHelp.isEmpty ? "" : " " + positionalsHelp.map { $0.0.uppercased() }.joined(separator: " "))")
        if !description.isEmpty { lines.append("  \(description)") }
        for (name, help) in positionalsHelp {
            lines.append(String(format: "  %-22@ %@", name, help))
        }
        for d in defs {
            var spec = "--\(d.long)"
            if let m = d.metavar { spec += " \(m)" } else if d.takesValue { spec += " VALUE" }
            if let s = d.short { spec += ", -\(s)" }
            lines.append(String(format: "  %-22@ %@", spec, d.help))
        }
        return lines.joined(separator: "\n")
    }
}

// ------------------------------------------------------------------ shared specs

private let blobModes = ["include", "exclude", "config"]

/// zmmboxmove-compatible knobs shared by move / preflight / batch.
func addMoveArgs(to parser: inout ArgParser) {
    parser.addOption("max-syncs", metavar: "N", help: "max unlocked sync passes (NE default 10)")
    parser.addOption("sync-finish-threshold", metavar: "MS",
                     help: "stop unlocked passes when one takes <= MS (NE code default 180s; NE doc says 30s)")
    parser.addFlag("sync", help: "NE compat no-op: zmove always runs synchronously and waits for completion")
    parser.addOption("blobs", help: "include|exclude|config (config = zimbraMailboxMoveSkip* attrs)")
    parser.addOption("secondary-blobs", help: "include|exclude|config")
    parser.addOption("search-index", help: "include|exclude|config")
    parser.addFlag("skip-lockout", help: "NE skipRemoteLockout")
    parser.addFlag("skip-memcache-purge", help: "NE skipMemcachePurge")
    parser.addFlag("overwrite", help: "remove a stray mailbox on destination")
    parser.addFlag("ng-migration", help: "NE-only flag: rejected (no documented semantics, refusing beats ignoring)")
    parser.addOption("db-strategy", help: "delta = pre-stage DB online | full")
    parser.addOption("verify", help: "full|count|none")
    parser.addOption("cutover-window", metavar: "HH:MM-HH:MM", help: "lock only inside this window")
    parser.addOption("max-lock-seconds", metavar: "S", help: "watchdog: abort+unlock if lock exceeds")
    parser.addOption("rsync-timeout", metavar: "S", help: "timeout per rsync pass, 0 = no timeout")
    parser.addOption("db-timeout", metavar: "S", help: "timeout per DB copy/compare batch, 0 = no timeout")
    parser.addOption("exclude-tables", help: "comma list of mboxgroup tables to skip (e.g. event)")
    parser.addFlag("reindex-after", help: "re-index on destination after move")
    parser.addFlag("no-flush-mta", help: "do not reschedule this account's deferred mail on the MTAs")
    parser.addFlag("background", help: "detach and run asynchronously")
    parser.addFlag("force", help: "override stale-cache safety check")
    parser.addFlag("keep-stage", help: "keep staging schema for forensics")
    parser.addFlag("confirm-steps", help: "prompt before each mutating step; answering no pauses the job, resume continues")
    parser.addFlag("yes", short: "y", help: "no interactive confirmation")
}

/// MoveMailboxRequest-shaped flags (NE port: full copy while locked).
func addNeMoveArgs(to parser: inout ArgParser) {
    parser.addPositional("account")
    parser.addOption("from", short: "f", help: "current home server of the account")
    parser.addOption("to", short: "t", help: "destination server")
    parser.addOption("max-syncs", help: "max unlocked sync passes (NE default 10)")
    parser.addOption("sync-finish-threshold", metavar: "MS",
                     help: "stop unlocked passes when one takes <= MS (NE code default 180000)")
    parser.addOption("blobs", help: "include|exclude|config")
    parser.addOption("secondary-blobs", help: "include|exclude|config")
    parser.addOption("search-index", help: "include|exclude|config")
    parser.addFlag("skip-lockout", help: "NE skipRemoteLockout")
    parser.addFlag("skip-memcache-purge", help: "NE skipMemcachePurge")
    parser.addOption("verify", help: "full|count|none")
    parser.addOption("exclude-tables", help: "comma list of mboxgroup tables to skip")
    parser.addFlag("keep-stage", help: "keep staging schema for forensics")
}

/// zmmboxmove-compatible flags (NE compat path: asks destination to move).
func addMboxmoveArgs(to parser: inout ArgParser) {
    parser.addOption("account", short: "a", help: "email address of account to move")
    parser.addOption("from", short: "f", help: "current home server of the account")
    parser.addOption("to", short: "t", help: "destination server")
    parser.addFlag("sync", help: "run synchronously")
    parser.addFlag("force", help: "force the move even if checks fail")
    parser.addFlag("ng-migration", help: "run for ng migration (Z-10 locators)")
    parser.addOption("server", short: "s", help: "mail server hostname (overridden by --to)")
    parser.addOption("authtoken", help: "use auth token string (JSON) from command line")
    parser.addOption("authtokenfile", help: "read auth token (JSON) from a file")
}

// ------------------------------------------------------------------ option maps

func moveOpts(_ a: ParsedArgs) throws -> [String: Any] {
    if a.flag("ng-migration") {
        throw CLIError("ngMigration is an NE-only contract flag with no documented semantics; zmove refuses it rather than silently ignoring it")
    }
    if a.flag("confirm-steps") && a.flag("yes") {
        throw CLIError("--confirm-steps and --yes conflict: drop one")
    }
    if let v = a.opt("blobs"), !blobModes.contains(v) {
        throw CLIError("--blobs must be include|exclude|config, got '\(v)'")
    }
    if let v = a.opt("secondary-blobs"), !blobModes.contains(v) {
        throw CLIError("--secondary-blobs must be include|exclude|config, got '\(v)'")
    }
    if let v = a.opt("search-index"), !blobModes.contains(v) {
        throw CLIError("--search-index must be include|exclude|config, got '\(v)'")
    }
    if let v = a.opt("db-strategy"), v != "delta" && v != "full" {
        throw CLIError("--db-strategy must be delta|full, got '\(v)'")
    }
    if let v = a.opt("verify"), !["full", "count", "none"].contains(v) {
        throw CLIError("--verify must be full|count|none, got '\(v)'")
    }
    var opts: [String: Any] = [:]
    func put(_ key: String, _ value: Any?) {
        if let v = value { opts[key] = v }
    }
    put("max_syncs", try a.intOpt("max-syncs"))
    put("sync_finish_threshold_ms", try a.intOpt("sync-finish-threshold"))
    put("blobs", a.opt("blobs"))
    put("secondary_blobs", a.opt("secondary-blobs"))
    put("search_index", a.opt("search-index"))
    if a.flag("skip-lockout") { opts["skip_lockout"] = true }
    if a.flag("skip-memcache-purge") { opts["skip_memcache_purge"] = true }
    if a.flag("overwrite") { opts["overwrite"] = true }
    put("db_strategy", a.opt("db-strategy"))
    put("verify", a.opt("verify"))
    if a.flag("no-flush-mta") { opts["flush_mta"] = false }
    put("cutover_window", a.opt("cutover-window"))
    put("max_lock_seconds", try a.intOpt("max-lock-seconds"))
    put("rsync_timeout", try a.intOpt("rsync-timeout"))
    put("db_timeout", try a.intOpt("db-timeout"))
    if let t = a.opt("exclude-tables"), !t.isEmpty {
        opts["exclude_tables"] = t.split(separator: ",").map(String.init)
    }
    if a.flag("reindex-after") { opts["reindex_after"] = true }
    if a.flag("force") { opts["force"] = true }
    if a.flag("keep-stage") { opts["keep_stage"] = true }
    if a.flag("confirm-steps") { opts["confirm_steps"] = true }
    return opts
}

func neOpts(_ a: ParsedArgs) throws -> [String: Any] {
    var opts: [String: Any] = [:]
    func put(_ key: String, _ value: Any?) {
        if let v = value { opts[key] = v }
    }
    put("max_syncs", try a.intOpt("max-syncs"))
    put("sync_finish_threshold_ms", try a.intOpt("sync-finish-threshold"))
    put("blobs", a.opt("blobs"))
    put("secondary_blobs", a.opt("secondary-blobs"))
    put("search_index", a.opt("search-index"))
    if a.flag("skip-lockout") { opts["skip_lockout"] = true }
    if a.flag("skip-memcache-purge") { opts["skip_memcache_purge"] = true }
    put("verify", a.opt("verify"))
    if let t = a.opt("exclude-tables"), !t.isEmpty {
        opts["exclude_tables"] = t.split(separator: ",").map(String.init)
    }
    if a.flag("keep-stage") { opts["keep_stage"] = true }
    return opts
}

// ------------------------------------------------------------------ output

func phaseName(_ p: Phase) -> String {
    switch p {
    case .planned: return "PLANNED"
    case .preflightOK: return "PREFLIGHT_OK"
    case .reserved: return "RESERVED"
    case .presync: return "PRESYNC"
    case .prestaged: return "PRESTAGED"
    case .locked: return "LOCKED"
    case .finalSynced: return "FINAL_SYNCED"
    case .dbFinal: return "DB_FINAL"
    case .verified: return "VERIFIED"
    case .merged: return "MERGED"
    case .flipped: return "FLIPPED"
    case .cachesPurged: return "CACHES_PURGED"
    case .unlocked: return "UNLOCKED"
    case .done: return "DONE"
    case .purged: return "PURGED"
    }
}

func cliJSON(_ value: Any) -> String {
    switch value {
    case let s as String:
        var e = s.replacingOccurrences(of: "\\", with: "\\\\")
        e = e.replacingOccurrences(of: "\"", with: "\\\"")
        e = e.replacingOccurrences(of: "\n", with: "\\n")
        e = e.replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(e)\""
    case let b as Bool: return b ? "true" : "false"
    case let i as Int: return String(i)
    case let d as Double:
        if d.truncatingRemainder(dividingBy: 1) == 0 && abs(d) < 1e15 { return String(Int64(d)) }
        return String(d)
    case let a as [Any]:
        return "[" + a.map(cliJSON).joined(separator: ", ") + "]"
    case let d as [String: Any]:
        let inner = d.keys.sorted().map { "\(cliJSON($0)): \(cliJSON(d[$0]!))" }.joined(separator: ", ")
        return "{\(inner)}"
    default:
        return cliJSON(String(describing: value))
    }
}

func cliJSONPretty(_ value: Any, indent: Int = 0) -> String {
    let pad = String(repeating: " ", count: indent)
    let pad2 = String(repeating: " ", count: indent + 2)
    switch value {
    case let d as [String: Any]:
        if d.isEmpty { return "{}" }
        let inner = d.keys.sorted().map { "\(pad2)\(cliJSON($0)): \(cliJSONPretty(d[$0]!, indent: indent + 2))" }.joined(separator: ",\n")
        return "{\n\(inner)\n\(pad)}"
    case let a as [Any]:
        if a.isEmpty { return "[]" }
        let inner = a.map { "\(pad2)\(cliJSONPretty($0, indent: indent + 2))" }.joined(separator: ",\n")
        return "[\n\(inner)\n\(pad)]"
    default:
        return cliJSON(value)
    }
}

func printJob(_ j: Job, asJSON: Bool = false) {
    if asJSON {
        print(cliJSON(["id": j.id, "account": j.account, "src": j.src, "dst": j.dst,
                       "phase": phaseName(j.phase), "status": j.status,
                       "error": j.error as Any, "data": j.data,
                       "created": j.created, "updated": j.updated]))
        return
    }
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm"
    let ts = df.string(from: Date(timeIntervalSince1970: j.created))
    let hb = j.heartbeat > 0 ? Int(Date().timeIntervalSince1970 - j.heartbeat) : -1
    let lock = j.data["lock_seconds"].map { "\($0)" } ?? "-"
    print("\(j.id)  \(ts)  \(j.account) \(j.src) -> \(j.dst)  \(j.status) \(phaseName(j.phase)) lock=\(lock)s hb=\(hb)s" +
        (j.error.map { "\n    error: \($0)" } ?? ""))
}

 func confirmPurge(job: Job) -> Bool {
     confirmPurge(job: job, isTTY: isStdinTTY(), readInput: { readLine(strippingNewline: true) })
 }
 
 func confirmPurge(job: Job, isTTY: Bool, readInput: () -> String?) -> Bool {
     guard isTTY else { return false }
     let want = job.data["src_mailbox_id"].map { "\($0)" } ?? "?"
     fputs("type '\(job.account)' to purge mailbox \(want) on \(job.src): ", stderr)
     guard let ans = readInput() else { return false }
     return ans.trimmingCharacters(in: .whitespaces) == job.account
 }

func isStdinTTY() -> Bool {
#if canImport(Darwin)
    return isatty(STDIN_FILENO) != 0
#else
    return Glibc.isatty(STDIN_FILENO) != 0
#endif
}

/// Detach and run asynchronously, mirroring cli.py _background.
func runBackground(argv: [String], logDir: String) -> Int32 {
    let filtered = argv.filter { $0 != "--background" }
    let exe = CommandLine.arguments[0]
    let logFile = (logDir as NSString).appendingPathComponent("background.log")
    try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
    let proc = Process()
    if FileManager.default.fileExists(atPath: "/usr/bin/setsid") {
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/setsid")
        proc.arguments = [exe] + filtered + ["--yes"]
    } else {
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = filtered + ["--yes"]
    }
    proc.standardInput = FileHandle.nullDevice
    if !FileManager.default.fileExists(atPath: logFile) {
         _ = FileManager.default.createFile(atPath: logFile, contents: nil)
    }
    proc.standardOutput = FileHandle(forWritingAtPath: logFile)
    proc.standardError = proc.standardOutput
    do {
        try proc.run()
    } catch {
        fputs("error: cannot detach background job: \(error)\n", stderr)
        return 1
    }
    print("started in background, pid \(proc.processIdentifier); follow with `zmove query` / \(logFile)")
    return 0
}

// ------------------------------------------------------------------ dispatch

public enum ZMoveCLI {
    public static func main(_ argv: [String]) -> Int32 {
        do {
            return try run(argv)
        } catch let e as CLIError {
            fputs("error: \(e.message)\n", stderr)
            return 2
        } catch {
            fputs("error: \(type(of: error)): \(error)\n", stderr)
            return 1
        }
    }

    static func run(_ argv: [String]) throws -> Int32 {
        // Global flags precede the subcommand; --version works anywhere global.
        var configPath: String? = nil
        var verbose = false
        var dryRun = false
        var cmd: String? = nil
        var rest: [String] = []
        var i = 0
        while i < argv.count {
            let t = argv[i]
            if cmd == nil && (t == "-c" || t == "--config") {
                guard i + 1 < argv.count else { throw CLIError("option --config needs a value") }
                configPath = argv[i + 1]; i += 2; continue
            }
            if cmd == nil && t.hasPrefix("--config=") {
                configPath = String(t.dropFirst("--config=".count)); i += 1; continue
            }
            if cmd == nil && (t == "-v" || t == "--verbose") { verbose = true; i += 1; continue }
            if cmd == nil && (t == "-n" || t == "--dry-run") { dryRun = true; i += 1; continue }
            if cmd == nil && t == "--version" { print(zmoveVersion); return 0 }
            if cmd == nil && (t == "-h" || t == "--help") { print(globalUsage()); return 0 }
            if cmd == nil && t.hasPrefix("-") {
                throw CLIError("unknown global option \(t)")
            }
            if cmd == nil { cmd = t; rest = Array(argv.dropFirst(i + 1)); break }
            i += 1
        }
        guard let command = cmd else { fputs(globalUsage() + "\n", stderr); return 2 }
        _ = verbose

        let settings: Settings
        do {
            settings = try loadConfig(path: configPath)
        } catch {
            fputs("error: bad config: \(error)\n", stderr)
            return 2
        }

        // --background relaunches detached (move / preflight / batch only).
        if ["move", "preflight", "batch"].contains(command) && argv.contains("--background") {
            var probe = ArgParser(prog: "zmove \(command)")
            addMoveArgs(to: &probe)
            let pa = try probe.parse(rest)
            if pa.flag("confirm-steps") {
                fputs("error: --confirm-steps needs an interactive terminal; drop --background\n", stderr)
                return 2
            }
            return runBackground(argv: [command] + rest, logDir: settings.logDir)
        }

        let state = try State(path: settings.stateDb)
        let eng = Engine(settings: settings, state: state, dryRun: dryRun,
                         progress: { print($0); fflush(stdout) })

        switch command {
        case "preflight": return try cmdPreflight(eng: eng, rest: rest)
        case "mboxmove": return cmdMboxmove(settings: settings, rest: rest, dryRun: dryRun)
        case "ne-move": return try cmdNeMove(settings: settings, rest: rest)
        case "move": return try cmdMove(eng: eng, state: state, rest: rest)
        case "batch": return try cmdBatch(settings: settings, rest: rest, dryRun: dryRun)
        case "query": return try cmdQuery(eng: eng, state: state, rest: rest)
        case "events": return try cmdEvents(state: state, rest: rest)
        case "resume": return try cmdResume(eng: eng, state: state, rest: rest)
        case "abort": return try cmdAbort(eng: eng, state: state, rest: rest)
        case "rollback": return try cmdRollback(eng: eng, state: state, rest: rest)
        case "purge": return try cmdPurge(eng: eng, state: state, rest: rest)
        case "unlock": return try cmdUnlock(eng: eng, rest: rest)
        case "gc": return try cmdGC(eng: eng, state: state, rest: rest)
        case "-h", "--help", "help": print(globalUsage()); return 0
        default:
            fputs("error: unknown command '\(command)'\n\(globalUsage())\n", stderr)
            return 2
         }
     }

    static func globalUsage() -> String {
        """
        usage: zmove [options] <command> [args]
          Online mailbox move for Zimbra FOSS (zmmboxmove-compatible, DB+blob level, item IDs preserved)
          -c, --config PATH   config file
          -v, --verbose       verbose logging
          -n, --dry-run       print mutating commands only
          --version            print version
        commands: move mboxmove ne-move preflight batch query events resume abort rollback purge unlock gc
        """
    }

    // -- preflight: all checks + estimates, changes nothing.
    static func cmdPreflight(eng: Engine, rest: [String]) throws -> Int32 {
        var p = ArgParser(prog: "zmove preflight")
        p.addPositional("account")
        p.addOption("from", short: "f")
        p.addOption("to", short: "t")
        addMoveArgs(to: &p)
        let a = try p.parse(rest)
        guard let account = a.positionals.first else {
            throw CLIError("the following arguments are required: account")
        }
        guard let src = a.opt("from"), let dst = a.opt("to") else {
            throw CLIError("the following arguments are required: -f/--from, -t/--to")
        }
        let acct = try accountInfo(host: eng.host(dst), account: account)
        let opts = try moveOpts(a)
        let tmp = Job(id: "preflight", account: acct.name, accountId: acct.id,
                      src: src, dst: dst, options: opts)
        let rep = try eng.plan(job: tmp)
        print(cliJSONPretty(rep))
        if let errs = rep["errors"] as? [Any], !errs.isEmpty { return 1 }
        return 0
    }

    // -- mboxmove: NE compat, asks the destination server to move the mailbox.
    static func cmdMboxmove(settings: Settings, rest: [String], dryRun: Bool) -> Int32 {
        var p = ArgParser(prog: "zmove mboxmove")
        addMboxmoveArgs(to: &p)
        do {
            let a = try p.parse(rest)
            guard let account = a.opt("account"), let src = a.opt("from"),
                  let dst = a.opt("to") else {
                throw CLIError("the following arguments are required: -a/--account, -f/--from, -t/--to")
            }
            _ = dryRun
            return runMboxMove(settings: settings, account: account, src: src, dst: dst,
                               sync: a.flag("sync"), force: a.flag("force"),
                               ngMigration: a.flag("ng-migration"),
                               authtoken: a.opt("authtoken"),
                               authtokenFile: a.opt("authtokenfile"))
        } catch let e as CLIError {
            fputs("error: \(e.message)\n", stderr)
            return 2
        } catch {
            fputs("error: \(type(of: error)): \(error)\n", stderr)
            return 1
        }
    }

    // -- ne-move: NE-faithful server-side move (full DB copy while locked).
    static func cmdNeMove(settings: Settings, rest: [String]) throws -> Int32 {
        var p = ArgParser(prog: "zmove ne-move")
        addNeMoveArgs(to: &p)
        let a = try p.parse(rest)
        guard let account = a.positionals.first else {
            throw CLIError("the following arguments are required: account")
        }
        guard let src = a.opt("from"), let dst = a.opt("to") else {
            throw CLIError("the following arguments are required: -f/--from, -t/--to")
        }
        let ne = NeServerMove(settings: settings)
        let info = try ne.run(account: account, src: src, dst: dst,
                              options: try neOpts(a), sync: true)
        _ = info
        return 0
    }

    // -- move: one mailbox through the durable job engine.
    static func cmdMove(eng: Engine, state: State, rest: [String]) throws -> Int32 {
        var p = ArgParser(prog: "zmove move")
        p.addPositional("account")
        p.addOption("from", short: "f")
        p.addOption("to", short: "t")
        addMoveArgs(to: &p)
        let a = try p.parse(rest)
        guard let account = a.positionals.first else {
            throw CLIError("the following arguments are required: account")
        }
        guard let src = a.opt("from"), let dst = a.opt("to") else {
            throw CLIError("the following arguments are required: -f/--from, -t/--to")
        }
        var job = try eng.newJob(account: account, src: src, dst: dst, options: try moveOpts(a))
        print("job \(job.id)")
        _ = try eng.run(&job)
        if let done = try state.get(job.id) { printJob(done) }
        return 0
    }

    // -- batch: many mailboxes from a CSV plan (account,src,dst).
    static func cmdBatch(settings: Settings, rest: [String], dryRun: Bool) throws -> Int32 {
        var p = ArgParser(prog: "zmove batch")
        p.addPositional("plan")
        p.addOption("parallel")
        p.addOption("per-server")
        p.addOption("max-cutovers")
        p.addOption("canary", metavar: "N")
        addMoveArgs(to: &p)
        let a = try p.parse(rest)
        guard let plan = a.positionals.first else {
            throw CLIError("the following arguments are required: plan")
        }
        let opts = try moveOpts(a)
        if opts["confirm_steps"] != nil {
            fputs("error: --confirm-steps is interactive and cannot be used with batch\n", stderr)
            return 2
        }
        let parallel = (try a.intOpt("parallel")) ?? 4
        let perServer = (try a.intOpt("per-server")) ?? 2
        let maxCutovers = (try a.intOpt("max-cutovers")) ?? 2
        let canary = (try a.intOpt("canary")) ?? 0
        let items = try readPlan(plan)
        let b = Batch(settings: settings, parallel: parallel, perServer: perServer,
                      maxCutovers: maxCutovers, dryRun: dryRun)
        let res = b.run(items, options: opts, canary: canary)
        let bad = res.filter { $0.2 != nil }
        print("\(res.count - bad.count) ok, \(bad.count) failed")
        for (it, _, err) in bad { print("  FAIL \(it.account): \(err ?? "")") }
        return bad.isEmpty ? 0 : 1
    }

    // -- query: show moves (zmmboxmovequery).
    static func cmdQuery(eng: Engine, state: State, rest: [String]) throws -> Int32 {
        var p = ArgParser(prog: "zmove query")
        p.addPositional("account", help: "optional account email or id")
        p.addOption("server", short: "s")
        p.addOption("status")
        p.addFlag("check-peer", help: "also check LDAP/lock state live")
        p.addFlag("json")
        let a = try p.parse(rest)
        let account = a.positionals.first
        var jobs = try state.find(account: account, server: a.opt("server"),
                                  status: a.opt("status"))
        if let acct = account, jobs.isEmpty, let srv = a.opt("server") {
            if let info = try? accountInfo(host: eng.host(srv), account: acct) {
                jobs = (try? state.find(account: info.id)) ?? []
            }
        }
        for j in jobs {
            printJob(j, asJSON: a.flag("json"))
            if a.flag("check-peer") && (j.status == "running" || j.status == "failed") {
                if let acct = try? accountInfo(host: eng.host(j.dst), account: j.account) {
                    print("    live: zimbraMailHost=\(acct.mailHost) status=\(acct.status)")
                }
                var hits: [String] = []
                for peer in [j.src, j.dst] {
                    do {
                        if let mv = try eng.soap(peer).queryMoves(j.account), !mv.isEmpty {
                            hits.append("\(peer): \(cliJSON(mv))")
                        }
                    } catch {
                        hits.append("\(peer): <lookup on \(peer) failed>")
                    }
                }
                if !hits.isEmpty {
                    print("    NE QueryMailboxMove: " + hits.joined(separator: "; "))
                } else {
                    print("    NE QueryMailboxMove: no move reported (or unsupported on this server)")
                }
            }
        }
        return 0
    }

    // -- events: event log of a job.
    static func cmdEvents(state: State, rest: [String]) throws -> Int32 {
        var p = ArgParser(prog: "zmove events")
        p.addPositional("job")
        let a = try p.parse(rest)
        guard let id = a.positionals.first else {
            throw CLIError("the following arguments are required: job")
        }
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        for row in try state.events(jobId: id) {
            let ts = (row[0] as? Double).map { df.string(from: Date(timeIntervalSince1970: $0)) } ?? "--:--:--"
            let ph: String
            if let n = row[1] as? Int, let phase = Phase(rawValue: n) { ph = phaseName(phase) }
            else { ph = "?" }
            let lvl = (row[2] as? String) ?? "-"
            let msg = (row[3] as? String) ?? ""
            print("\(ts) \(ph) \(lvl) \(msg)")
        }
        return 0
    }

    // -- resume: continue a failed/interrupted job.
    static func cmdResume(eng: Engine, state: State, rest: [String]) throws -> Int32 {
        var p = ArgParser(prog: "zmove resume")
        p.addPositional("job")
        p.addFlag("force")
        p.addFlag("yes", short: "y", help: "skip per-step confirmations for this run")
        let a = try p.parse(rest)
        guard let id = a.positionals.first else {
            throw CLIError("the following arguments are required: job")
        }
        guard var job = try state.get(id) else {
            fputs("error: no such job \(id)\n", stderr)
            return 1
        }
        if job.status == "done" { print("already done"); return 0 }
        if job.status == "aborted" && !a.flag("yes") && isStdinTTY() {
            fputs("job \(job.id) was aborted; its copies were removed and it will restart from RESERVED. proceed? [y/N] ", stderr)
            if readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces).lowercased() != "y" {
                return 1
            }
        }
        if a.flag("force") { job.options["force"] = true }
        if a.flag("yes") { job.options["confirm_steps"] = false }
        _ = try eng.run(&job)
        if let done = try state.get(job.id) { printJob(done) }
        return 0
    }

    // -- abort: undo a job that has not reached FLIPPED.
    static func cmdAbort(eng: Engine, state: State, rest: [String]) throws -> Int32 {
        var p = ArgParser(prog: "zmove abort")
        p.addPositional("job")
        p.addFlag("force")
        let a = try p.parse(rest)
        guard let id = a.positionals.first else {
            throw CLIError("the following arguments are required: job")
        }
        guard var job = try state.get(id) else {
            fputs("error: no such job \(id)\n", stderr)
            return 1
        }
        _ = try eng.abort(job: &job, reason: "manual")
        return 0
    }

    // -- rollback: flip back to the untouched source copy after cutover.
    static func cmdRollback(eng: Engine, state: State, rest: [String]) throws -> Int32 {
        var p = ArgParser(prog: "zmove rollback")
        p.addPositional("job")
        p.addFlag("force")
        let a = try p.parse(rest)
        guard let id = a.positionals.first else {
            throw CLIError("the following arguments are required: job")
        }
        guard var job = try state.get(id) else {
            fputs("error: no such job \(id)\n", stderr)
            return 1
        }
        _ = try eng.rollback(job: &job, force: a.flag("force"))
        return 0
    }

    // -- purge: delete the old copy on the source (zmpurgeoldmbox).
    static func cmdPurge(eng: Engine, state: State, rest: [String]) throws -> Int32 {
        var p = ArgParser(prog: "zmove purge")
        p.addPositional("account")
        p.addOption("server", short: "s", help: "source server of the move")
        p.addOption("job")
        p.addOption("older-than", metavar: "DAYS")
        p.addFlag("all", help: "purge every eligible finished move")
        p.addFlag("keep-blobs", help: "delete DB rows only")
        p.addFlag("yes", short: "y")
        let a = try p.parse(rest)
        let olderThan = (try a.floatOpt("older-than")) ?? 0
        var jobs: [Job]
        if let id = a.opt("job") {
            guard let j = try state.get(id) else {
                fputs("error: no such job \(id)\n", stderr)
                return 1
            }
            jobs = [j]
        } else {
            jobs = try state.find(account: a.positionals.first, server: a.opt("server"))
                .filter {
                    $0.phase == .done && $0.status == "done" &&
                    $0.data["rolled_back_at"] == nil &&
                    (a.opt("server") == nil || $0.src == a.opt("server"))
                }
            if !a.flag("all") && a.positionals.first == nil {
                fputs("error: give ACCOUNT, --job or --all\n", stderr)
                return 2
            }
        }
        let cutoff = Date().timeIntervalSince1970 - olderThan * 86400
        jobs = jobs.filter { $0.updated <= cutoff }
        if jobs.isEmpty { print("nothing to purge"); return 0 }
        for j in jobs {
            print("will purge mailbox \(j.data["src_mailbox_id"].map { "\($0)" } ?? "?") of \(j.account) on \(j.src)")
        }
        if !a.flag("yes") {
            for j in jobs {
                if !confirmPurge(job: j) {
                    fputs("purge declined for \(j.account); aborting (use --yes to skip confirmation)\n", stderr)
                    return 1
                }
            }
        }
        for j in jobs {
            var m = j
            _ = try eng.purge(job: &m, keepBlobs: a.flag("keep-blobs"))
        }
        return 0
    }

    // -- unlock: recover an account left locked (zmprov ulm).
    static func cmdUnlock(eng: Engine, rest: [String]) throws -> Int32 {
        var p = ArgParser(prog: "zmove unlock")
        p.addPositional("account")
        p.addOption("server", short: "s", help: "any mailstore to run zmprov on")
        let a = try p.parse(rest)
        guard let account = a.positionals.first else {
            throw CLIError("the following arguments are required: account")
        }
        guard let server = a.opt("server") else {
            throw CLIError("the following arguments are required: -s/--server")
        }
        try eng.unlock(account: account, server: server)
        print("\(account) unlocked")
        return 0
    }

    // -- gc: clean leftovers of failed/aborted jobs.
    static func cmdGC(eng: Engine, state: State, rest: [String]) throws -> Int32 {
        var p = ArgParser(prog: "zmove gc")
        p.addOption("older-than", metavar: "HOURS")
        p.addOption("prune-events", metavar: "DAYS")
        let a = try p.parse(rest)
        let olderThan = (try a.floatOpt("older-than")) ?? 24
        let pruneEvents = (try a.floatOpt("prune-events")) ?? 0
        let cutoff = Date().timeIntervalSince1970 - olderThan * 3600
        if pruneEvents > 0 {
            let n = try state.pruneEvents(maxAgeDays: pruneEvents)
            print("pruned \(n) old event rows")
        }
        var cleaned = 0
        let pending = try state.find(status: "aborted") + state.find(status: "failed")
        for j in pending {
            if j.updated > cutoff || j.phase.rawValue >= Phase.flipped.rawValue ||
                j.data["gc_at"] != nil { continue }
            if j.status == "failed" &&
                (j.phase.rawValue >= Phase.locked.rawValue || j.data["locking"] != nil) {
                print("skip \(j.id): failed while locked, resolve with resume/abort")
                continue
            }
            do {
                var m = j
                let what = eng.gcJob(job: &m)
                print("\(what) \(j.id)")
                cleaned += 1
            } catch {
                print("  \(j.id): cleanup failed (\(type(of: error)): \(error))")
                continue
            }
        }
        if cleaned == 0 && pruneEvents == 0 { print("nothing to clean") }
        return 0
    }
}
 
 /// Standalone `zmmboxmove` entry: parses NE-compat flags, loads the default
 /// config, and asks the destination server to move the mailbox.
 /// Mirrors compat_mboxmove.main (prog=zmmboxmove).
 public enum ZMMBoxMove {
     public static func main(_ argv: [String]) -> Int32 {
         var p = ArgParser(prog: "zmmboxmove",
                           description: "NE zmmboxmove port: ask the destination server to move a mailbox")
         addMboxmoveArgs(to: &p)
         do {
             let a = try p.parse(argv)
             guard let account = a.opt("account"), let src = a.opt("from"),
                   let dst = a.opt("to") else {
                 fputs("Error occurred: the following arguments are required: -a/--account, -f/--from, -t/--to\n", stderr)
                 return 2
             }
             let s: Settings
             do {
                 s = try loadConfig(path: nil)
             } catch {
                 fputs("Error occurred: bad config: \(error)\n", stderr)
                 return 1
             }
             return runMboxMove(settings: s, account: account, src: src, dst: dst,
                                sync: a.flag("sync"), force: a.flag("force"),
                                ngMigration: a.flag("ng-migration"),
                                authtoken: a.opt("authtoken"),
                                authtokenFile: a.opt("authtokenfile"))
         } catch let e as CLIError {
             fputs("Error occurred: \(e.message)\n", stderr)
             return 2
         } catch {
             fputs("Error occurred: \(type(of: error)): \(error)\n", stderr)
             return 1
         }
     }
 }

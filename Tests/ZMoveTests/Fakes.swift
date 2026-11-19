/// Fake transport layer for tests: records commands, answers from a
/// {substring: output} table. Port of tests/fakes.py.
import Foundation
@testable import ZMove

/// `zmprov -l ga` output for the fixture account.
func gaText(name: String, id: String = "id1", mailHost: String,
            transport: String = "lmtp:src:7025", status: String,
            aliases: [String] = []) -> String {
    var lines = ["# name \(name)", "zimbraId: \(id)", "zimbraMailHost: \(mailHost)",
                 "zimbraMailTransport: \(transport)", "zimbraAccountStatus: \(status)",
                 "mail: \(name)"]
     for a in aliases { lines += ["mail: \(a)", "zimbraMailAlias: \(a)"] }
    lines.append("zimbraMailDeliveryAddress: \(name)")
    return lines.joined(separator: "\n") + "\n"
}

final class FakeHost: ZMove.Host {
    var cmds: [String] = []
    var answers: [String: String]
    var fail: [String]

    init(name: String, answers: [String: String] = [:],
         fail: [String] = [], settings: Settings = Settings()) {
        self.answers = answers
        self.fail = fail
        super.init(name: name, settings: settings)
    }

    override func run(_ cmd: String, input: String? = nil, check: Bool = true,
                      timeout: Double? = nil, mutating: Bool = true) throws -> CommandResult {
        cmds.append(cmd)
        if fail.contains(where: { cmd.contains($0) }) {
            if check { throw RemoteError(host: name, cmd: cmd, rc: 1, stderr: "boom") }
            return CommandResult(rc: 1, out: "", err: "boom", seconds: 0)
        }
        for (k, v) in answers where cmd.contains(k) {
            return CommandResult(rc: 0, out: v, err: "", seconds: 0)
        }
        return CommandResult(rc: 0, out: "", err: "", seconds: 0)
    }
}

final class FakeMySQL: MySQL {
    var schemas: [String: Set<String>]
    var executed: [String] = []

    init(schemas: [String: Set<String>] = [:], host: ZMove.Host? = nil) {
        self.schemas = schemas
        super.init(host: host ?? FakeHost(name: "dst"),
                   mysqlBin: "mysql", mysqldumpBin: "mysqldump",
                   myCnf: "/opt/zimbra/conf/my.cnf")
    }

    override func schemaExists(_ schema: String) -> Bool { schemas[schema] != nil }

    override func allTables(_ schema: String) -> [String] {
        (schemas[schema] ?? []).sorted()
    }

    override func scalar(_ sql: String, db: String? = nil,
                         timeout: Double? = nil) -> String? {
        let cands = schemas.keys.filter {
            $0.hasPrefix("mboxgroup") && (schemas[$0]?.contains("mail_item") ?? false)
                && !sql.contains("'\($0)'")
        }.sorted()
        return cands.first
    }

    override func execute(_ sql: String, db: String? = nil,
                          timeout: Double? = nil) throws {
        executed.append(sql)
    }
}

final class FakeDbMove: DbMove {
    var dropped = 0
    var deleted = 0
    var inUse = false

    init(dstId: Int = 42) {
        let p = DbPlan(account: "a", accountId: "id", srcId: 1, srcGroup: 1,
                       dstId: dstId, dstGroup: 7, dstIndexVolume: 3,
                       stage: "zmove_stage_x", volMap: [:])
        super.init(plan: p, src: FakeMySQL(), dst: FakeMySQL())
    }

    override func dropStage() throws { dropped += 1 }

    override func deleteLiveDst(timeout: Double? = nil) throws {
        deleted += 1
        inUse = false
    }
}

final class FakeSoap: AdminSoap {
    var tokenText = "T"
    var moveEffect: Error? = nil
    var callEffect: Error? = nil
    var calls: [String] = []

    init(host: ZMove.Host = FakeHost(name: "dst")) {
        super.init(host: host, port: 7071, user: nil, password: nil,
                   verifyTLS: false, tlsCA: nil)
    }

    override func token() throws -> String { tokenText }

    override func call(_ name: String, payload: [String: Any],
                       mutating: Bool = true) throws -> [String: Any] {
        calls.append(name)
        if let e = callEffect { throw e }
        return [:]
    }

    override func moveMailbox(name: String, src: String, dest: String, sync: Bool = false,
                              skipRemoteLockout: Bool = false,
                              ngMigration: Bool = false) throws -> [String: Any] {
        if let e = moveEffect { throw e }
        return [:]
    }
}

/// Shared engine-test fixture: journaled job, faked hosts/servers/SOAP.
/// Port of the `env` fixture in test_engine.py.
final class Lockouts {
    var items: [(String, String, String)] = []
}

struct Env {
    var eng: Engine
    var st: State
    var hosts: [String: FakeHost]
    var lockouts: Lockouts
    var job: Job
    var dir: String

    func setGa(mailHost: String = "src", status: String = "maintenance",
                transport: String = "lmtp:src:7025") {
         // Trailing space: "zmprov -l gas ..." (memcached/MTA discovery) must
         // NOT match this answer.
         for h in hosts.values {
             h.answers["zmprov -l ga "] = gaText(name: "o'brien@x", mailHost: mailHost,
                                                transport: transport, status: status)
         }
     }
 }

func makeEnv(mailHost: String = "src", status: String = "maintenance",
             settings: Settings = Settings()) throws -> Env {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("zmove-test-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let db = (dir as NSString).appendingPathComponent("s.db")
    let st = try State(path: db)
    var settings = settings
    settings.stateDb = db
    let eng = Engine(settings: settings, state: st)
    let hosts = ["src": FakeHost(name: "src"), "dst": FakeHost(name: "dst")]
    eng.hosts = hosts.mapValues { $0 as ZMove.Host }
    let lockouts = Lockouts()
    eng.lockoutHook = { lockouts.items.append(($0, $1, $2)) }
    for n in ["src", "dst"] {
        eng.servers[n] = ServerInfo(name: n, numGroups: 100, lmtpPort: 7026)
    }
    let env = Env(eng: eng, st: st, hosts: hosts, lockouts: lockouts,
                  job: try st.create(account: "o'brien@x", accountId: "id1",
                                      src: "src", dst: "dst", options: defaultOptions),
                  dir: dir)
    env.setGa(mailHost: mailHost, status: status)
    var job = env.job
     job.data.merge(["orig_status": "closed", "orig_transport": "lmtp:src:7025",
                     "copy": ["search_index": true], "dst_mailbox_id": 42]) { _, new in new }
    return Env(eng: eng, st: st, hosts: hosts, lockouts: lockouts, job: job, dir: dir)
}

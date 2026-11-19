/// Configuration (INI, stdlib only). Port of config.py.
import Foundation

public struct Settings: Sendable {
    // control node -> mailstore SSH
    public var sshUser = "zimbra"
    public var sshPort = 22
    public var sshKey: String? = nil
    public var sshOptions: [String] = []
    public var runAsZimbra = false
    // mailstore -> mailstore SSH (used by rsync running on source)
    public var nodeSshUser = "zimbra"
    public var nodeSshPort = 22
    public var nodeSshOptions = "-o BatchMode=yes -o StrictHostKeyChecking=accept-new"
    // zimbra install
    public var zimbraHome = "/opt/zimbra"
    public var mysqlBin = "/opt/zimbra/common/bin/mysql"
    public var mysqldumpBin = "/opt/zimbra/common/bin/mysqldump"
    public var rsyncBin = "rsync"
    // admin SOAP
    public var adminPort = 7071
    public var adminUser: String? = nil
    public var adminPassword: String? = nil
    public var verifyTLS = false
    // behaviour
    public var stateDb = "~/.local/share/zmove/state.db"
    public var logDir = "~/.local/share/zmove/logs"
    public var maxSyncs = 10
    public var syncFinishThresholdMs = 180000
    public var rsyncBwlimitKbps = 0
    public var ionice = true
    public var maxLockSeconds = 900
    public var cutoverWindow: String? = nil
    public var verify = "full"
    public var dbStrategy = "delta"
    public var mtaHosts: [String] = []
    public var sharedVolumes: [Int: Int] = [:]
    public var metricsTextfile: String? = nil
    public var rsyncTimeout: Int = 0
    public var dbTimeout: Int = 0
    public var tlsCa: String? = nil
    public var excludeTables: [String] = []
    public var reindexAfter = false
    public var flushMta = true
    public var force = false
    public var keepStage = false
    public var confirmSteps = false
    public var skipLockout = false
    public var skipMemcachePurge = false
    public mutating func expand() {
        stateDb = (stateDb as NSString).expandingTildeInPath
        logDir = (logDir as NSString).expandingTildeInPath
        if let k = sshKey { sshKey = (k as NSString).expandingTildeInPath }
    }
}

public enum ConfigError: Error, CustomStringConvertible {
    case unreadable(String)
    case invalid(String, String?)

    public var description: String {
        switch self {
        case .unreadable(let p): return "cannot read config: \(p)"
        case .invalid(let m, let src):
            return "bad config\(src.map { " (\($0))" } ?? ""): \(m)"
        }
    }
}

private func splitList(_ v: String) -> [String] {
    v.replacingOccurrences(of: "\n", with: ",").split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

public func defaultConfigPaths() -> [String] {
    ["./zmove.ini", "/etc/zmove/zmove.ini",
     ("~/.config/zmove/zmove.ini" as NSString).expandingTildeInPath]
}

public func loadConfig(path: String? = nil) throws -> Settings {
    var s = Settings()
    var found: String? = nil
    if let p = path {
        found = p
    } else {
        for p in defaultConfigPaths()
            where FileManager.default.fileExists(atPath: p) { found = p; break }
    }
    guard let src = found else { var e = s; e.expand(); return e }
    return try loadConfigFile(src, into: s)
}

private func loadConfigFile(_ path: String, into s: Settings) throws -> Settings {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        throw ConfigError.unreadable(path)
    }
    var s = s
    var section = ""
    for rawLine in text.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
        if line.hasPrefix("[") && line.hasSuffix("]") {
            section = String(line.dropFirst().dropLast()).lowercased()
            continue
        }
        guard section == "zmove", let eq = line.firstIndex(of: "=") else { continue }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
        let val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        switch key {
        case "ssh_user": s.sshUser = val
        case "ssh_port": s.sshPort = Int(val) ?? s.sshPort
        case "ssh_key": s.sshKey = val.isEmpty ? nil : val
        case "ssh_options": s.sshOptions = splitList(val)
        case "run_as_zimbra": s.runAsZimbra = val.uppercased() == "TRUE"
        case "node_ssh_user": s.nodeSshUser = val
        case "node_ssh_port": s.nodeSshPort = Int(val) ?? s.nodeSshPort
        case "node_ssh_options": s.nodeSshOptions = val
        case "zimbra_home": s.zimbraHome = val
        case "mysql_bin": s.mysqlBin = val
        case "mysqldump_bin": s.mysqldumpBin = val
        case "rsync_bin": s.rsyncBin = val
        case "admin_port": s.adminPort = Int(val) ?? s.adminPort
        case "admin_user": s.adminUser = val.isEmpty ? nil : val
        case "admin_password": s.adminPassword = val.isEmpty ? nil : val
        case "verify_tls": s.verifyTLS = val.uppercased() == "TRUE"
        case "state_db": s.stateDb = val
        case "log_dir": s.logDir = val
        case "max_syncs": s.maxSyncs = Int(val) ?? s.maxSyncs
        case "sync_finish_threshold_ms": s.syncFinishThresholdMs = Int(val) ?? s.syncFinishThresholdMs
        case "rsync_bwlimit_kbps": s.rsyncBwlimitKbps = Int(val) ?? s.rsyncBwlimitKbps
        case "ionice": s.ionice = val.uppercased() != "FALSE"
        case "max_lock_seconds": s.maxLockSeconds = Int(val) ?? s.maxLockSeconds
        case "cutover_window": s.cutoverWindow = val.isEmpty ? nil : val
        case "verify": s.verify = val
        case "db_strategy": s.dbStrategy = val
        case "mta_hosts": s.mtaHosts = splitList(val)
        case "metrics_textfile": s.metricsTextfile = val.isEmpty ? nil : val
        case "rsync_timeout": s.rsyncTimeout = Int(val) ?? s.rsyncTimeout
        case "db_timeout": s.dbTimeout = Int(val) ?? s.dbTimeout
        case "tls_ca": s.tlsCa = val.isEmpty ? nil : val
        case "shared_volumes":
            for item in splitList(val) {
                let kv = item.split(separator: ":", maxSplits: 1).map(String.init)
                if kv.count == 2, let k = Int(kv[0]), let v = Int(kv[1]) {
                    s.sharedVolumes[k] = v
                }
            }
        default: break
        }
    }
    try validateSettings(s, source: path)
    return s.expanded()
}

private extension Settings {
    func expanded() -> Settings { var c = self; c.expand(); return c }
}

func validateSettings(_ s: Settings, source: String?) throws {
    let wh = source.map { " (\($0))" } ?? ""
    if s.maxSyncs < 1 { throw ConfigError.invalid("max_syncs must be >= 1", wh.isEmpty ? nil : source) }
    if let w = s.cutoverWindow { _ = try parseWindow(w) }
}

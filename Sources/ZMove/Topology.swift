/// Discovery of servers, volumes, accounts and mailboxes.
/// Port of topology.py.
import Foundation

public func parseZmprovAttrs(_ text: String) -> [String: [String]] {
    var out: [String: [String]] = [:]
    var current: String? = nil
    for line in text.components(separatedBy: .newlines) {
        if line.hasPrefix("# ") {
            current = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            continue
        }
        guard let colon = line.firstIndex(of: ":") else { continue }
        let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        let val = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        if !key.isEmpty { out[key, default: []].append(val); current = key }
        _ = current
    }
    return out
}

public func firstAttr(_ attrs: [String: [String]], _ key: String,
                      default def: String? = nil) -> String? {
    attrs[key]?.first ?? def
}

public func isTrue(_ v: String?) -> Bool { (v ?? "").uppercased() == "TRUE" }

public struct ServerInfo: Sendable {
    public var name: String
    public var zimbraId: String
    public var version: String
    public var dbVersion: String
    public var indexVersion: String
    public var numGroups: Int
    public var blobDirServerId: Bool
    public var moveSkipBlobs: Bool
    public var moveSkipHsmBlobs: Bool
    public var moveSkipIndex: Bool
    public var lmtpPort: Int
    public var mailboxdStarted: Int?
    public var hasMailClient: Bool
    public var volumes: [Volume] = []
    public var currentMsg: Int = 0
    public var currentSecondary: Int? = nil
    public var currentIndex: Int = 0

    public init(name: String, zimbraId: String = "", version: String = "",
                dbVersion: String = "?", indexVersion: String = "?",
                numGroups: Int = 100, blobDirServerId: Bool = false,
                moveSkipBlobs: Bool = false, moveSkipHsmBlobs: Bool = false,
                moveSkipIndex: Bool = false, lmtpPort: Int = 7025,
                mailboxdStarted: Int? = nil, hasMailClient: Bool = false) {
        self.name = name; self.zimbraId = zimbraId; self.version = version
        self.dbVersion = dbVersion; self.indexVersion = indexVersion
        self.numGroups = numGroups; self.blobDirServerId = blobDirServerId
        self.moveSkipBlobs = moveSkipBlobs; self.moveSkipHsmBlobs = moveSkipHsmBlobs
        self.moveSkipIndex = moveSkipIndex; self.lmtpPort = lmtpPort
        self.mailboxdStarted = mailboxdStarted; self.hasMailClient = hasMailClient
    }

    public func volume(_ vid: Int) throws -> Volume {
        if let v = volumes.first(where: { $0.id == vid }) { return v }
        throw TopologyError.noSuchVolume(vid, name)
    }

    public var pathPrefix: String? { blobDirServerId ? zimbraId : nil }
}

public enum TopologyError: Error {
    case noSuchVolume(Int, String)
    case unknownAccount(String)
}


public struct AccountInfo: Sendable {
    public var name: String
    public var id: String
    public var mailHost: String
    public var mailTransport: String
    public var status: String
    public var aliases: [String]

    public init(name: String, id: String, mailHost: String = "",
                mailTransport: String = "", status: String = "active",
                aliases: [String] = []) {
        self.name = name; self.id = id; self.mailHost = mailHost
        self.mailTransport = mailTransport; self.status = status
        self.aliases = aliases
    }
}

public struct MailboxRow: Sendable {
    public var id: Int
    public var groupId: Int
    public var indexVolumeId: Int
    public var items: Int = 0
    public var size: Int = 0
}

public func serverInfo(host: Host, mysql: MySQL) throws -> ServerInfo {
    let attrs = parseZmprovAttrs(try host.out(
        "zmprov -l gs \(shellQuote(host.name)) zimbraId zimbraConfiguredServerIDForBlobDirEnabled " +
        "zimbraMailboxMoveSkipBlobs zimbraMailboxMoveSkipHsmBlobs zimbraMailboxMoveSkipSearchIndex " +
        "zimbraLmtpBindPort zimbraServiceEnabled"))
    let version = try host.out("zmcontrol -v").components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? ""
    let groups = Int(try host.out("zmlocalconfig -m nokey zimbra_mailbox_groups")) ?? 100
    let startedRaw = try host.out("pid=$(pgrep -u zimbra -f 'java.*mailboxd' | head -1); [ -n \"$pid\" ] && stat -c %Y /proc/$pid || true")
    var si = ServerInfo(
        name: host.name,
        zimbraId: firstAttr(attrs, "zimbraId", default: "") ?? "",
        version: version,
        dbVersion: mysql.configValue("db.version") ?? "?",
        indexVersion: mysql.configValue("index.version") ?? "?",
        numGroups: groups,
        blobDirServerId: isTrue(firstAttr(attrs, "zimbraConfiguredServerIDForBlobDirEnabled")),
        moveSkipBlobs: isTrue(firstAttr(attrs, "zimbraMailboxMoveSkipBlobs")),
        moveSkipHsmBlobs: isTrue(firstAttr(attrs, "zimbraMailboxMoveSkipHsmBlobs")),
        moveSkipIndex: isTrue(firstAttr(attrs, "zimbraMailboxMoveSkipSearchIndex")),
        lmtpPort: Int(firstAttr(attrs, "zimbraLmtpBindPort") ?? "") ?? 7025,
        mailboxdStarted: Int(startedRaw),
        hasMailClient: attrs["zimbraServiceEnabled"]?.contains("mailbox") ?? false)
    let hasStoreType = mysql.scalar(
        "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='zimbra' " +
        "AND table_name='volume' AND column_name='store_type'") == "1"
    let st = hasStoreType ? "store_type" : "1"
    for r in mysql.query("SELECT id, type, name, path, file_bits, file_group_bits, mailbox_bits, " +
                         "mailbox_group_bits, compress_blobs, \(st) FROM zimbra.volume") {
        guard r.count >= 10,
              let id = Int(r[0] ?? ""), let type = Int(r[1] ?? ""),
              let fb = Int(r[4] ?? ""), let fgb = Int(r[5] ?? ""),
              let mb = Int(r[6] ?? ""), let mgb = Int(r[7] ?? ""),
              let stv = Int(r[9] ?? "") else { continue }
        si.volumes.append(Volume(id: id, type: type, name: r[2] ?? "",
                                 path: r[3] ?? "", fileBits: fb, fileGroupBits: fgb,
                                 mailboxBits: mb, mailboxGroupBits: mgb,
                                 compressBlobs: r[8] == "1", storeType: stv))
    }
    let cv = mysql.query("SELECT message_volume_id, secondary_message_volume_id, index_volume_id " +
                         "FROM zimbra.current_volumes")
    if let row = cv.first, row.count >= 3 {
        if let m = Int(row[0] ?? "") { si.currentMsg = m }
        si.currentSecondary = (row[1] ?? "").isEmpty ? nil : Int(row[1] ?? "")
        if let i = Int(row[2] ?? "") { si.currentIndex = i }
    }
    return si
}

public func accountInfo(host: Host, account: String) throws -> AccountInfo {
    /// Look up an account. The returned name is the CANONICAL one (zmprov's '# name'
    /// header), even when an alias was given, so every later per-account command
    /// targets the real account.
    let raw = try host.out(
        "zmprov -l ga \(shellQuote(account)) zimbraId zimbraMailHost zimbraMailTransport " +
        "zimbraAccountStatus mail zimbraMailAlias zimbraMailDeliveryAddress")
    let attrs = parseZmprovAttrs(raw)
    guard let zid = firstAttr(attrs, "zimbraId"), !zid.isEmpty else {
        throw TopologyError.unknownAccount(account)
    }
    var name = account
    for line in raw.components(separatedBy: .newlines) where line.hasPrefix("# name ") {
        let canon = String(line.dropFirst("# name ".count)).trimmingCharacters(in: .whitespaces)
        if !canon.isEmpty { name = canon }
        break
    }
    var aliases = attrs["zimbraMailAlias"] ?? []
    aliases += (attrs["mail"] ?? []).filter { $0 != name }
    aliases += attrs["zimbraMailDeliveryAddress"] ?? []
    return AccountInfo(name: name, id: zid,
                       mailHost: firstAttr(attrs, "zimbraMailHost", default: "") ?? "",
                       mailTransport: firstAttr(attrs, "zimbraMailTransport", default: "") ?? "",
                       status: firstAttr(attrs, "zimbraAccountStatus", default: "active") ?? "active",
                       aliases: Array(Set(aliases)))
}

public func mailboxRow(mysql: MySQL, accountId: String,
                       withStats: Bool = true) -> MailboxRow? {
    let rows = mysql.query("SELECT id, group_id, index_volume_id FROM zimbra.mailbox " +
                           "WHERE account_id=\(q(accountId))")
    guard let r = rows.first, r.count >= 3,
          let id = Int(r[0] ?? ""), let gid = Int(r[1] ?? ""),
          let ivid = Int(r[2] ?? "") else { return nil }
    var mb = MailboxRow(id: id, groupId: gid, indexVolumeId: ivid)
    if withStats {
        let s = mysql.query("SELECT COUNT(*), COALESCE(SUM(size),0) FROM mboxgroup\(gid).mail_item " +
                            "WHERE mailbox_id=\(id)")
        if let sr = s.first, sr.count >= 2 {
            mb.items = Int(sr[0] ?? "") ?? 0
            mb.size = Int(sr[1] ?? "") ?? 0
        }
    }
    return mb
}

public func mailboxIdInUse(mysql: MySQL, mailboxId: Int) -> Bool {
    mysql.scalar("SELECT COUNT(*) FROM zimbra.mailbox WHERE id=\(mailboxId)") != "0"
}

public func memcachedServers(host: Host) throws -> [String] {
    let attrs = parseZmprovAttrs(try host.out("zmprov -l gcf zimbraMemcachedClientServerList"))
    var servers = attrs["zimbraMemcachedClientServerList"] ?? []
    if servers.isEmpty {
        servers = try host.out("zmprov -l gas memcached")
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            .map { $0.contains(":") ? $0 : "\($0):11211" }
    }
    var out: [String] = []
    for s in servers {
        for part in s.replacingOccurrences(of: ",", with: " ").split(separator: " ") {
            let p = String(part)
            out.append(p.contains(":") ? p : "\(p):11211")
        }
    }
    return out
}

public func mtaServers(host: Host) -> [String] {
    (try? host.out("zmprov -l gas mta"))?.components(separatedBy: .whitespaces)
        .filter { !$0.isEmpty } ?? []
}

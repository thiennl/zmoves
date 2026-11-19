/// Pure functions mirroring Zimbra's on-disk / DB layout.
/// Port of paths.py. References (Zimbra/zm-mailbox):
///   DbMailbox.calculateMailboxGroupId()
///   Volume.getMailboxDir() / getBlobDir()
///   FileBlobStore.getBlobPath()

public let typeMessage = 1
public let typeMessageSecondary = 2
public let typeIndex = 10
public let storeInternal = 1

public enum LayoutError: Error, Equatable {
    case invalidMailboxId(Int)
    case invalidGroupCount(Int)
    case unsafeIdentifier(String)
}

public func mailboxGroupId(_ mailboxId: Int, numGroups: Int) throws -> Int {
    guard mailboxId >= 1 else { throw LayoutError.invalidMailboxId(mailboxId) }
    guard numGroups >= 1 else { throw LayoutError.invalidGroupCount(numGroups) }
    return (mailboxId - 1) % numGroups + 1
}

public func groupDb(_ groupId: Int) -> String {
    "mboxgroup\(groupId)"
}

public struct Volume: Sendable {
    public var id: Int
    public var type: Int
    public var name: String
    public var path: String
    public var fileBits: Int
    public var fileGroupBits: Int
    public var mailboxBits: Int
    public var mailboxGroupBits: Int
    public var compressBlobs: Bool
    public var storeType: Int

    public init(id: Int, type: Int, name: String, path: String,
                fileBits: Int, fileGroupBits: Int, mailboxBits: Int,
                mailboxGroupBits: Int, compressBlobs: Bool = false,
                storeType: Int = storeInternal) {
        self.id = id; self.type = type; self.name = name; self.path = path
        self.fileBits = fileBits; self.fileGroupBits = fileGroupBits
        self.mailboxBits = mailboxBits; self.mailboxGroupBits = mailboxGroupBits
        self.compressBlobs = compressBlobs; self.storeType = storeType
    }

    public var isMessage: Bool { type == typeMessage || type == typeMessageSecondary }
    public var isIndex: Bool { type == typeIndex }

    /// Two volumes with the same layout key name files identically inside a mailbox dir.
    public func layoutKey() -> (Int, Int) { (fileBits, fileGroupBits) }

    /// Volume.getMailboxDir(mboxId, null): <root>/[serverId/]<hash>/<mboxId>
    public func mailboxDir(_ mailboxId: Int, serverIdPrefix: String? = nil) -> String {
        let mask = (1 << mailboxGroupBits) - 1
        let bucket = (mailboxId >> mailboxBits) & mask
        var root = path
        while root.hasSuffix("/") { root.removeLast() }
        if let prefix = serverIdPrefix { root += "/\(prefix)" }
        return "\(root)/\(bucket)/\(mailboxId)"
    }

    /// Path of a blob relative to mailbox dir: msg/<bucket>/<item>-<rev>.msg
    public func blobRelpath(itemId: Int, revision: Int) -> String {
        let mask = (1 << fileGroupBits) - 1
        let bucket = (itemId >> fileBits) & mask
        let name = revision >= 0 ? "\(itemId)-\(revision).msg" : "\(itemId).msg"
        return "msg/\(bucket)/\(name)"
    }
}

public enum VolumeMapError: Error, Equatable {
    case externalSourceVolume(Int, String)
    case externalDestinationVolume(Int, String)
    case destinationMissing(Int)
    case typeMismatch(src: Int, dst: Int)
    case layoutMismatch(src: Int, dst: String, srcBits: (Int, Int), dstBits: (Int, Int))

    public static func == (lhs: VolumeMapError, rhs: VolumeMapError) -> Bool {
        switch (lhs, rhs) {
        case (.externalSourceVolume(let a, _), .externalSourceVolume(let b, _)): return a == b
        default: return false
        }
    }
}

/// Map every source volume id to a destination volume id.
/// Primary message volumes -> dest current primary, secondary/HSM -> dest current
/// secondary (or primary if dest has none), index -> dest current index.
/// `explicit` overrides (e.g. shared storage where src vol 3 == dst vol 3).
public func mapVolumes(srcVols: [Volume], dstVols: [Volume],
                       dstCurrentMsg: Int, dstCurrentSecondary: Int?,
                       dstCurrentIndex: Int,
                       explicit: [Int: Int]? = nil) throws -> [Int: Int] {
    let byId = Dictionary(uniqueKeysWithValues: dstVols.map { ($0.id, $0) })
    var out: [Int: Int] = [:]
    for sv in srcVols {
        let isExplicit = explicit?[sv.id] != nil
        if sv.storeType != storeInternal && !isExplicit {
            throw VolumeMapError.externalSourceVolume(sv.id, sv.name)
        }
        let target: Int?
        if let explicit = explicit, let t = explicit[sv.id] {
            target = t
        } else if sv.type == typeMessage {
            target = dstCurrentMsg
        } else if sv.type == typeMessageSecondary {
            target = dstCurrentSecondary ?? dstCurrentMsg
        } else if sv.type == typeIndex {
            target = dstCurrentIndex
        } else {
            continue
        }
        guard let tid = target, let dv = byId[tid] else {
            throw VolumeMapError.destinationMissing(target ?? -1)
        }
        if dv.storeType != storeInternal && !isExplicit {
            throw VolumeMapError.externalDestinationVolume(dv.id, dv.name)
        }
        if sv.isIndex != dv.isIndex {
            throw VolumeMapError.typeMismatch(src: sv.id, dst: dv.id)
        }
        if sv.isMessage && sv.layoutKey() != dv.layoutKey()
            && !(isExplicit && (sv.storeType != storeInternal || dv.storeType != storeInternal)) {
            throw VolumeMapError.layoutMismatch(src: sv.id, dst: dv.name,
                                                srcBits: sv.layoutKey(), dstBits: dv.layoutKey())
        }
        out[sv.id] = dv.id
    }
    return out
}

/// SQL expression remapping a FileBlobStore locator (volume id as string).
public func locatorCaseSQL(column: String, mapping: [Int: Int]) -> String {
    let pairs = mapping.filter { $0.key != $0.value }.sorted { $0.key < $1.key }
    guard !pairs.isEmpty else { return column }
    let whens = pairs.map { "WHEN '\($0.key)' THEN '\($0.value)'" }.joined(separator: " ")
    return "(CASE \(column) \(whens) ELSE \(column) END)"
}

/// 'lmtp:mbx01.dom:7025' -> 'lmtp:mbx02.dom:<port>'.
///
/// `port` is the destination's zimbraLmtpBindPort: the source's LMTP port is not
/// necessarily the destination's. Only LMTP transports point at a mailbox server.
/// Anything else (smtp relay, hold, error, VIP) is returned unchanged so a move
/// never rewrites custom routing.
 public func replaceHostInTransport(_ transport: String, _ newHost: String,
                                    port: Int = 7025) -> String {
     if transport.isEmpty { return "lmtp:\(newHost):\(port)" }
     let parts = transport.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
     if parts[0].lowercased() != "lmtp" { return transport }
     return "\(parts[0]):\(newHost):\(port)"
 }

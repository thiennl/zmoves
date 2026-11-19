/// Blob / Lucene index transfer (rsync) with NE-compatible convergence loop.
/// Port of blobs.py.
import Foundation

public struct DirPlan: Sendable {
    /// One destination mailbox dir fed by one or more source mailbox dirs.
    public var kind: String          // "msg" | "index"
    public var dstVolume: Int
    public var dstDir: String
    public var srcDirs: [String]
    public var srcVolumes: [Int]
    public var shared: Bool          // src paths visible on dst host -> local copy
    public var external: Bool        // object/S3-style volume: DB locator remap only

    public init(kind: String, dstVolume: Int, dstDir: String,
                srcDirs: [String] = [], srcVolumes: [Int] = [],
                shared: Bool = false, external: Bool = false) {
        self.kind = kind; self.dstVolume = dstVolume; self.dstDir = dstDir
        self.srcDirs = srcDirs; self.srcVolumes = srcVolumes
        self.shared = shared; self.external = external
    }
}

public struct SyncStats: Sendable {
    public var seconds: Double = 0
    public var files: Int = 0
    public var bytes: Int = 0

    public mutating func add(_ o: SyncStats) {
        seconds += o.seconds; files += o.files; bytes += o.bytes
    }
}

private let filesRE = try! NSRegularExpression(
    pattern: #"Number of regular files transferred:\s*([\d,]+)"#)
private let bytesRE = try! NSRegularExpression(
    pattern: #"Total transferred file size:\s*([\d,]+)"#)

public func parseStats(_ out: String) -> (Int, Int) {
    func num(_ re: NSRegularExpression) -> Int {
        let r = NSRange(out.startIndex..., in: out)
        guard let m = re.firstMatch(in: out, range: r),
              let gr = Range(m.range(at: 1), in: out) else { return 0 }
        return Int(out[gr].replacingOccurrences(of: ",", with: "")) ?? 0
    }
    return (num(filesRE), num(bytesRE))
}

public enum BlobError: Error {
    case unexpectedPath(String)
}

public final class BlobSync {
    public let settings: Settings
    public let src: Host
    public let dst: Host

    public init(_ s: Settings, src: Host, dst: Host) {
        self.settings = s; self.src = src; self.dst = dst
    }

    public func existingSrcDirs(_ plan: DirPlan) throws -> [String] {
        let host = plan.shared ? dst : src
        var keep: [String] = []
        for d in plan.srcDirs {
            let r = try host.run("test -d '\(d)'", check: false, mutating: false)
            if r.rc == 0 { keep.append(d) }
        }
        return keep
    }

    private func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func cmd(plan: DirPlan, srcs: [String], final: Bool) -> (Host, String) {
        // online passes yield to user I/O; the final pass runs while users are locked
        let nice = (settings.ionice && !final) ? "ionice -c2 -n7 nice -n 10 " : ""
        var opts = ["-a", "--numeric-ids", "--stats", "--partial", "--delete"]
        // Multiple source dirs (several old primary volumes -> one dest volume) are merged;
        // --delete then removes only files absent from *all* sources.
        opts.append("-H")
        if final {
            // bit-rot safety: the last pass compares content, not just size/mtime
            opts.append("--checksum")
        }
        if settings.rsyncBwlimitKbps > 0 && !final {
            opts.append("--bwlimit=\(settings.rsyncBwlimitKbps)")
        }
        let srcsQ = srcs.map { quote($0.hasSuffix("/") ? $0 : $0 + "/") }.joined(separator: " ")
        let dq = quote(plan.dstDir.hasSuffix("/") ? plan.dstDir : plan.dstDir + "/")
        if plan.shared {
            // shared storage: hard-link unchanged files from the old dir, copy nothing over the wire
            let link = srcs.map { "--link-dest=\(quote($0.hasSuffix("/") ? String($0.dropLast()) : $0))" }.joined(separator: " ")
            let cmd = "mkdir -p \(quote(plan.dstDir)) && \(nice)\(settings.rsyncBin) \(opts.joined(separator: " ")) \(link) \(srcsQ) \(dq)"
            return (dst, cmd)
        }
        let e = "ssh -p \(settings.nodeSshPort) \(settings.nodeSshOptions)"
        let rpath = "mkdir -p \(quote(plan.dstDir)) && \(settings.rsyncBin)"
        let cmd = "\(nice)\(settings.rsyncBin) \(opts.joined(separator: " ")) -e \(quote(e)) " +
            "--rsync-path=\(quote(rpath)) \(srcsQ) \(settings.nodeSshUser)@\(dst.name):\(dq)"
        return (src, cmd)
    }

    public func syncOnce(plans: [DirPlan], final: Bool = false,
                         timeout: Double? = nil) throws -> SyncStats {
        var total = SyncStats()
        for p in plans {
            if p.external {
                // external/object storage: no filesystem tree to copy, the DB
                // locator remap keeps pointing at the shared store
                continue
            }
            let srcs = try existingSrcDirs(p)
            if srcs.isEmpty {
                if final {
                    // stray content from an older attempt must not survive under the new id
                    try removeDirs(dst, [p.dstDir])
                }
                continue
            }
            let (host, c) = cmd(plan: p, srcs: srcs, final: final)
            let r = try host.run(c, timeout: timeout)
            let (f, b) = parseStats(r.out)
            total.add(SyncStats(seconds: r.seconds, files: f, bytes: b))
        }
        return total
    }

    /// NE semantics (MoveMailboxRequest doc): repeat until a pass takes <= syncFinishThreshold
    /// or maxSyncs passes ran. Improvement: also stop early when a pass transferred nothing.
    public func converge(plans: [DirPlan], maxSyncs: Int, thresholdMs: Int,
                         onPass: ((Int, SyncStats) -> Void)? = nil,
                         timeout: Double? = nil) throws -> [SyncStats] {
        var passes: [SyncStats] = []
        for i in 1...max(1, maxSyncs) {
            let st = try syncOnce(plans: plans, timeout: timeout)
            passes.append(st)
            onPass?(i, st)
            if st.seconds * 1000 <= Double(thresholdMs) || st.files == 0 { break }
        }
        return passes
    }

    public func fsFree(host: Host, path: String) -> (mount: String, free: Int)? {
        guard let out = try? host.out("df -PB1 \(quote(path)) | awk 'NR==2 {print $6\" \"$4}'"),
              let idx = out.lastIndex(of: " ") else { return nil }
        let mount = String(out[..<idx])
        guard let n = Int(out[out.index(after: idx)...]) else { return nil }
        return (mount, n)
    }

    public func freeBytes(host: Host, path: String) throws -> Int? {
        try fsFree(host: host, path: path)?.1
    }

     public func inventory(host: Host, dirs: [String]) throws -> (Int, Int) {
         /// (file count, apparent bytes) with merged-source dedup: a relative path
         /// present in more than one source counts once, as rsync --delete merges them.
         if dirs.isEmpty { return (0, 0) }
         let dq = dirs.map { quote($0) }.joined(separator: " ")
         let out = try host.out("find \(dq) -type f -printf '%P\\t%s\\n' 2>/dev/null | " +
             "awk -F'\\t' '!seen[$1]++ {n++; s+=$2} END {printf \"%d %d\", n, s}'")
         let parts = out.split(separator: " ").map(String.init)
         if parts.count == 2, let n = Int(parts[0]), let s = Int(parts[1]) {
             return (n, s)
         }
         return (0, 0)
     }

    public func du(host: Host, dirs: [String]) throws -> Int {
        try inventory(host: host, dirs: dirs).1
    }

    public func removeDirs(_ host: Host, _ dirs: [String]) throws {
        for d in dirs {
            // defensive: only remove paths that look like <root>/<bucket>/<mboxid>
            let range = NSRange(d.startIndex..., in: d)
            guard try! NSRegularExpression(pattern: "/[0-9]+/[0-9]+/?$")
                    .firstMatch(in: d, range: range) != nil else {
                throw BlobError.unexpectedPath(d)
            }
            try host.run("rm -rf --one-file-system \(quote(d))")
        }
    }
}

/// Cache coherence after cutover (NE: skipMemcachePurge controls the same step).
///
/// Every function here is scoped to ONE account: nothing flushes server-wide
/// caches or the whole MTA queue, and every remote call has a timeout so an
/// unreachable cache/MTA cannot leave the account stuck in maintenance.
import Foundation

// MemcachedKeyPrefix.java: keys keyed only by accountId (no checkpoint validation on load).
// FoldersTagsCache is read in Mailbox.loadFoldersAndTags() without comparing change ids.
public let accountKeys = ["zmFldrsTags:{id}", "zmCalsList:{id}"]

public let cmdTimeout: Double = 120
public let memcachedTimeout: Double = 5

@discardableResult
private func runBestEffort(host: Host, cmd: String, what: String,
                           timeout: Double = cmdTimeout) -> CommandResult? {
    do {
        let r = try host.run(cmd, check: false, timeout: timeout)
        if r.rc != 0 {
            fputs("[zmove.caches] [\(host.name)] \(what) failed rc=\(r.rc): \(r.err.suffix(500))\n", stderr)
        }
        return r
    } catch {
        fputs("[zmove.caches] [\(host.name)] \(what) timed out after \(timeout)s\n", stderr)
        return nil
    }
}

/// In-JVM account/LDAP caches on ALL mailstores (zmprov fc -a).
public func flushAccountCache(host: Host, account: String) {
    _ = runBestEffort(host: host,
                      cmd: "zmprov flushCache -a account \(shellQuote(account))",
                      what: "flushCache")
}

/// nginx route cache in memcached (ProxyPurgeUtil: route:proto=...;user=...).
/// Routes are keyed by the login name, and users may log in with an alias, so
/// purge the canonical name and every alias: all belong to the account being moved.
public func purgeProxyRoutes(host: Host, account: String, aliases: [String] = []) {
    var seen = Set<String>()
    for name in [account] + aliases where !seen.contains(name) {
        seen.insert(name)
        _ = runBestEffort(host: host,
                          cmd: "zmproxypurge -a \(shellQuote(name))",
                          what: "zmproxypurge \(name)")
    }
}

/// Delete account-scoped mailbox caches on every memcached server (keys are distributed by
/// consistent hashing, so we simply ask all of them). Bounded per-server timeout.
@discardableResult
public func deleteMemcachedKeys(host: Host, accountId: String) throws -> Int {
    let servers: [String]
    do {
        servers = try memcachedServers(host: host)
    } catch {
        fputs("[zmove.caches] [\(host.name)] memcached discovery failed: \(error)\n", stderr)
        return 0
    }
    var deleted = 0
    for hp in servers {
        guard let colon = hp.lastIndex(of: ":") else { continue }
        let h = String(hp[..<colon])
        let p = Int(hp[hp.index(after: colon)...]) ?? 11211
        for tmpl in accountKeys {
            let key = tmpl.replacingOccurrences(of: "{id}", with: accountId)
             let cmd = "exec 3<>/dev/tcp/\(h)/\(p) && printf 'delete %s\\r\\n' \(shellQuote(key)) >&3 && " +
                 "head -1 <&3; exec 3>&-"
             let r = runBestEffort(host: host,
                                   cmd: "timeout \(Int(memcachedTimeout)) bash -c \(shellQuote(cmd))",
                                  what: "memcached delete on \(hp)",
                                  timeout: memcachedTimeout + 5)
            if let out = r?.out, out.contains("DELETED") { deleted += 1 }
        }
    }
    return deleted
}

/// Queue ids of DEFERRED messages with at least one recipient of this account
/// (`postqueue -j` emits one JSON object per line).
public func queueIds(for postqueueJSON: String, recipients: [String]) -> [String] {
    let want = Set(recipients.filter { !$0.isEmpty }.map { $0.lowercased() })
    var ids: [String] = []
    for line in postqueueJSON.components(separatedBy: .newlines) {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty,
              let data = t.data(using: .utf8),
              let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        guard (m["queue_name"] as? String) == "deferred" else { continue }
        let rcpts = ((m["recipients"] as? [[String: Any]]) ?? []).compactMap {
            ($0["address"] as? String)?.lowercased()
        }
        if !Set(rcpts).isDisjoint(with: want), let qid = m["queue_id"] as? String {
            ids.append(qid)
        }
    }
    return ids
}

/// Deliver mail deferred (450 4.2.1) during the lock for THIS account only.
///
/// Never `postqueue -f`: that would re-try every deferred message of every user on the MTA
/// at once. Only messages addressed to the account (canonical name or alias) are rescheduled
/// with `postqueue -i`; the rest of the queue keeps its normal retry schedule.
@discardableResult
public func flushMtaQueues(hosts: [Host], account: String,
                           zimbraHome: String = "/opt/zimbra",
                           aliases: [String] = []) -> Int {
    let pq = shellQuote(zimbraHome.hasSuffix("/") ? String(zimbraHome.dropLast()) + "/common/sbin/postqueue" : zimbraHome + "/common/sbin/postqueue")
    let rcpts = [account] + aliases
    var total = 0
    for h in hosts {
        guard let r = runBestEffort(host: h, cmd: "\(pq) -j", what: "postqueue -j") else { continue }
        if r.rc != 0 {
            fputs("[zmove.caches] [\(h.name)] cannot list the queue (postqueue -j needs Postfix >= 3.1); " +
                "mail for \(account) will be retried on the normal schedule\n", stderr)
            continue
        }
        let ids = queueIds(for: r.out, recipients: rcpts)
        var i = 0
        while i < ids.count {
            let chunk = Array(ids[i..<min(i + 200, ids.count)])
            _ = runBestEffort(host: h,
                              cmd: chunk.map { "\(pq) -i \(shellQuote($0))" }.joined(separator: "; "),
                              what: "postqueue -i")
            i += chunk.count
        }
        total += ids.count
        if !ids.isEmpty {
            print("[\(h.name)] rescheduled \(ids.count) deferred message(s) for \(account)")
        }
    }
    return total
}

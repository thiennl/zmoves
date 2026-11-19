/// Fleet-scale moves: plan file, global parallelism, per-server limits, cutover throttling.
/// Port of batch.py.
import Foundation

public struct BatchItem: Sendable {
    public var account: String
    public var src: String
    public var dst: String
    public init(account: String, src: String, dst: String) {
        self.account = account; self.src = src; self.dst = dst
    }
}

public func readPlan(_ path: String) throws -> [BatchItem] {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    var items: [BatchItem] = []
    for raw in text.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count < 3 || parts[0].isEmpty {
            throw BatchError.badPlan("bad plan line: \(line)")
        }
        if parts[0].lowercased() == "account" { continue }
        items.append(BatchItem(account: parts[0], src: parts[1], dst: parts[2]))
    }
    return items
}

public enum BatchError: Error {
    case badPlan(String)
}

private final class Semaphores: @unchecked Sendable {
    private var lock = NSLock()
    private var table: [String: DispatchSemaphore] = [:]
    private let perServer: Int
    init(perServer: Int) { self.perServer = perServer }
    func get(_ server: String) -> DispatchSemaphore {
        lock.lock(); defer { lock.unlock() }
        if let s = table[server] { return s }
        let s = DispatchSemaphore(value: max(1, perServer))
        table[server] = s
        return s
    }
}

private final class ResultsBox: @unchecked Sendable {
    var items: [(BatchItem, String?, String?)] = []
    let lock = NSLock()
    func append(_ r: (BatchItem, String?, String?)) {
        lock.lock(); defer { lock.unlock() }
        items.append(r)
    }
}

public func confirmContinue(_ msg: String) -> Bool {
    if isatty(STDIN_FILENO) == 0 { return false }
    print(msg, terminator: "")
    guard let line = readLine(strippingNewline: true) else { return false }
    let v = line.trimmingCharacters(in: .whitespaces).lowercased()
    return v == "y" || v == "yes"
}

public final class Batch {
    public let settings: Settings
    public let parallel: Int
    public let perServer: Int
    public let maxCutovers: Int
    public let dryRun: Bool
     private let cutovers: DispatchSemaphore
     private let sems: Semaphores
     /// Test hooks (monkeypatch equivalents): consulted first when set.
     internal var oneHook: ((BatchItem, [String: Any]) -> (BatchItem, String?, String?))? = nil
     internal var askContinue: ((String) -> Bool) = confirmContinue
 
     public init(settings: Settings, parallel: Int = 4, perServer: Int = 2,
                 maxCutovers: Int = 2, dryRun: Bool = false) {
         self.settings = settings
         self.parallel = max(1, parallel)
         self.perServer = perServer
         self.maxCutovers = max(1, maxCutovers)
         self.dryRun = dryRun
         self.cutovers = DispatchSemaphore(value: max(1, maxCutovers))
         self.sems = Semaphores(perServer: perServer)
     }
 
     internal func one(_ it: BatchItem, options: [String: Any]) -> (BatchItem, String?, String?) {
         if let h = oneHook { return h(it, options) }
        if it.src == it.dst {
            return (it, nil, "MoveError: source and destination are the same server")
        }
        let sa = sems.get(it.src), sb = sems.get(it.dst)
        if sa === sb {
            sa.wait(); defer { sa.signal() }
            return runOne(it, options: options)
        }
        // fixed order by identity to avoid deadlock
        let ai = UInt(bitPattern: Unmanaged.passUnretained(sa).toOpaque())
        let bi = UInt(bitPattern: Unmanaged.passUnretained(sb).toOpaque())
        let first = ai < bi ? sa : sb
        let second: DispatchSemaphore = (first === sa) ? sb : sa
        first.wait(); defer { first.signal() }
        second.wait(); defer { second.signal() }
        return runOne(it, options: options)
    }

    private func runOne(_ it: BatchItem, options: [String: Any]) -> (BatchItem, String?, String?) {
        do {
            let st = try State(path: settings.stateDb)
            let eng = Engine(settings: settings, state: st, dryRun: dryRun,
                             progress: { zlog($0) })
            eng.lockSemaphore = cutovers
            var job = try eng.newJob(account: it.account, src: it.src, dst: it.dst, options: options)
            _ = try eng.run(&job)
            return (it, job.id, nil)
        } catch {
            return (it, nil, "\(type(of: error)): \(error)")
        }
    }

    private func runAll(_ items: [BatchItem],
                        options: [String: Any]) -> [(BatchItem, String?, String?)] {
        let box = ResultsBox()
        let group = DispatchGroup()
        let queue = DispatchQueue.global()
        let gate = DispatchSemaphore(value: parallel)
        for it in items {
            gate.wait()
            queue.async(group: group) { [self] in
                defer { gate.signal() }
                let r = self.one(it, options: options)
                box.append(r)
                if let e = r.2 {
                    zlog("FAIL \(it.account) \(it.src)->\(it.dst): \(e)")
                } else {
                    zlog("OK   \(it.account) \(it.src)->\(it.dst) job=\(r.1 ?? "?")")
                }
            }
        }
        group.wait()
        return box.items
    }

    @discardableResult
    public func run(_ items: [BatchItem], options: [String: Any],
                    canary: Int = 0) -> [(BatchItem, String?, String?)] {
        if canary <= 0 || canary >= items.count { return runAll(items, options: options) }
        let first = Array(items.prefix(canary))
        let rest = Array(items.dropFirst(canary))
        var results = runAll(first, options: options)
        if results.contains(where: { $0.2 != nil }) {
            zlog("canary: failures in first \(first.count); stopping before remaining \(rest.count)")
            return results
        }
         if !askContinue("canary ok (\(first.count) moved); continue with remaining \(rest.count)? [y/N] ") {
            zlog("canary paused by operator/non-TTY; \(rest.count) remaining skipped")
            return results
        }
        return results + runAll(rest, options: options)
    }
}

/// Small shared helpers.
import Foundation

/// POSIX shell single-quote escaping (mirrors Python shlex.quote).
public func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

public func zlog(_ msg: String) {
    fputs("[zmove] \(msg)\n", stderr)
}

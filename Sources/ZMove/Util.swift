/// Small shared helpers.
import Foundation

 /// POSIX shell quoting (mirrors Python shlex.quote: bare when every byte is
 /// [A-Za-z0-9@%_+=:,./-], single-quoted otherwise).
 public func shellQuote(_ s: String) -> String {
     let safe: Set<UInt8> = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@%_+=:,./-".utf8)
     if !s.isEmpty && s.utf8.allSatisfy({ safe.contains($0) }) { return s }
     return "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
 }

public func zlog(_ msg: String) {
    fputs("[zmove] \(msg)\n", stderr)
}

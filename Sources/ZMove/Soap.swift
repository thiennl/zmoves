/// Minimal Zimbra admin SOAP (JSON) client.
/// Port of soap.py. Requests are POSTed with curl *on the target mailstore
/// itself* to https://localhost:7071, so the control node does not need
/// firewall access to 7071 and secrets travel only on stdin.
import Foundation

public struct SoapFault: Error {
    public var code: String
    public var reason: String
    public init(code: String, reason: String) {
        self.code = code; self.reason = reason
    }
}

public final class AdminSoap {
    public let host: Host
    public let port: Int
    public let user: String?
    public let password: String?
    public let verifyTLS: Bool
    public let tlsCA: String?
    private var tokenValue: String?

    public init(host: Host, port: Int = 7071, user: String? = nil,
                password: String? = nil, verifyTLS: Bool = false,
                tlsCA: String? = nil) {
        self.host = host; self.port = port; self.user = user
        self.password = password; self.verifyTLS = verifyTLS; self.tlsCA = tlsCA
    }

    private func curlBase() -> String {
        let verify: String
        if verifyTLS {
            verify = tlsCA.map { " --cacert '\($0)'" } ?? ""
        } else {
            verify = " -k"
        }
        return "curl -sS --max-time 120\(verify) -H 'Content-Type: application/json' " +
            "--data-binary @- https://localhost:\(port)/service/admin/soap/"
    }

    private func post(_ body: [String: Any], token: String?,
                      mutating: Bool) throws -> [String: Any] {
        var context: [String: Any] = ["_jsns": "urn:zimbra"]
        if let t = token { context["authToken"] = ["_content": t] }
        let header: [String: Any] = ["context": context]
        let env: [String: Any] = ["Header": header, "Body": body]
        let data = try JSONSerialization.data(withJSONObject: env, options: [])
        guard let json = String(data: data, encoding: .utf8) else {
            throw SoapFault(code: "zmove.BAD_REQUEST", reason: "cannot encode SOAP body")
        }
        let res = try host.run(curlBase(), input: json, mutating: mutating)
        if host.dryRun && mutating { return [:] }
        guard let rdata = res.out.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: rdata) as? [String: Any],
              let b = parsed["Body"] as? [String: Any] else {
            throw SoapFault(code: "zmove.BAD_RESPONSE",
                            reason: "\(host.name): \(res.out.prefix(300))")
        }
        if let fault = b["Fault"] as? [String: Any] {
            let detail = (fault["Detail"] as? [String: Any])?["Error"] as? [String: Any]
            let code = detail?["Code"] as? String ?? "?"
            let reason = (fault["Reason"] as? [String: Any])?["Text"] as? String ?? "?"
            throw SoapFault(code: code, reason: reason)
        }
        return b
    }

    @discardableResult
    public func token() throws -> String {
        if let t = tokenValue { return t }
        if host.dryRun { return "dry-run" }
        let user = self.user ?? (try? host.out("zmlocalconfig -m nokey zimbra_ldap_user")) ?? "zimbra"
        let pw: String
        if let p = password {
            pw = p
        } else {
            pw = (try? host.out("zmlocalconfig -s -m nokey zimbra_ldap_password")) ?? ""
        }
        let b = try post(["AuthRequest": ["_jsns": "urn:zimbraAdmin",
                                          "name": user, "password": pw]],
                         token: nil, mutating: false)
        guard let resp = b["AuthResponse"] as? [String: Any] else {
            throw SoapFault(code: "zmove.AUTH_FAILED", reason: "no AuthResponse")
        }
        let tok = resp["authToken"]
        let t: String
        if let arr = tok as? [[String: Any]], let first = arr.first,
           let c = first["_content"] as? String {
            t = c
        } else if let dict = tok as? [String: Any],
                  let c = dict["_content"] as? String {
            t = c
        } else {
            throw SoapFault(code: "zmove.AUTH_FAILED", reason: "no authToken")
        }
        tokenValue = t
        return t
    }

    public func setToken(_ t: String) { tokenValue = t }

    @discardableResult
    public func call(_ name: String, payload: [String: Any],
                     mutating: Bool = true) throws -> [String: Any] {
        var req: [String: Any] = ["_jsns": "urn:zimbraAdmin"]
        payload.forEach { req[$0.key] = $0.value }
        let b = try post([name: req], token: try token(), mutating: mutating)
        return b[name.replacingOccurrences(of: "Request", with: "Response")] as? [String: Any] ?? [:]
    }

    // -- specific requests -------------------------------------------------

    /// LockoutMailboxRequest (OSE: service/admin/LockoutMailbox.java). op = start|end.
    public func lockout(account: String, op: String) throws {
        try call("LockoutMailboxRequest", payload:
                 ["op": op, "account": ["by": "name", "_content": account]])
    }

    /// Best-effort QueryMailboxMoveRequest (NE only). Returns the move list,
    /// or nil when the server does not support the request (FOSS) or rejects
    /// the wire format. Request-level faults are swallowed on purpose.
    public func queryMoves(_ account: String? = nil) throws -> [[String: Any]]? {
        var payload: [String: Any] = [:]
        if let a = account { payload["account"] = ["by": "name", "_content": a] }
        let b: [String: Any]
        do {
            b = try call("QueryMailboxMoveRequest", payload: payload, mutating: false)
        } catch {
            return nil
        }
        if let arr = b["move"] as? [[String: Any]] { return arr }
        if let one = b["move"] as? [String: Any] { return [one] }
        return nil
    }

    /// MoveMailboxRequest (NE). Must be sent to the *destination* server;
    /// src/dest are safety checks (src must equal the account's current
    /// mailHost, dest must be this server). Mirrors MboxMoveUtil.move().
    @discardableResult
    public func moveMailbox(name: String, src: String, dest: String,
                            sync: Bool = false, skipRemoteLockout: Bool = false,
                            ngMigration: Bool = false) throws -> [String: Any] {
        try call("MoveMailboxRequest", payload: ["account": [
            "name": name, "src": src, "dest": dest,
            "sync": sync, "skipRemoteLockout": skipRemoteLockout, "ngMigration": ngMigration,
        ] as [String: Any]], mutating: true)
    }

    /// RegisterMailboxMoveOut on the source (ALREADY_BEING_MOVED_OUT aborts;
    /// absent handler (FOSS) is signalled via UNKNOWN_DOCUMENT).
    public func registerMoveOut(account: String, dest: String) throws {
        try call("RegisterMailboxMoveOutRequest", payload:
                 ["account": ["name": account, "target": dest]])
    }

    public func unregisterMoveOut(account: String, dest: String) throws {
        try call("UnregisterMailboxMoveOutRequest", payload:
                 ["account": ["name": account, "target": dest]])
    }

    /// The full JSON envelope, exposed for wire-format tests.
    public static func envelope(body: [String: Any],
                               token: String?) throws -> String {
        var header: [String: Any] = ["context": ["_jsns": "urn:zimbra"]]
        if let t = token {
            header = ["context": ["_jsns": "urn:zimbra",
                                  "authToken": ["_content": t]]]
        }
        let env: [String: Any] = ["Header": header, "Body": body]
        let data = try JSONSerialization.data(withJSONObject: env, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? ""
    }
}

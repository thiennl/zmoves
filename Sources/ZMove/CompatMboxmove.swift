/// Faithful port of zmmboxmove (MboxMoveUtil + MoveMailboxRequest).
/// Sends the NE MoveMailbox request to the *destination* server; the server
/// performs the move. This is a thin client over admin SOAP.
///
/// Differences from the Java original (all deliberate):
/// - No license gate: this port targets FOSS servers, which have no license
///   concept. Enforcement is left to the destination server; a client-side
///   BACKUP_ENABLED check would wrongly fail closed, so it is omitted.
/// - --authtoken/--authtokenfile accept a raw token string or a JSON file
///   carrying it under authtoken/authToken/token/id. Java additionally
///   supports interactive login, which this port does not implement.
/// - -s/--server is accepted but unconditionally overridden by --to, exactly
///   like MboxMoveUtil.main calling setServer(destHost).
///
/// NE message catalog (kept verbatim):
/// - "specified destHost does not correspond to a valid server hostname: X"
/// - "specified targetHost does not correspond to a valid mailclient server
///   with service webapp enabled: X"
/// - "WARNING: --force option specified. ..." (stdout)
/// - "Mailbox move started" / "Mailbox move completed successfully" (stdout)
/// - "Error occurred: ..." (stderr), exit 1; usage errors exit 1 (not 2).
import Foundation

public let compatUsage = "zmmboxmove -a <email> --from <src> --to <dest> [--sync]"
public let compatTrailer = "Move the account's mailbox from source server to destination server."
public let compatForceWarning =
    "WARNING: --force option specified. Not all data may be copied from the " +
    "source to destination mailbox. The source mailbox should be manually " +
    "inspected and any remaining data must be migrated manually."
public let compatLicenseError = "License is not valid or feature BackupEnabled is disabled"

public func readAuthtoken(value: String?, path: String?) throws -> String? {
    let raw: String
    if let v = value {
        raw = v
    } else if let p = path {
        raw = try String(contentsOfFile: (p as NSString).expandingTildeInPath,
                         encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
        return nil
    }
    if let data = raw.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        for k in ["authtoken", "authToken", "token", "id", "auth_token"] {
            if let s = obj[k] as? String { return s }
        }
    }
    return raw
}

public func checkCompatDest(host: Host, dst: String) throws {
    let out: String
    do {
        out = try host.out("zmprov -l gs \(shellQuote(dst)) zimbraId zimbraServiceEnabled")
    } catch {
        throw CompatError.invalidDest("specified destHost does not correspond to a valid server " +
                                      "hostname: \(dst) (\(error))")
    }
    let attrs = parseZmprovAttrs(out)
    guard let zid = firstAttr(attrs, "zimbraId"), !zid.isEmpty else {
        throw CompatError.invalidDest("specified destHost does not correspond to a valid server " +
                                      "hostname: \(dst)")
    }
    if !(attrs["zimbraServiceEnabled"] ?? []).contains("mailbox") {
        throw CompatError.invalidDest("specified targetHost does not correspond to a valid mailclient " +
                                      "server with service webapp enabled: \(dst)")
    }
}

public enum CompatError: Error {
    case invalidDest(String)
 }
 
 /// The stderr message for a MoveMailbox SOAP fault (pure: unit-tested).
 public func compatFaultMessage(_ e: SoapFault) -> String {
     var msg = "Error occurred: \(e.code): \(e.reason)"
     if e.code.hasSuffix("UNKNOWN_DOCUMENT") || e.code.hasSuffix("UNKNOWN_SERVICE") {
         msg += "\n(hint: the destination does not implement MoveMailbox " +
                "(FOSS server?). Use `zmove move` or `zmove ne-move` instead, " +
                "which perform the move without NE server code)"
     }
     return msg
 }

 @discardableResult
 public func runMboxMove(settings: Settings, account: String, src: String, dst: String,
                         sync: Bool = false, force: Bool = false,
                         ngMigration: Bool = false,
                         authtoken: String? = nil,
                         authtokenFile: String? = nil,
                         hostFactory: ((String) -> Host)? = nil,
                         soapFactory: ((Host) -> AdminSoap)? = nil) -> Int32 {
     do {
         let host = hostFactory?(dst) ?? Host(name: dst, settings: settings)
         try checkCompatDest(host: host, dst: dst)
         let soap = soapFactory?(host) ?? AdminSoap(host: host, port: settings.adminPort,
                              user: settings.adminUser, password: settings.adminPassword,
                              verifyTLS: settings.verifyTLS, tlsCA: settings.tlsCa)
        if let tok = try readAuthtoken(value: authtoken, path: authtokenFile) {
            soap.setToken(tok)
        } else {
            _ = try soap.token()
        }
        if force { print(compatForceWarning); fflush(stdout) }
        _ = try soap.moveMailbox(name: account, src: src, dest: dst, sync: sync,
                                 skipRemoteLockout: force, ngMigration: ngMigration)
     } catch let e as SoapFault {
         fputs(compatFaultMessage(e) + "\n", stderr)
         return 1
     } catch {
         fputs("Error occurred: \(error)\n", stderr)
         return 1
     }
    if sync {
        print("Mailbox move completed successfully"); fflush(stdout)
    } else {
        print("Mailbox move started"); fflush(stdout)
    }
    return 0
}


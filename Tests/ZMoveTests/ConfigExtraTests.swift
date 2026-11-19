/// Port of the config half of tests/test_pure.py: key parsing, shared
/// volumes, verify_tls truthiness, cutover window, invalid values rejected.
import Foundation
import Testing
@testable import ZMove

private func writeConf(_ body: String) throws -> String {
    let p = FileManager.default.temporaryDirectory
        .appendingPathComponent("zmove-test-\(UUID().uuidString).conf").path
    try body.write(toFile: p, atomically: true, encoding: .utf8)
    return p
}

@Suite("config-extra")
struct ConfigExtraTests {
    @Test func loadKeyValues() throws {
        let s = try loadConfig(path: try writeConf(
            "[zmove]\nmax_syncs = 3\nshared_volumes = 1:2, 3:3\nverify_tls = yes\n" +
            "cutover_window = 22:00-02:00\n"))
        #expect(s.maxSyncs == 3 && s.sharedVolumes == [1: 2, 3: 3] && s.verifyTLS == true)
        #expect(s.cutoverWindow == "22:00-02:00")
    }

    @Test func invalidVerifyRejected() throws {
        let p = try writeConf("[zmove]\nverify = maybe\n")
        #expect(throws: (any Error).self) { try loadConfig(path: p) }
    }

    @Test func invalidStrategyAndSyncsRejected() throws {
        #expect(throws: (any Error).self) {
            try loadConfig(path: try writeConf("[zmove]\ndb_strategy = sometimes\n"))
        }
        #expect(throws: (any Error).self) {
            try loadConfig(path: try writeConf("[zmove]\nmax_syncs = 0\n"))
        }
    }

    @Test func boolVariants() throws {
        let s = try loadConfig(path: try writeConf("[zmove]\nrun_as_zimbra = TRUE\nionice = no\n"))
        #expect(s.runAsZimbra == true && s.ionice == false)
    }
}

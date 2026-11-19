/// Second half of tests/test_paths.py: full map_volumes matrix, group/dir
/// edge cases, exact locator SQL, non-LMTP transports. Pure, no I/O.
import Testing
@testable import ZMove

private func xvol(_ id: Int, type: Int = 1, fb: Int = 8, fgb: Int = 8,
                  st: Int = 1) -> Volume {
    Volume(id: id, type: type, name: "v\(id)", path: "/store/\(id)",
           fileBits: fb, fileGroupBits: fgb, mailboxBits: 12,
           mailboxGroupBits: 8, storeType: st)
}

private func xdst() -> [Volume] {
    [xvol(10), xvol(20, type: 2), xvol(30, type: 10)]
}

@Suite("paths-extra")
struct PathsExtraTests {
    @Test func groupBoundaries() throws {
        #expect(try mailboxGroupId(1, numGroups: 100) == 1)
        #expect(try mailboxGroupId(100, numGroups: 100) == 100)
        #expect(try mailboxGroupId(101, numGroups: 100) == 1)
        #expect(try mailboxGroupId(1, numGroups: 1) == 1)
        #expect(try mailboxGroupId(1_000_000_000, numGroups: 100) == (1_000_000_000 - 1) % 100 + 1)
        #expect(groupDb(3) == "mboxgroup3")
    }

    @Test func groupRejectsNonPositive() {
        #expect(throws: (any Error).self) { try mailboxGroupId(0, numGroups: 100) }
        #expect(throws: (any Error).self) { try mailboxGroupId(1, numGroups: 0) }
    }

    @Test func mailboxDirVariants() {
        let v = xvol(1)
        #expect(v.mailboxDir(5) == "/store/1/0/5")
        #expect(v.mailboxDir(5, serverIdPrefix: "srv-id") == "/store/1/srv-id/0/5")
        let trailing = Volume(id: 1, type: 1, name: "m", path: "/store/1/",
                              fileBits: 8, fileGroupBits: 8, mailboxBits: 12,
                              mailboxGroupBits: 8)
        #expect(trailing.mailboxDir(5) == "/store/1/0/5")
    }

    @Test func blobRelpathVariants() {
        let v = xvol(1)
        #expect(v.blobRelpath(itemId: 12345, revision: 2) == "msg/48/12345-2.msg")
        #expect(v.blobRelpath(itemId: 12345, revision: -1) == "msg/48/12345.msg")
    }

    @Test func mapBasic() throws {
        let m = try mapVolumes(srcVols: [xvol(1), xvol(2, type: 2), xvol(3, type: 10)],
                               dstVols: xdst(), dstCurrentMsg: 10, dstCurrentSecondary: 20,
                               dstCurrentIndex: 30)
        #expect(m == [1: 10, 2: 20, 3: 30])
    }

    @Test func mapSecondaryFallsBack() throws {
        let m = try mapVolumes(srcVols: [xvol(2, type: 2)], dstVols: xdst(),
                               dstCurrentMsg: 10, dstCurrentSecondary: nil,
                               dstCurrentIndex: 30)
        #expect(m == [2: 10])
    }

    @Test func mapExplicitOverride() throws {
        var dst = xdst()
        dst.append(xvol(99))
        let m = try mapVolumes(srcVols: [xvol(2, type: 2)], dstVols: dst,
                               dstCurrentMsg: 10, dstCurrentSecondary: 20,
                               dstCurrentIndex: 30, explicit: [2: 99])
        #expect(m == [2: 99])
    }

    @Test func mapUnknownTypeSkipped() throws {
        let m = try mapVolumes(srcVols: [xvol(7, type: 99)], dstVols: xdst(),
                               dstCurrentMsg: 10, dstCurrentSecondary: 20,
                               dstCurrentIndex: 30)
        #expect(m == [:])
    }

    @Test func mapExternalNeedsExplicit() {
        #expect(throws: VolumeMapError.self) {
            try mapVolumes(srcVols: [xvol(1, st: 2)], dstVols: xdst(),
                           dstCurrentMsg: 10, dstCurrentSecondary: 20, dstCurrentIndex: 30)
        }
        let dst = [xvol(10, st: 2), xvol(20, type: 2), xvol(30, type: 10)]
        #expect(throws: VolumeMapError.self) {
            try mapVolumes(srcVols: [xvol(1)], dstVols: dst,
                           dstCurrentMsg: 10, dstCurrentSecondary: 20, dstCurrentIndex: 30)
        }
    }

    @Test func mapDstMissing() {
        #expect(throws: VolumeMapError.self) {
            try mapVolumes(srcVols: [xvol(1)], dstVols: [xvol(30, type: 10)],
                           dstCurrentMsg: 10, dstCurrentSecondary: 20, dstCurrentIndex: 30)
        }
    }

    @Test func mapTypeMismatch() {
        #expect(throws: VolumeMapError.self) {
            try mapVolumes(srcVols: [xvol(1)], dstVols: [xvol(10, type: 10)],
                           dstCurrentMsg: 10, dstCurrentSecondary: 20, dstCurrentIndex: 10)
        }
    }

    @Test func mapLayoutMismatch() {
        let dst = [xvol(10, fb: 10), xvol(20, type: 2), xvol(30, type: 10)]
        #expect(throws: VolumeMapError.self) {
            try mapVolumes(srcVols: [xvol(1)], dstVols: dst,
                           dstCurrentMsg: 10, dstCurrentSecondary: 20, dstCurrentIndex: 30)
        }
    }

     @Test func mapLayoutMismatchExplicitInternalRejected() {
         #expect(throws: VolumeMapError.self) {
             try mapVolumes(srcVols: [xvol(1)], dstVols: [xvol(99, fb: 10)],
                            dstCurrentMsg: 99, dstCurrentSecondary: 20, dstCurrentIndex: 30,
                            explicit: [1: 99])
         }
     }

    @Test func locatorExact() {
        #expect(locatorCaseSQL(column: "locator", mapping: [:]) == "locator")
        #expect(locatorCaseSQL(column: "locator", mapping: [1: 1]) == "locator")
        #expect(locatorCaseSQL(column: "loc", mapping: [1: 2]) ==
            "(CASE loc WHEN '1' THEN '2' ELSE loc END)")
        #expect(locatorCaseSQL(column: "loc", mapping: [3: 4, 1: 2]) ==
            "(CASE loc WHEN '1' THEN '2' WHEN '3' THEN '4' ELSE loc END)")
    }

    @Test func transportNonLmtpUntouched() {
        for t in ["smtp:relay:25", "hold:foo", "error:bar"] {
            #expect(replaceHostInTransport(t, "b") == t)
        }
        #expect(replaceHostInTransport("", "b") == "lmtp:b:7025")
    }
}

 import Foundation
 import Testing
 @testable import ZMove

private func vol(_ id: Int, type: Int = 1, path: String = "/opt/zimbra/store",
                 fb: Int = 12, fgb: Int = 8, st: Int = 1) -> Volume {
    Volume(id: id, type: type, name: "v\(id)", path: path,
           fileBits: fb, fileGroupBits: fgb, mailboxBits: 12,
           mailboxGroupBits: 8, storeType: st)
}

@Suite("paths")
struct PathsTests {
    @Test func groupAndDirs() throws {
        #expect(try mailboxGroupId(1, numGroups: 100) == 1)
        #expect(try mailboxGroupId(101, numGroups: 100) == 1)
        #expect(try mailboxGroupId(100, numGroups: 100) == 100)
        #expect(vol(1).mailboxDir(5) == "/opt/zimbra/store/0/5")
        #expect(vol(1).mailboxDir(5, serverIdPrefix: "sid") == "/opt/zimbra/store/sid/0/5")
        #expect(vol(1).blobRelpath(itemId: 4097, revision: 3) == "msg/1/4097-3.msg")
    }

    @Test func mapVolumesLayoutMismatch() {
        #expect(throws: (any Error).self) {
            try mapVolumes(srcVols: [vol(1)], dstVols: [vol(2, fb: 10)],
                           dstCurrentMsg: 2, dstCurrentSecondary: nil, dstCurrentIndex: 3)
        }
    }

    @Test func mapVolumesSecondaryFallsBackToPrimary() throws {
        let m = try mapVolumes(srcVols: [vol(1), vol(2, type: 2), vol(3, type: 10)],
                               dstVols: [vol(4), vol(5, type: 10)],
                               dstCurrentMsg: 4, dstCurrentSecondary: nil,
                               dstCurrentIndex: 5)
        #expect(m == [1: 4, 2: 4, 3: 5])
    }

    @Test func locatorCaseAndTransport() {
        #expect(locatorCaseSQL(column: "`locator`", mapping: [1: 1]) == "`locator`")
        #expect(locatorCaseSQL(column: "`locator`", mapping: [1: 4]).contains("WHEN '1' THEN '4'"))
        #expect(replaceHostInTransport("lmtp:a:7025", "b") == "lmtp:b:7025")
        #expect(replaceHostInTransport("smtp:[relay]:25", "b") == "smtp:[relay]:25")
        #expect(replaceHostInTransport("", "b") == "lmtp:b:7025")
        #expect(replaceHostInTransport("lmtp:a:7025", "b", port: 7026) == "lmtp:b:7026")
    }

    @Test func cutoverWindow() throws {
        #expect(try parseWindow("22:00-06:00") == (1320, 360))
         #expect(throws: (any Error).self) { try parseWindow("22-06") }
         #expect(throws: (any Error).self) { try parseWindow("25:00-06:00") }
         var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
         comps.hour = 23; comps.minute = 0
         let night = Calendar.current.date(from: comps)!
         #expect(try inWindow("22:00-06:00", now: night))
         comps.hour = 12
         #expect(!(try inWindow("22:00-06:00", now: Calendar.current.date(from: comps)!)))
    }
}

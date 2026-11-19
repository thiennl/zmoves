import Testing
@testable import ZMove

@Suite("db-sql")
struct DbSQLTests {
    @Test func identAndQuote() throws {
        #expect(try ident("mail_item") == "`mail_item`")
        #expect(throws: (any Error).self) { try ident("x`; drop") }
        #expect(q("o'b\\") == "'o\\'b\\\\'")
    }

    @Test func checksumAndInsertSQL() {
        let ti = TableInfo(schema: "g", name: "mail_item",
                           columns: ["mailbox_id", "id", "locator"], uniqueIndexes: [])
        let sql = checksumSQL(schema: "g", table: ti, keyCol: "mailbox_id",
                              keyVal: 7, locatorExpr: "(CASE x END)")
        #expect(sql.contains("WHERE `mailbox_id`=7"))
        #expect(sql.contains("(CASE x END)"))
        #expect(!sql.contains("`mailbox_id`,"))
        let ins = insertSelectSQL(dstSchema: "dst", stageSchema: "stage", table: ti,
                                  keyCol: "mailbox_id", newKey: 9,
                                  overrides: ["locator": "L"])
        #expect(ins.hasPrefix("INSERT INTO `dst`.`mail_item` (`mailbox_id`, `id`, `locator`) SELECT 9, `id`, L"))
    }

    @Test func mysqlMyCnfIsConfigurable() throws {
        let s = Settings()
        let h = Host(name: "t", settings: s)
        let m = MySQL(host: h, mysqlBin: "mysql", mysqldumpBin: "mysqldump",
                      myCnf: "/srv/zimbra/conf/my.cnf")
        #expect(try m.clientCmd().contains("--defaults-file=/srv/zimbra/conf/my.cnf"))
        #expect(try m.dumpCmd(db: "g", tables: ["t"], where: "1=1")
            .contains("--defaults-file=/srv/zimbra/conf/my.cnf"))
    }
}

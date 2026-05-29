import XCTest
import GRDB
@testable import TrackerBudCore

final class EventStoreTests: XCTestCase {

    // We can't easily redirect EventStore.databaseURL, so these tests exercise
    // the migrator + a fresh in-memory DatabaseQueue directly. The EventStore
    // class is exercised via integration smoke tests in the app itself.

    func testSchemaMigratesOnFreshDatabase() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator().migrate(queue)

        try queue.read { db in
            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type='table' ORDER BY name
            """)
            // v1
            XCTAssertTrue(tables.contains("events"))
            XCTAssertTrue(tables.contains("app_events"))
            XCTAssertTrue(tables.contains("sessions"))
            XCTAssertTrue(tables.contains("patterns"))
            XCTAssertTrue(tables.contains("screenshots"))
            XCTAssertTrue(tables.contains("clipboard_items"))
            // v2
            XCTAssertTrue(tables.contains("screen_time_cache"))
            XCTAssertTrue(tables.contains("digests"))
            XCTAssertTrue(tables.contains("digest_runs"))
            XCTAssertTrue(tables.contains("api_calls"))
            XCTAssertTrue(tables.contains("session_summaries"))
        }
    }

    func testEventsHasIsPrivateColumn() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator().migrate(queue)
        try queue.read { db in
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(events)")
            let names = columns.compactMap { $0["name"] as String? }
            XCTAssertTrue(names.contains("is_private"))
        }
    }

    func testDigestRoundTrip() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator().migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO digests (kind, range_start, range_end, created_at, payload_json)
                VALUES ('daily', ?, ?, ?, ?)
            """, arguments: [
                Date().timeIntervalSince1970 - 86400,
                Date().timeIntervalSince1970,
                Date().timeIntervalSince1970,
                "{\"totalActiveMinutes\":42}"
            ])
        }
        try queue.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM digests")
            XCTAssertEqual(count, 1)
        }
    }

    func testAPICallRoundTrip() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator().migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO api_calls (ts, model, input_tokens, output_tokens,
                                       cache_read_tokens, cache_creation_tokens,
                                       cost_usd, purpose)
                VALUES (?, 'claude-haiku-4-5', 1000, 500, 800, 100, 0.0035, 'test')
            """, arguments: [Date().timeIntervalSince1970])
        }
        try queue.read { db in
            let cost = try Double.fetchOne(db, sql: "SELECT SUM(cost_usd) FROM api_calls")
            XCTAssertNotNil(cost)
            XCTAssertEqual(cost!, 0.0035, accuracy: 1e-6)
        }
    }

    func testFTS5IsAvailable() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator().migrate(queue)

        try queue.write { db in
            try db.execute(sql: "CREATE VIRTUAL TABLE temp.probe USING fts5(content)")
            try db.execute(sql: "INSERT INTO probe VALUES (?)", arguments: ["the quick brown fox"])
            let hits = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM probe WHERE probe MATCH 'quick'
            """)
            XCTAssertEqual(hits, 1)
        }
    }

    func testClipboardFTSRoundTrip() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator().migrate(queue)

        try queue.write { db in
            // Insert a session + event so the FK on clipboard_items can resolve.
            let session = Session(startedAt: Date().timeIntervalSince1970)
            try session.insert(db)
            let sessionID = db.lastInsertedRowID

            let event = Event(
                ts: Date().timeIntervalSince1970,
                sessionId: sessionID,
                source: .clipboard,
                type: "clipboard.copy",
                token: "clip:text",
                payloadJSON: "{}"
            )
            try event.insert(db)
            let eventID = db.lastInsertedRowID

            try db.execute(sql: """
                INSERT INTO clipboard_items (event_id, ts, kind, text_content)
                VALUES (?, ?, 'text', ?)
            """, arguments: [eventID, Date().timeIntervalSince1970, "hello world from clipboard"])
            let rowid = db.lastInsertedRowID

            try db.execute(
                sql: "INSERT INTO clipboard_fts(rowid, text_content) VALUES (?, ?)",
                arguments: [rowid, "hello world from clipboard"]
            )

            let hits = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM clipboard_fts WHERE clipboard_fts MATCH 'world'
            """)
            XCTAssertEqual(hits, 1)
        }
    }

    func testInsertingEventAndAppDetailRoundTrips() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator().migrate(queue)

        try queue.write { db in
            let session = Session(startedAt: Date().timeIntervalSince1970)
            try session.insert(db)
            let sessionID = db.lastInsertedRowID

            let event = Event(
                ts: Date().timeIntervalSince1970,
                sessionId: sessionID,
                source: .app,
                type: "app.activated",
                token: "app:com.apple.mail",
                payloadJSON: "{}"
            )
            try event.insert(db)
            let eventID = db.lastInsertedRowID

            let detail = AppEventDetail(
                eventId: eventID,
                bundleId: "com.apple.mail",
                appName: "Mail",
                windowTitle: "Inbox",
                pid: 1234
            )
            try detail.insert(db)
        }

        try queue.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events") ?? 0
            XCTAssertEqual(count, 1)

            let joined = try Row.fetchOne(db, sql: """
                SELECT e.token, a.app_name, a.window_title
                FROM events e JOIN app_events a ON a.event_id = e.id
            """)
            XCTAssertEqual(joined?["token"], "app:com.apple.mail")
            XCTAssertEqual(joined?["app_name"], "Mail")
            XCTAssertEqual(joined?["window_title"], "Inbox")
        }
    }
}

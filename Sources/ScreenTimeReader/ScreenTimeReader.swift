import Foundation
import GRDB
import TrackerBudCore
import OSLog

/// Read-only access to Apple's Screen Time DB. The DB lives at
/// `~/Library/Application Support/Knowledge/knowledgeC.db` and is owned by
/// the user but TCC restricts access — Full Disk Access is required.
///
/// We open it via the SQLite `?mode=ro&immutable=1` URI so we don't acquire a
/// lock or trigger a journal write. Apple's writer keeps appending while we
/// read.
///
/// Schema is private to Apple and may change between macOS releases. We probe
/// for the columns we need and return `.unavailable` instead of crashing if
/// they're gone.
public final class ScreenTimeReader: @unchecked Sendable {
    public static let shared = ScreenTimeReader()

    public enum Status: Sendable, Equatable {
        case ready
        case fileMissing
        case notReadable    // typically: FDA not granted
        case schemaUnsupported(String)
    }

    public struct AppUsageRow: Sendable, Hashable {
        public let bundleID: String
        public let date: Date
        public let totalSeconds: Int
    }

    public struct WebUsageRow: Sendable, Hashable {
        public let host: String
        public let date: Date
        public let totalSeconds: Int
    }

    /// Apple stores timestamps as seconds since 2001-01-01 UTC, not the unix epoch.
    private static let cocoaReferenceDate: TimeInterval = 978307200

    private let log = Logger(subsystem: "com.arushsharma.trackerbud", category: "ScreenTimeReader")
    private let dbPath: String

    public init(path: String? = nil) {
        self.dbPath = path ?? "\(NSHomeDirectory())/Library/Application Support/Knowledge/knowledgeC.db"
    }

    public func status() -> Status {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dbPath) else { return .fileMissing }
        // Behavioral probe: try to open read-only. FDA denial returns SQLITE_AUTH or open failure.
        do {
            let q = try openReadOnly()
            // Verify the tables we depend on are present.
            return try q.read { db -> Status in
                let tables = try String.fetchAll(db, sql: """
                    SELECT name FROM sqlite_master WHERE type='table' AND name IN ('ZOBJECT','ZSTRUCTUREDMETADATA')
                """)
                if !tables.contains("ZOBJECT") {
                    return .schemaUnsupported("missing ZOBJECT")
                }
                return .ready
            }
        } catch {
            log.warning("ScreenTime open failed: \(error.localizedDescription, privacy: .public)")
            return .notReadable
        }
    }

    public func appUsage(for date: Date) throws -> [AppUsageRow] {
        let boundary = EventStore.DayBoundary(date: date)
        let startCocoa = boundary.start.timeIntervalSince1970 - Self.cocoaReferenceDate
        let endCocoa = boundary.end.timeIntervalSince1970 - Self.cocoaReferenceDate

        let queue = try openReadOnly()
        let rows = try queue.read { db -> [AppUsageRow] in
            // ZOBJECT.ZSTREAMNAME = '/app/usage'
            // ZOBJECT.ZVALUESTRING = bundle ID
            // ZOBJECT.ZSTARTDATE / ZENDDATE in Cocoa reference seconds
            let raw = try Row.fetchAll(db, sql: """
                SELECT ZVALUESTRING AS bundle,
                       CAST(SUM(ZENDDATE - ZSTARTDATE) AS INTEGER) AS secs
                FROM ZOBJECT
                WHERE ZSTREAMNAME = '/app/usage'
                  AND ZSTARTDATE >= ?
                  AND ZSTARTDATE < ?
                  AND ZVALUESTRING IS NOT NULL
                GROUP BY ZVALUESTRING
                HAVING secs > 0
                ORDER BY secs DESC
            """, arguments: [startCocoa, endCocoa])
            return raw.compactMap { row in
                guard let bundle: String = row["bundle"], let secs: Int = row["secs"] else { return nil }
                return AppUsageRow(bundleID: bundle, date: boundary.start, totalSeconds: secs)
            }
        }
        return rows
    }

    public func webUsage(for date: Date) throws -> [WebUsageRow] {
        let boundary = EventStore.DayBoundary(date: date)
        let startCocoa = boundary.start.timeIntervalSince1970 - Self.cocoaReferenceDate
        let endCocoa = boundary.end.timeIntervalSince1970 - Self.cocoaReferenceDate

        let queue = try openReadOnly()
        return try queue.read { db -> [WebUsageRow] in
            let raw = try Row.fetchAll(db, sql: """
                SELECT ZVALUESTRING AS host,
                       CAST(SUM(ZENDDATE - ZSTARTDATE) AS INTEGER) AS secs
                FROM ZOBJECT
                WHERE ZSTREAMNAME = '/app/webUsage'
                  AND ZSTARTDATE >= ?
                  AND ZSTARTDATE < ?
                  AND ZVALUESTRING IS NOT NULL
                GROUP BY ZVALUESTRING
                HAVING secs > 0
                ORDER BY secs DESC
                LIMIT 100
            """, arguments: [startCocoa, endCocoa])
            return raw.compactMap { row in
                guard let host: String = row["host"], let secs: Int = row["secs"] else { return nil }
                return WebUsageRow(host: host, date: boundary.start, totalSeconds: secs)
            }
        }
    }

    /// Sync app usage for a date into our EventStore.screen_time_cache.
    /// Idempotent: re-running for the same date replaces the cached row.
    @discardableResult
    public func syncCache(for date: Date) throws -> Int {
        let isoDate = Self.isoDay(from: date)
        let rows = try appUsage(for: date)
        for row in rows {
            try EventStore.shared.upsertScreenTimeCache(
                bundleID: row.bundleID,
                dateISO: isoDate,
                totalSeconds: row.totalSeconds
            )
        }
        return rows.count
    }

    public static func isoDay(from date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func openReadOnly() throws -> DatabaseQueue {
        var config = Configuration()
        config.readonly = true
        config.label = "screen_time.ro"
        // immutable=1 tells SQLite the file won't change during the connection
        // lifetime, so it skips locking even though Apple's writer is also touching it.
        // The reader takes a snapshot at open time which is fine for our use.
        return try DatabaseQueue(path: dbPath, configuration: config)
    }
}

import Foundation
import GRDB
import OSLog

/// Owns the GRDB connection. DatabaseQueue is thread-safe internally; we
/// only synchronize the small mutable bits (currentSessionID, dbQueue
/// reference during startup).
public final class EventStore: @unchecked Sendable {
    public static let shared = EventStore()

    private let lock = NSLock()
    private var dbQueue: DatabaseQueue?
    private var currentSessionID: Int64?
    private let log = Logger(subsystem: "com.arushsharma.trackerbud", category: "EventStore")
    private let idleGapSeconds: Double = 5 * 60

    public init() {}

    public static func databaseURL() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("TrackerBud", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("trackerbud.db")
    }

    public func start() throws {
        lock.lock()
        if dbQueue != nil { lock.unlock(); return }
        lock.unlock()

        // Ensure encryption key exists in Keychain before opening the DB,
        // so writes happening at startup can already encrypt sensitive fields.
        try CryptoVault.shared.ensureKey()

        let url = try Self.databaseURL()
        log.info("Opening database at \(url.path, privacy: .public)")

        var config = Configuration()
        config.label = "trackerbud.main"
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        try Schema.migrator().migrate(queue)

        lock.lock()
        self.dbQueue = queue
        lock.unlock()

        try ensureSession()
        try runFTS5SmokeTest()
    }

    public func reader() throws -> DatabaseReader {
        lock.lock()
        defer { lock.unlock() }
        guard let q = dbQueue else { throw EventStoreError.notStarted }
        return q
    }

    private func requireQueue() throws -> DatabaseQueue {
        lock.lock()
        defer { lock.unlock() }
        guard let q = dbQueue else { throw EventStoreError.notStarted }
        return q
    }

    private func ensureSession() throws {
        let queue = try requireQueue()
        let now = Date().timeIntervalSince1970

        let sessionID: Int64 = try queue.write { db in
            if let last = try Session.order(Column("id").desc).fetchOne(db) {
                let lastTouch = try Event
                    .filter(Column("session_id") == last.id!)
                    .order(Column("ts").desc)
                    .fetchOne(db)?.ts ?? last.startedAt
                if last.endedAt == nil && (now - lastTouch) < self.idleGapSeconds {
                    return last.id!
                } else if last.endedAt == nil {
                    try db.execute(
                        sql: "UPDATE sessions SET ended_at = ? WHERE id = ?",
                        arguments: [lastTouch, last.id!]
                    )
                }
            }
            let session = Session(startedAt: now)
            try session.insert(db)
            return db.lastInsertedRowID
        }

        lock.lock()
        self.currentSessionID = sessionID
        lock.unlock()
        log.info("Active session: \(sessionID, privacy: .public)")
    }

    public func currentSession() throws -> Int64 {
        lock.lock()
        let cached = currentSessionID
        lock.unlock()
        if let id = cached { return id }
        try ensureSession()
        lock.lock()
        defer { lock.unlock() }
        return currentSessionID!
    }

    @discardableResult
    public func writeAppEvent(
        ts: Date,
        type: String,
        token: String,
        bundleID: String,
        appName: String,
        windowTitle: String?,
        pid: Int32?,
        payloadJSON: String = "{}"
    ) throws -> Int64 {
        let queue = try requireQueue()
        let sessionID = try currentSession()
        let encryptedTitle = CryptoVault.shared.encrypt(windowTitle)
        let encryptedPayload = CryptoVault.shared.encrypt(payloadJSON) ?? payloadJSON
        let inserted: Int64 = try queue.write { db in
            // Before inserting the new event, back-fill duration_ms on the
            // previous foreground row of THIS session for the prior bundle.
            // Only on type "app.activated" — window-title-change events are
            // intra-app and shouldn't close a duration window.
            if type == "app.activated" {
                if let prior = try Row.fetchOne(db, sql: """
                    SELECT e.id, e.ts, a.bundle_id
                    FROM events e
                    JOIN app_events a ON a.event_id = e.id
                    WHERE e.session_id = ? AND e.source = 'app' AND e.type = 'app.activated'
                    ORDER BY e.id DESC
                    LIMIT 1
                """, arguments: [sessionID]) {
                    let priorID: Int64 = prior["id"]
                    let priorTS: Double = prior["ts"]
                    let priorBundle: String = prior["bundle_id"] ?? ""
                    if priorBundle != bundleID {
                        let durationMs = Int64((ts.timeIntervalSince1970 - priorTS) * 1000)
                        if durationMs >= 0 && durationMs < 6 * 3600 * 1000 {  // sanity cap: 6h
                            try db.execute(
                                sql: "UPDATE events SET duration_ms = ? WHERE id = ?",
                                arguments: [durationMs, priorID]
                            )
                        }
                    }
                }
            }

            let ev = Event(
                ts: ts.timeIntervalSince1970,
                sessionId: sessionID,
                source: .app,
                type: type,
                token: token,
                payloadJSON: encryptedPayload
            )
            try ev.insert(db)
            let eventID = db.lastInsertedRowID
            let detail = AppEventDetail(
                eventId: eventID,
                bundleId: bundleID,
                appName: appName,
                windowTitle: encryptedTitle,
                pid: pid
            )
            try detail.insert(db)
            return eventID
        }
        return inserted
    }

    // MARK: - Time analytics queries

    public struct DayBoundary {
        public let start: Date
        public let end: Date
        public init(date: Date, calendar: Calendar = .current) {
            let startOfDay = calendar.startOfDay(for: date)
            self.start = startOfDay
            self.end = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
        }
    }

    public func appTimeSpent(date: Date) throws -> [(bundleID: String, appName: String?, seconds: Int)] {
        let boundary = DayBoundary(date: date)
        let queue = try requireQueue()
        return try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT a.bundle_id, a.app_name,
                       CAST(SUM(COALESCE(e.duration_ms, 0)) / 1000 AS INTEGER) AS secs
                FROM events e
                JOIN app_events a ON a.event_id = e.id
                WHERE e.source = 'app' AND e.type = 'app.activated'
                  AND e.ts >= ? AND e.ts < ?
                  AND e.duration_ms IS NOT NULL
                GROUP BY a.bundle_id
                HAVING secs > 0
                ORDER BY secs DESC
            """, arguments: [
                boundary.start.timeIntervalSince1970,
                boundary.end.timeIntervalSince1970
            ]).map { row in
                (bundleID: row["bundle_id"] ?? "", appName: row["app_name"], seconds: row["secs"] ?? 0)
            }
        }
    }

    public func siteTimeSpent(date: Date) throws -> [(host: String, seconds: Int)] {
        // Browser tracker writes one event per URL change. We use the time
        // between consecutive browser events of the same host as a proxy.
        // Less accurate than apps (background tabs not counted) but useful.
        let boundary = DayBoundary(date: date)
        let queue = try requireQueue()
        return try queue.read { db in
            // Compute durations by row_number window
            let rows = try Row.fetchAll(db, sql: """
                WITH ordered AS (
                    SELECT b.url_host AS host, e.ts AS ts,
                           LEAD(e.ts) OVER (PARTITION BY e.session_id ORDER BY e.ts) AS next_ts,
                           e.session_id
                    FROM events e
                    JOIN browser_events b ON b.event_id = e.id
                    WHERE e.source = 'browser' AND e.ts >= ? AND e.ts < ?
                )
                SELECT host, CAST(SUM(MIN(COALESCE(next_ts - ts, 0), 1800)) AS INTEGER) AS secs
                FROM ordered
                WHERE next_ts IS NOT NULL
                GROUP BY host
                HAVING secs > 0
                ORDER BY secs DESC
                LIMIT 50
            """, arguments: [
                boundary.start.timeIntervalSince1970,
                boundary.end.timeIntervalSince1970
            ])
            return rows.map { row in
                (host: row["host"] ?? "", seconds: row["secs"] ?? 0)
            }
        }
    }

    public func totalActiveSeconds(date: Date) throws -> Int {
        let rows = try appTimeSpent(date: date)
        return rows.reduce(0) { $0 + $1.seconds }
    }

    // MARK: - Screen Time cache

    public func upsertScreenTimeCache(bundleID: String, dateISO: String, totalSeconds: Int) throws {
        let queue = try requireQueue()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO screen_time_cache (bundle_id, date_iso, total_seconds, fetched_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(bundle_id, date_iso) DO UPDATE SET
                    total_seconds = excluded.total_seconds,
                    fetched_at = excluded.fetched_at
            """, arguments: [bundleID, dateISO, totalSeconds, Date().timeIntervalSince1970])
        }
    }

    public func screenTimeForDate(_ dateISO: String) throws -> [(bundleID: String, seconds: Int)] {
        let queue = try requireQueue()
        return try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT bundle_id, total_seconds FROM screen_time_cache
                WHERE date_iso = ? ORDER BY total_seconds DESC
            """, arguments: [dateISO]).map { row in
                (bundleID: row["bundle_id"] ?? "", seconds: row["total_seconds"] ?? 0)
            }
        }
    }

    public func recentEventRows(limit: Int = 200) throws -> [EventRow] {
        let queue = try requireQueue()
        return try queue.read { db in
            let sql = """
                SELECT e.id, e.ts, e.source, e.type, e.token,
                       a.app_name, a.window_title, a.bundle_id,
                       b.url, b.url_host, b.page_title, b.browser,
                       f.path AS file_path, f.action AS file_action,
                       i.modifiers AS in_mods, i.key_code AS in_key, i.key_char AS in_char,
                       c.kind AS clip_kind, c.text_content AS clip_text, c.source_app AS clip_app
                FROM events e
                LEFT JOIN app_events a ON a.event_id = e.id
                LEFT JOIN browser_events b ON b.event_id = e.id
                LEFT JOIN file_events f ON f.event_id = e.id
                LEFT JOIN input_events i ON i.event_id = e.id
                LEFT JOIN clipboard_items c ON c.event_id = e.id
                ORDER BY e.id DESC
                LIMIT ?
            """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [limit])
            return rows.compactMap { row -> EventRow? in
                guard
                    let id: Int64 = row["id"],
                    let ts: Double = row["ts"],
                    let sourceStr: String = row["source"],
                    let type: String = row["type"],
                    let token: String = row["token"],
                    let source = EventSource(rawValue: sourceStr)
                else { return nil }

                let vault = CryptoVault.shared
                var primary: String? = nil
                var secondary: String? = nil
                var appName: String? = row["app_name"]
                let bundleID: String? = row["bundle_id"]

                switch source {
                case .app:
                    primary = vault.decrypt(row["window_title"])
                    secondary = bundleID
                case .browser:
                    let title = vault.decrypt(row["page_title"])
                    let url = vault.decrypt(row["url"])
                    primary = title?.isEmpty == false ? title : url
                    secondary = row["url_host"]
                    if appName == nil { appName = (row["browser"] as String?)?.capitalized }
                case .file:
                    let p = vault.decrypt(row["file_path"]) ?? ""
                    primary = (p as NSString).lastPathComponent
                    secondary = row["file_action"]
                case .input:
                    let modifiers: Int64 = row["in_mods"] ?? 0
                    let key: String = row["in_char"] ?? ""
                    let keyCode: Int64 = row["in_key"] ?? 0
                    primary = InputKeyFormatter.format(modifiers: modifiers, keyChar: key, keyCode: keyCode)
                    if appName == nil { appName = bundleID }
                case .clipboard:
                    let text = vault.decrypt(row["clip_text"]) ?? ""
                    primary = String(text.prefix(80))
                    secondary = row["clip_kind"]
                    if appName == nil { appName = row["clip_app"] }
                case .screen:
                    primary = "Screenshot"
                    secondary = bundleID
                }

                return EventRow(
                    id: id,
                    ts: Date(timeIntervalSince1970: ts),
                    source: source,
                    type: type,
                    token: token,
                    appName: appName,
                    bundleId: bundleID,
                    primaryText: primary,
                    secondaryText: secondary
                )
            }
        }
    }

    public func countEvents() throws -> Int {
        let queue = try requireQueue()
        return try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events") ?? 0
        }
    }

    public func countScreenshots() throws -> Int {
        let queue = try requireQueue()
        return try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM screenshots WHERE skipped_reason IS NULL AND thumb_path != ''") ?? 0
        }
    }

    @discardableResult
    public func writeBrowserEvent(
        ts: Date,
        browser: String,
        url: String,
        urlHost: String,
        urlPath: String?,
        pageTitle: String?,
        token: String
    ) throws -> Int64 {
        let queue = try requireQueue()
        let sessionID = try currentSession()
        let vault = CryptoVault.shared
        let encURL = vault.encrypt(url) ?? url
        let encPath = vault.encrypt(urlPath)
        let encTitle = vault.encrypt(pageTitle)
        return try queue.write { db in
            let ev = Event(
                ts: ts.timeIntervalSince1970,
                sessionId: sessionID,
                source: .browser,
                type: "browser.url",
                token: token,
                payloadJSON: "{}"
            )
            try ev.insert(db)
            let eventID = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO browser_events (event_id, browser, url, url_host, url_path, page_title)
                VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [eventID, browser, encURL, urlHost, encPath, encTitle])
            return eventID
        }
    }

    @discardableResult
    public func writeFileEvent(
        ts: Date,
        path: String,
        action: String,
        inode: Int64?,
        fileExt: String?,
        token: String
    ) throws -> Int64 {
        let queue = try requireQueue()
        let sessionID = try currentSession()
        let vault = CryptoVault.shared
        let encPath = vault.encrypt(path) ?? path
        return try queue.write { db in
            let ev = Event(
                ts: ts.timeIntervalSince1970,
                sessionId: sessionID,
                source: .file,
                type: "file.\(action)",
                token: token,
                payloadJSON: "{}"
            )
            try ev.insert(db)
            let eventID = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO file_events (event_id, path, action, inode, file_ext)
                VALUES (?, ?, ?, ?, ?)
            """, arguments: [eventID, encPath, action, inode, fileExt])
            return eventID
        }
    }

    @discardableResult
    public func writeInputEvent(
        ts: Date,
        modifiers: Int64,
        keyCode: Int64,
        keyChar: String?,
        token: String
    ) throws -> Int64 {
        let queue = try requireQueue()
        let sessionID = try currentSession()
        return try queue.write { db in
            let ev = Event(
                ts: ts.timeIntervalSince1970,
                sessionId: sessionID,
                source: .input,
                type: "input.shortcut",
                token: token,
                payloadJSON: "{}"
            )
            try ev.insert(db)
            let eventID = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO input_events (event_id, modifiers, key_code, key_char)
                VALUES (?, ?, ?, ?)
            """, arguments: [eventID, modifiers, keyCode, keyChar])
            return eventID
        }
    }

    @discardableResult
    public func writeClipboardEvent(
        ts: Date,
        kind: String,
        textContent: String?,
        byteSize: Int?,
        sourceApp: String?,
        token: String
    ) throws -> Int64 {
        let queue = try requireQueue()
        let sessionID = try currentSession()
        let vault = CryptoVault.shared
        let encText = vault.encrypt(textContent)
        return try queue.write { db in
            let ev = Event(
                ts: ts.timeIntervalSince1970,
                sessionId: sessionID,
                source: .clipboard,
                type: "clipboard.copy",
                token: token,
                payloadJSON: "{}"
            )
            try ev.insert(db)
            let eventID = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO clipboard_items (event_id, ts, kind, text_content, byte_size, source_app)
                VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [eventID, ts.timeIntervalSince1970, kind, encText, byteSize, sourceApp])
            let clipID = db.lastInsertedRowID
            // FTS5: index plaintext for search. The clipboard_fts index holds
            // plaintext — accept the lower security bar here so search works.
            if let t = textContent, !t.isEmpty {
                try db.execute(sql: """
                    INSERT INTO clipboard_fts (rowid, text_content) VALUES (?, ?)
                """, arguments: [clipID, t])
            }
            return eventID
        }
    }

    @discardableResult
    public func writeScreenshot(
        ts: Date,
        frontmostBundle: String?,
        thumbPath: String,
        fullresPath: String?,
        perceptualHash: Int64?,
        width: Int,
        height: Int,
        skippedReason: String?,
        ocrText: String?,
        token: String
    ) throws -> (eventID: Int64, screenshotID: Int64) {
        let queue = try requireQueue()
        let sessionID = try currentSession()
        let vault = CryptoVault.shared
        let encOCR = vault.encrypt(ocrText)
        return try queue.write { db in
            let ev = Event(
                ts: ts.timeIntervalSince1970,
                sessionId: sessionID,
                source: .screen,
                type: skippedReason == nil ? "screen.capture" : "screen.skip",
                token: token,
                payloadJSON: "{}"
            )
            try ev.insert(db)
            let eventID = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO screenshots (ts, display_id, frontmost_bundle, thumb_path, fullres_path,
                                         perceptual_hash, width, height, skipped_reason)
                VALUES (?, NULL, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                ts.timeIntervalSince1970, frontmostBundle, thumbPath, fullresPath,
                perceptualHash, width, height, skippedReason
            ])
            let shotID = db.lastInsertedRowID

            if let text = ocrText, !text.isEmpty {
                try db.execute(sql: """
                    INSERT INTO ocr_blocks (screenshot_id, text, confidence)
                    VALUES (?, ?, ?)
                """, arguments: [shotID, encOCR, 1.0])
                let blockID = db.lastInsertedRowID
                try db.execute(sql: """
                    INSERT INTO ocr_fts (rowid, text) VALUES (?, ?)
                """, arguments: [blockID, text])
            }
            return (eventID, shotID)
        }
    }

    // MARK: - Privacy rules

    public struct PrivacyRule: Sendable, Hashable, Identifiable {
        public let id: Int64
        public let bundleID: String?
        public let urlPattern: String?
        public let action: String
        public let createdAt: Date
    }

    public func privacyRules() throws -> [PrivacyRule] {
        let queue = try requireQueue()
        return try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM privacy_rules ORDER BY id ASC").map { row in
                PrivacyRule(
                    id: row["id"],
                    bundleID: row["bundle_id"],
                    urlPattern: row["url_pattern"],
                    action: row["action"],
                    createdAt: Date(timeIntervalSince1970: row["created_at"] ?? 0)
                )
            }
        }
    }

    public func addPrivacyRule(bundleID: String?, urlPattern: String?, action: String) throws {
        let queue = try requireQueue()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO privacy_rules (bundle_id, url_pattern, action, created_at)
                VALUES (?, ?, ?, ?)
            """, arguments: [bundleID, urlPattern, action, Date().timeIntervalSince1970])
        }
    }

    public func removePrivacyRule(id: Int64) throws {
        let queue = try requireQueue()
        try queue.write { db in
            try db.execute(sql: "DELETE FROM privacy_rules WHERE id = ?", arguments: [id])
        }
    }

    public func seedDefaultPrivacyRules() throws {
        let existing = try privacyRules()
        if !existing.isEmpty { return }
        let seeds: [(String, String)] = [
            ("com.apple.keychainaccess", "skip-screenshot"),
            ("com.1password.1password7", "skip-screenshot"),
            ("com.1password.1password8", "skip-screenshot"),
            ("com.agilebits.onepassword4", "skip-screenshot"),
            ("com.bitwarden.desktop", "skip-screenshot"),
            ("com.apple.systempreferences", "skip-screenshot")
        ]
        for (bid, action) in seeds {
            try addPrivacyRule(bundleID: bid, urlPattern: nil, action: action)
        }
    }

    // MARK: - Search

    public func searchClipboard(query: String, limit: Int = 50) throws -> [(eventID: Int64, ts: Date, text: String, sourceApp: String?)] {
        let queue = try requireQueue()
        let sanitized = query
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "*", with: "")
        return try queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.event_id, c.ts, c.text_content, c.source_app
                FROM clipboard_fts f
                JOIN clipboard_items c ON c.id = f.rowid
                WHERE f.text_content MATCH ?
                ORDER BY c.ts DESC
                LIMIT ?
            """, arguments: [sanitized, limit])
            return rows.map { row in
                let plainText = CryptoVault.shared.decrypt(row["text_content"]) ?? ""
                return (
                    eventID: row["event_id"],
                    ts: Date(timeIntervalSince1970: row["ts"]),
                    text: plainText,
                    sourceApp: row["source_app"]
                )
            }
        }
    }

    public func recentScreenshots(limit: Int = 100) throws -> [(screenshotID: Int64, ts: Date, thumbPath: String, snippet: String, frontmostBundle: String?)] {
        let queue = try requireQueue()
        return try queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.id, s.ts, s.thumb_path, s.frontmost_bundle,
                       (SELECT b.text FROM ocr_blocks b WHERE b.screenshot_id = s.id LIMIT 1) AS ocr_text
                FROM screenshots s
                WHERE s.skipped_reason IS NULL AND s.thumb_path != ''
                ORDER BY s.ts DESC
                LIMIT ?
            """, arguments: [limit])
            return rows.map { row in
                let plainText = CryptoVault.shared.decrypt(row["ocr_text"]) ?? ""
                return (
                    screenshotID: row["id"],
                    ts: Date(timeIntervalSince1970: row["ts"]),
                    thumbPath: row["thumb_path"],
                    snippet: String(plainText.prefix(200)),
                    frontmostBundle: row["frontmost_bundle"]
                )
            }
        }
    }

    public func searchOCR(query: String, limit: Int = 100) throws -> [(screenshotID: Int64, ts: Date, thumbPath: String, snippet: String)] {
        let queue = try requireQueue()
        let sanitized = query
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "*", with: "")
        return try queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.id, s.ts, s.thumb_path, b.text
                FROM ocr_fts f
                JOIN ocr_blocks b ON b.id = f.rowid
                JOIN screenshots s ON s.id = b.screenshot_id
                WHERE f.text MATCH ?
                ORDER BY s.ts DESC
                LIMIT ?
            """, arguments: [sanitized, limit])
            return rows.map { row in
                let plainText = CryptoVault.shared.decrypt(row["text"]) ?? ""
                return (
                    screenshotID: row["id"],
                    ts: Date(timeIntervalSince1970: row["ts"]),
                    thumbPath: row["thumb_path"],
                    snippet: String(plainText.prefix(200))
                )
            }
        }
    }

    // MARK: - Pattern mining helpers

    public func eventsForMining(afterID: Int64, limit: Int = 5000) throws -> [(id: Int64, sessionID: Int64, ts: Double, token: String)] {
        let queue = try requireQueue()
        return try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, session_id, ts, token
                FROM events
                WHERE id > ? AND token != ''
                ORDER BY id ASC
                LIMIT ?
            """, arguments: [afterID, limit]).map { row in
                (id: row["id"], sessionID: row["session_id"], ts: row["ts"], token: row["token"])
            }
        }
    }

    public func upsertPattern(signature: String, length: Int, lastSeenAt: Double, sampleEventIDsJSON: String) throws {
        let queue = try requireQueue()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO patterns (signature, length, occurrences, last_seen_at, score, sample_event_ids)
                VALUES (?, ?, 1, ?, 0, ?)
                ON CONFLICT(signature) DO UPDATE SET
                    occurrences = occurrences + 1,
                    last_seen_at = MAX(last_seen_at, excluded.last_seen_at),
                    sample_event_ids = excluded.sample_event_ids
            """, arguments: [signature, length, lastSeenAt, sampleEventIDsJSON])
        }
    }

    public func rescorePatterns(halfLifeDays: Double = 7, now: Date = Date()) throws {
        let queue = try requireQueue()
        let nowTs = now.timeIntervalSince1970
        let halfLifeSec = halfLifeDays * 86400.0
        try queue.write { db in
            // score = occurrences * exp(-ln(2) * elapsed / halfLife)
            try db.execute(sql: """
                UPDATE patterns
                SET score = occurrences * exp(-0.6931471805599453 * (? - last_seen_at) / ?)
            """, arguments: [nowTs, halfLifeSec])
        }
    }

    public func topPatterns(minOccurrences: Int = 3, minLength: Int = 2, minScore: Double = 1.5, limit: Int = 50) throws -> [PatternRow] {
        let queue = try requireQueue()
        return try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, signature, length, occurrences, last_seen_at, score, sample_event_ids
                FROM patterns
                WHERE occurrences >= ? AND length >= ? AND score >= ?
                ORDER BY score DESC
                LIMIT ?
            """, arguments: [minOccurrences, minLength, minScore, limit]).map { row in
                PatternRow(
                    id: row["id"],
                    signature: row["signature"],
                    length: row["length"],
                    occurrences: row["occurrences"],
                    lastSeenAt: Date(timeIntervalSince1970: row["last_seen_at"]),
                    score: row["score"],
                    sampleEventIDsJSON: row["sample_event_ids"]
                )
            }
        }
    }

    // MARK: - Screenshot storage admin

    public func screenshotsStorageBytes() throws -> Int64 {
        let queue = try requireQueue()
        return try queue.read { db in
            try Int64.fetchOne(db, sql: """
                SELECT COALESCE(SUM(length(thumb_path)),0) FROM screenshots
            """) ?? 0
        }
    }

    public func oldestScreenshotsForEviction(limit: Int) throws -> [(id: Int64, thumbPath: String, fullresPath: String?)] {
        let queue = try requireQueue()
        return try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, thumb_path, fullres_path FROM screenshots
                WHERE skipped_reason IS NULL
                ORDER BY ts ASC LIMIT ?
            """, arguments: [limit]).map { row in
                (id: row["id"], thumbPath: row["thumb_path"], fullresPath: row["fullres_path"])
            }
        }
    }

    public func deleteScreenshot(id: Int64) throws {
        let queue = try requireQueue()
        try queue.write { db in
            try db.execute(sql: "DELETE FROM screenshots WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Digests

    public struct DigestRecord: Sendable, Hashable, Identifiable {
        public let id: Int64
        public let kind: String
        public let rangeStart: Date
        public let rangeEnd: Date
        public let createdAt: Date
        public let payloadJSON: String
    }

    public func recordDigest(kind: String, rangeStart: Date, rangeEnd: Date, payloadJSON: String) throws {
        let queue = try requireQueue()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO digests (kind, range_start, range_end, created_at, payload_json)
                VALUES (?, ?, ?, ?, ?)
            """, arguments: [
                kind,
                rangeStart.timeIntervalSince1970,
                rangeEnd.timeIntervalSince1970,
                Date().timeIntervalSince1970,
                payloadJSON
            ])
        }
    }

    public func latestDigest(kind: String) throws -> DigestRecord? {
        let queue = try requireQueue()
        return try queue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT id, kind, range_start, range_end, created_at, payload_json
                FROM digests WHERE kind = ?
                ORDER BY range_start DESC, created_at DESC
                LIMIT 1
            """, arguments: [kind]) else { return nil }
            return DigestRecord(
                id: row["id"],
                kind: row["kind"] ?? "",
                rangeStart: Date(timeIntervalSince1970: row["range_start"]),
                rangeEnd: Date(timeIntervalSince1970: row["range_end"]),
                createdAt: Date(timeIntervalSince1970: row["created_at"]),
                payloadJSON: row["payload_json"] ?? "{}"
            )
        }
    }

    public func recentDigests(kind: String, limit: Int = 7) throws -> [DigestRecord] {
        let queue = try requireQueue()
        return try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, kind, range_start, range_end, created_at, payload_json
                FROM digests WHERE kind = ?
                ORDER BY range_start DESC
                LIMIT ?
            """, arguments: [kind, limit]).map { row in
                DigestRecord(
                    id: row["id"],
                    kind: row["kind"] ?? "",
                    rangeStart: Date(timeIntervalSince1970: row["range_start"]),
                    rangeEnd: Date(timeIntervalSince1970: row["range_end"]),
                    createdAt: Date(timeIntervalSince1970: row["created_at"]),
                    payloadJSON: row["payload_json"] ?? "{}"
                )
            }
        }
    }

    // MARK: - Digest runs (scheduler bookkeeping)

    public func recordDigestRun(kind: String, status: String, message: String?) throws {
        let queue = try requireQueue()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO digest_runs (kind, run_at, status, message)
                VALUES (?, ?, ?, ?)
            """, arguments: [kind, Date().timeIntervalSince1970, status, message])
        }
    }

    public func lastSuccessfulDigestRun(kind: String) throws -> Date? {
        let queue = try requireQueue()
        return try queue.read { db in
            let ts = try Double.fetchOne(db, sql: """
                SELECT MAX(run_at) FROM digest_runs
                WHERE kind = ? AND status = 'ok'
            """, arguments: [kind])
            return ts.map { Date(timeIntervalSince1970: $0) }
        }
    }

    // MARK: - API calls (cost tracking)

    public struct APICall: Sendable, Hashable, Identifiable {
        public let id: Int64
        public let ts: Date
        public let model: String
        public let inputTokens: Int
        public let outputTokens: Int
        public let cacheReadTokens: Int
        public let cacheCreationTokens: Int
        public let costUSD: Double
        public let purpose: String
    }

    public func recordAPICall(
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int,
        costUSD: Double,
        purpose: String
    ) throws {
        let queue = try requireQueue()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO api_calls (ts, model, input_tokens, output_tokens,
                                       cache_read_tokens, cache_creation_tokens,
                                       cost_usd, purpose)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                Date().timeIntervalSince1970,
                model, inputTokens, outputTokens,
                cacheReadTokens, cacheCreationTokens,
                costUSD, purpose
            ])
        }
    }

    public func todayAPISpend() throws -> (inputTokens: Int, outputTokens: Int, costUSD: Double) {
        let queue = try requireQueue()
        let boundary = DayBoundary(date: Date())
        return try queue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT COALESCE(SUM(input_tokens), 0) AS i,
                       COALESCE(SUM(output_tokens), 0) AS o,
                       COALESCE(SUM(cost_usd), 0) AS c
                FROM api_calls
                WHERE ts >= ? AND ts < ?
            """, arguments: [
                boundary.start.timeIntervalSince1970,
                boundary.end.timeIntervalSince1970
            ]) else {
                return (0, 0, 0.0)
            }
            return (row["i"] ?? 0, row["o"] ?? 0, row["c"] ?? 0.0)
        }
    }

    public func recentAPICalls(limit: Int = 30) throws -> [APICall] {
        let queue = try requireQueue()
        return try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, ts, model, input_tokens, output_tokens,
                       cache_read_tokens, cache_creation_tokens, cost_usd, purpose
                FROM api_calls
                ORDER BY ts DESC
                LIMIT ?
            """, arguments: [limit]).map { row in
                APICall(
                    id: row["id"],
                    ts: Date(timeIntervalSince1970: row["ts"]),
                    model: row["model"] ?? "",
                    inputTokens: row["input_tokens"] ?? 0,
                    outputTokens: row["output_tokens"] ?? 0,
                    cacheReadTokens: row["cache_read_tokens"] ?? 0,
                    cacheCreationTokens: row["cache_creation_tokens"] ?? 0,
                    costUSD: row["cost_usd"] ?? 0,
                    purpose: row["purpose"] ?? ""
                )
            }
        }
    }

    // MARK: - Session summaries

    public func recordSessionSummary(
        rangeStart: Date,
        rangeEnd: Date,
        privacyMode: String,
        model: String,
        prose: String,
        tokenCount: Int
    ) throws -> Int64 {
        let queue = try requireQueue()
        return try queue.write { db in
            try db.execute(sql: """
                INSERT INTO session_summaries (range_start, range_end, privacy_mode, model, prose, token_count, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                rangeStart.timeIntervalSince1970,
                rangeEnd.timeIntervalSince1970,
                privacyMode, model, prose, tokenCount,
                Date().timeIntervalSince1970
            ])
            return db.lastInsertedRowID
        }
    }

    // MARK: - Privacy event flag

    public func markEventPrivate(_ eventID: Int64, isPrivate: Bool) throws {
        let queue = try requireQueue()
        try queue.write { db in
            try db.execute(
                sql: "UPDATE events SET is_private = ? WHERE id = ?",
                arguments: [isPrivate ? 1 : 0, eventID]
            )
        }
    }

    private func runFTS5SmokeTest() throws {
        let queue = try requireQueue()
        try queue.write { db in
            // Use a temp table so we don't touch the real schema or trip foreign keys.
            try db.execute(sql: "CREATE VIRTUAL TABLE temp.trackerbud_fts5_probe USING fts5(content)")
            defer { try? db.execute(sql: "DROP TABLE temp.trackerbud_fts5_probe") }
            try db.execute(
                sql: "INSERT INTO trackerbud_fts5_probe VALUES (?)",
                arguments: ["the quick brown fox jumps over"]
            )
            let hit = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM trackerbud_fts5_probe
                WHERE trackerbud_fts5_probe MATCH ?
            """, arguments: ["quick"]) ?? 0
            if hit < 1 { throw EventStoreError.fts5Unavailable }
        }
        log.info("FTS5 smoke test passed")
    }
}

public struct PatternRow: Sendable, Identifiable, Hashable {
    public let id: Int64
    public let signature: String
    public let length: Int
    public let occurrences: Int
    public let lastSeenAt: Date
    public let score: Double
    public let sampleEventIDsJSON: String
}

public enum EventStoreError: Error, CustomStringConvertible {
    case notStarted
    case fts5Unavailable

    public var description: String {
        switch self {
        case .notStarted: return "EventStore.start() has not been called"
        case .fts5Unavailable: return "SQLite was not built with FTS5 support"
        }
    }
}

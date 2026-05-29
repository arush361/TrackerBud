import Foundation
import GRDB

public enum Schema {
    public static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1.initial") { db in
            try db.create(table: "sessions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("started_at", .double).notNull()
                t.column("ended_at", .double)
                t.column("device_state", .text).notNull().defaults(to: "active")
            }
            try db.create(index: "idx_sessions_started", on: "sessions", columns: ["started_at"])

            try db.create(table: "events") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("ts", .double).notNull()
                t.column("session_id", .integer).notNull().references("sessions", onDelete: .cascade)
                t.column("source", .text).notNull()
                t.column("type", .text).notNull()
                t.column("token", .text).notNull()
                t.column("payload_json", .text).notNull().defaults(to: "{}")
                t.column("duration_ms", .integer)
            }
            try db.create(index: "idx_events_ts", on: "events", columns: ["ts"])
            try db.create(index: "idx_events_session", on: "events", columns: ["session_id", "ts"])
            try db.create(index: "idx_events_source_type", on: "events", columns: ["source", "type", "ts"])
            try db.create(index: "idx_events_token", on: "events", columns: ["token"])

            try db.create(table: "app_events") { t in
                t.column("event_id", .integer).primaryKey().references("events", onDelete: .cascade)
                t.column("bundle_id", .text).notNull()
                t.column("app_name", .text).notNull()
                t.column("window_title", .text)
                t.column("pid", .integer)
            }
            try db.create(index: "idx_app_events_bundle", on: "app_events", columns: ["bundle_id"])

            // Browser, file, input details — created in later milestones but schema reserved now
            try db.create(table: "browser_events") { t in
                t.column("event_id", .integer).primaryKey().references("events", onDelete: .cascade)
                t.column("browser", .text).notNull()
                t.column("url", .text).notNull()
                t.column("url_host", .text).notNull()
                t.column("url_path", .text)
                t.column("page_title", .text)
            }
            try db.create(index: "idx_browser_host", on: "browser_events", columns: ["url_host"])

            try db.create(table: "file_events") { t in
                t.column("event_id", .integer).primaryKey().references("events", onDelete: .cascade)
                t.column("path", .text).notNull()
                t.column("action", .text).notNull()
                t.column("inode", .integer)
                t.column("file_ext", .text)
            }
            try db.create(index: "idx_file_events_path", on: "file_events", columns: ["path"])

            try db.create(table: "input_events") { t in
                t.column("event_id", .integer).primaryKey().references("events", onDelete: .cascade)
                t.column("modifiers", .integer).notNull()
                t.column("key_code", .integer).notNull()
                t.column("key_char", .text)
            }

            try db.create(table: "clipboard_items") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("event_id", .integer).notNull().references("events", onDelete: .cascade)
                t.column("ts", .double).notNull()
                t.column("kind", .text).notNull()
                t.column("text_content", .text)
                t.column("byte_size", .integer)
                t.column("source_app", .text)
            }
            try db.execute(sql: """
                CREATE VIRTUAL TABLE clipboard_fts USING fts5(
                    text_content,
                    content='clipboard_items',
                    content_rowid='id'
                )
            """)

            try db.create(table: "screenshots") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("ts", .double).notNull()
                t.column("display_id", .integer)
                t.column("frontmost_bundle", .text)
                t.column("thumb_path", .text).notNull()
                t.column("fullres_path", .text)
                t.column("perceptual_hash", .integer)
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("skipped_reason", .text)
            }
            try db.create(index: "idx_screenshots_ts", on: "screenshots", columns: ["ts"])
            try db.create(index: "idx_screenshots_phash", on: "screenshots", columns: ["perceptual_hash"])

            try db.create(table: "ocr_blocks") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("screenshot_id", .integer).notNull().references("screenshots", onDelete: .cascade)
                t.column("text", .text).notNull()
                t.column("bbox_x", .double)
                t.column("bbox_y", .double)
                t.column("bbox_w", .double)
                t.column("bbox_h", .double)
                t.column("confidence", .double)
            }
            try db.execute(sql: """
                CREATE VIRTUAL TABLE ocr_fts USING fts5(
                    text,
                    content='ocr_blocks',
                    content_rowid='id'
                )
            """)

            try db.create(table: "patterns") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("signature", .text).notNull().unique()
                t.column("length", .integer).notNull()
                t.column("occurrences", .integer).notNull().defaults(to: 0)
                t.column("last_seen_at", .double).notNull()
                t.column("score", .double).notNull().defaults(to: 0)
                t.column("sample_event_ids", .text).notNull().defaults(to: "[]")
            }
            try db.create(index: "idx_patterns_score", on: "patterns", columns: ["score"])

            try db.create(table: "privacy_rules") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("bundle_id", .text)
                t.column("url_pattern", .text)
                t.column("action", .text).notNull()
                t.column("created_at", .double).notNull()
            }
        }

        return migrator
    }
}

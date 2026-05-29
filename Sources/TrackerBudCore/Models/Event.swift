import Foundation
import GRDB

public enum EventSource: String, Codable, Sendable {
    case app
    case browser
    case file
    case input
    case clipboard
    case screen
}

public struct Event: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public var id: Int64?
    public var ts: Double
    public var sessionId: Int64
    public var source: String
    public var type: String
    public var token: String
    public var payloadJSON: String
    public var durationMs: Int64?

    public init(
        id: Int64? = nil,
        ts: Double,
        sessionId: Int64,
        source: EventSource,
        type: String,
        token: String,
        payloadJSON: String,
        durationMs: Int64? = nil
    ) {
        self.id = id
        self.ts = ts
        self.sessionId = sessionId
        self.source = source.rawValue
        self.type = type
        self.token = token
        self.payloadJSON = payloadJSON
        self.durationMs = durationMs
    }

    public static let databaseTableName = "events"

    public enum Columns {
        public static let id = Column("id")
        public static let ts = Column("ts")
        public static let sessionId = Column("session_id")
        public static let source = Column("source")
        public static let type = Column("type")
        public static let token = Column("token")
        public static let payloadJSON = Column("payload_json")
        public static let durationMs = Column("duration_ms")
    }

    enum CodingKeys: String, CodingKey {
        case id
        case ts
        case sessionId = "session_id"
        case source
        case type
        case token
        case payloadJSON = "payload_json"
        case durationMs = "duration_ms"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct AppEventDetail: Codable, FetchableRecord, PersistableRecord, Sendable {
    public var eventId: Int64
    public var bundleId: String
    public var appName: String
    public var windowTitle: String?
    public var pid: Int32?

    public init(eventId: Int64, bundleId: String, appName: String, windowTitle: String?, pid: Int32?) {
        self.eventId = eventId
        self.bundleId = bundleId
        self.appName = appName
        self.windowTitle = windowTitle
        self.pid = pid
    }

    public static let databaseTableName = "app_events"

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case bundleId = "bundle_id"
        case appName = "app_name"
        case windowTitle = "window_title"
        case pid
    }
}

public struct Session: Codable, FetchableRecord, PersistableRecord, Sendable {
    public var id: Int64?
    public var startedAt: Double
    public var endedAt: Double?
    public var deviceState: String

    public init(id: Int64? = nil, startedAt: Double, endedAt: Double? = nil, deviceState: String = "active") {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.deviceState = deviceState
    }

    public static let databaseTableName = "sessions"

    enum CodingKeys: String, CodingKey {
        case id
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case deviceState = "device_state"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Hydrated view-model that joins an Event with its source-specific detail
/// tables. Sensitive fields are decrypted before they reach this struct.
public struct EventRow: Sendable, Identifiable, Hashable {
    public let id: Int64
    public let ts: Date
    public let source: EventSource
    public let type: String
    public let token: String
    public let appName: String?
    public let bundleId: String?
    /// Primary descriptor: window title / page title / file leaf / key combo / clipboard preview.
    public let primaryText: String?
    /// Secondary descriptor: host / file action / etc.
    public let secondaryText: String?

    public init(
        id: Int64,
        ts: Date,
        source: EventSource,
        type: String,
        token: String,
        appName: String?,
        bundleId: String?,
        primaryText: String?,
        secondaryText: String?
    ) {
        self.id = id
        self.ts = ts
        self.source = source
        self.type = type
        self.token = token
        self.appName = appName
        self.bundleId = bundleId
        self.primaryText = primaryText
        self.secondaryText = secondaryText
    }
}

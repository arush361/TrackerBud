import Foundation
import TrackerBudCore

/// Convenience wrapper that combines TrackerBud event-log durations with
/// cached Apple Screen Time numbers for the same day, so the UI can show a
/// "ours / Apple" comparison without repeated DB roundtrips.
public final class TimeAnalyzer: Sendable {
    public static let shared = TimeAnalyzer()
    public init() {}

    public struct AppRow: Sendable, Hashable, Identifiable {
        public let bundleID: String
        public let appName: String?
        public let ourSeconds: Int
        public let appleSeconds: Int?
        public var id: String { bundleID }

        public var displayName: String {
            if let n = appName, !n.isEmpty { return n }
            // Pretty fallback: last segment of bundle ID
            return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        }

        /// Returns Apple-vs-ours delta as a positive/negative seconds value
        public var delta: Int? {
            guard let apple = appleSeconds else { return nil }
            return apple - ourSeconds
        }
    }

    public struct SiteRow: Sendable, Hashable, Identifiable {
        public let host: String
        public let seconds: Int
        public var id: String { host }
    }

    public func appRows(for date: Date) throws -> [AppRow] {
        let ours = try EventStore.shared.appTimeSpent(date: date)
        let iso = ScreenTimeISO.day(from: date)
        let apple = (try? EventStore.shared.screenTimeForDate(iso)) ?? []
        var appleByBundle: [String: Int] = [:]
        for r in apple { appleByBundle[r.bundleID] = r.seconds }

        // Union of bundles seen in either source
        var seen = Set<String>()
        var rows: [AppRow] = []
        for r in ours {
            seen.insert(r.bundleID)
            rows.append(AppRow(
                bundleID: r.bundleID,
                appName: r.appName,
                ourSeconds: r.seconds,
                appleSeconds: appleByBundle[r.bundleID]
            ))
        }
        for r in apple where !seen.contains(r.bundleID) {
            rows.append(AppRow(
                bundleID: r.bundleID,
                appName: nil,
                ourSeconds: 0,
                appleSeconds: r.seconds
            ))
        }
        // Sort by max(ours, apple) descending
        return rows.sorted { lhs, rhs in
            max(lhs.ourSeconds, lhs.appleSeconds ?? 0) > max(rhs.ourSeconds, rhs.appleSeconds ?? 0)
        }
    }

    public func siteRows(for date: Date) throws -> [SiteRow] {
        let raw = try EventStore.shared.siteTimeSpent(date: date)
        return raw.map { SiteRow(host: $0.host, seconds: $0.seconds) }
    }

    public func totalActiveSeconds(for date: Date) throws -> Int {
        try EventStore.shared.totalActiveSeconds(date: date)
    }

    public static func formatDuration(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 {
            let m = seconds / 60
            let s = seconds % 60
            return s == 0 ? "\(m)m" : "\(m)m \(s)s"
        }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}

public enum ScreenTimeISO {
    public static func day(from date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

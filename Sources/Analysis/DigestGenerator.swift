import Foundation
import TrackerBudCore

public struct Digest: Sendable, Codable, Hashable {
    public let kind: Kind
    public let rangeStart: Date
    public let rangeEnd: Date
    public let appTime: [AppEntry]
    public let siteTime: [SiteEntry]
    public let totalActiveMinutes: Int
    public let topPatterns: [PatternEntry]
    public let newPatternsThisWeek: [PatternEntry]
    public let anomalies: [AnomalyEntry]

    public enum Kind: String, Sendable, Codable { case daily, weekly }

    public struct AppEntry: Sendable, Codable, Hashable {
        public let bundleID: String
        public let appName: String?
        public let seconds: Int
    }
    public struct SiteEntry: Sendable, Codable, Hashable {
        public let host: String
        public let seconds: Int
    }
    public struct PatternEntry: Sendable, Codable, Hashable {
        public let signature: String
        public let length: Int
        public let occurrences: Int
        public let score: Double
    }
    public struct AnomalyEntry: Sendable, Codable, Hashable {
        public let bundleID: String
        public let appName: String?
        public let observedSeconds: Int
        public let medianSeconds: Int
        public let ratio: Double
        public let severity: String
    }
}

/// Rule-based daily/weekly summary builder. No LLM here — M9 adds prose
/// summarization on top of this structured payload.
public final class DigestGenerator: Sendable {
    public static let shared = DigestGenerator()
    public init() {}

    public func generateDaily(for date: Date) throws -> Digest {
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? date

        let appRows = try TimeAnalyzer.shared.appRows(for: date)
        let siteRows = try TimeAnalyzer.shared.siteRows(for: date)
        let totalSeconds = try TimeAnalyzer.shared.totalActiveSeconds(for: date)
        let anomalies = (try? AnomalyDetector.shared.anomalies(for: date)) ?? []

        let topPatterns = (try? EventStore.shared.topPatterns(limit: 10)) ?? []
        let newPatterns = (try? newThisWeek(patterns: topPatterns)) ?? []

        return Digest(
            kind: .daily,
            rangeStart: start,
            rangeEnd: end,
            appTime: Array(appRows.prefix(15)).map {
                .init(bundleID: $0.bundleID, appName: $0.appName, seconds: $0.ourSeconds)
            },
            siteTime: Array(siteRows.prefix(15)).map {
                .init(host: $0.host, seconds: $0.seconds)
            },
            totalActiveMinutes: totalSeconds / 60,
            topPatterns: topPatterns.map {
                .init(signature: $0.signature, length: $0.length, occurrences: $0.occurrences, score: $0.score)
            },
            newPatternsThisWeek: newPatterns.map {
                .init(signature: $0.signature, length: $0.length, occurrences: $0.occurrences, score: $0.score)
            },
            anomalies: anomalies.map {
                .init(
                    bundleID: $0.bundleID,
                    appName: $0.appName,
                    observedSeconds: $0.observedSeconds,
                    medianSeconds: $0.medianSeconds,
                    ratio: $0.ratio,
                    severity: $0.severity.rawValue
                )
            }
        )
    }

    public func generateWeekly(endingOn date: Date) throws -> Digest {
        let cal = Calendar.current
        let endDay = cal.startOfDay(for: date)
        let startDay = cal.date(byAdding: .day, value: -6, to: endDay) ?? endDay
        let end = cal.date(byAdding: .day, value: 1, to: endDay) ?? endDay

        // Aggregate across 7 days
        var appTotals: [String: (name: String?, secs: Int)] = [:]
        var siteTotals: [String: Int] = [:]
        var totalSeconds = 0
        for offset in 0..<7 {
            guard let d = cal.date(byAdding: .day, value: -offset, to: endDay) else { continue }
            let apps = try TimeAnalyzer.shared.appRows(for: d)
            for a in apps {
                let existing = appTotals[a.bundleID]?.secs ?? 0
                appTotals[a.bundleID] = (a.appName ?? appTotals[a.bundleID]?.name, existing + a.ourSeconds)
            }
            let sites = try TimeAnalyzer.shared.siteRows(for: d)
            for s in sites {
                siteTotals[s.host, default: 0] += s.seconds
            }
            totalSeconds += try TimeAnalyzer.shared.totalActiveSeconds(for: d)
        }

        let topApps = appTotals
            .map { Digest.AppEntry(bundleID: $0.key, appName: $0.value.name, seconds: $0.value.secs) }
            .sorted { $0.seconds > $1.seconds }
            .prefix(20)
        let topSites = siteTotals
            .map { Digest.SiteEntry(host: $0.key, seconds: $0.value) }
            .sorted { $0.seconds > $1.seconds }
            .prefix(20)

        let patterns = (try? EventStore.shared.topPatterns(limit: 15)) ?? []
        let newPatterns = (try? newThisWeek(patterns: patterns)) ?? []

        return Digest(
            kind: .weekly,
            rangeStart: startDay,
            rangeEnd: end,
            appTime: Array(topApps),
            siteTime: Array(topSites),
            totalActiveMinutes: totalSeconds / 60,
            topPatterns: patterns.map {
                .init(signature: $0.signature, length: $0.length, occurrences: $0.occurrences, score: $0.score)
            },
            newPatternsThisWeek: newPatterns.map {
                .init(signature: $0.signature, length: $0.length, occurrences: $0.occurrences, score: $0.score)
            },
            anomalies: []
        )
    }

    private func newThisWeek(patterns: [PatternRow]) throws -> [PatternRow] {
        let cal = Calendar.current
        guard let weekAgo = cal.date(byAdding: .day, value: -7, to: Date()) else { return [] }
        return patterns.filter { $0.lastSeenAt > weekAgo && $0.occurrences <= 5 }
    }

    public func persist(_ digest: Digest) throws {
        let json = try JSONEncoder().encode(digest)
        let jsonStr = String(data: json, encoding: .utf8) ?? "{}"
        try EventStore.shared.recordDigest(
            kind: digest.kind.rawValue,
            rangeStart: digest.rangeStart,
            rangeEnd: digest.rangeEnd,
            payloadJSON: jsonStr
        )
    }
}

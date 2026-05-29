import Foundation
import TrackerBudCore

/// Median-absolute-deviation based anomaly detection. For each app and a given
/// date, compare today's time-spent against the median time-spent for that
/// same day-of-week over the last N weeks. Flag if (observed - median) / MAD
/// exceeds threshold.
public final class AnomalyDetector: Sendable {
    public static let shared = AnomalyDetector()
    public init() {}

    public struct Anomaly: Sendable, Hashable, Identifiable {
        public let bundleID: String
        public let appName: String?
        public let observedSeconds: Int
        public let medianSeconds: Int
        public let ratio: Double
        public let severity: Severity
        public var id: String { bundleID }

        public enum Severity: String, Sendable {
            case low, medium, high
        }
    }

    public func anomalies(for date: Date, lookbackWeeks: Int = 4) throws -> [Anomaly] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: date)
        let weekday = cal.component(.weekday, from: today)

        // Gather time-spent for the same weekday across N prior weeks (exclude `today` itself).
        var samples: [String: [Int]] = [:]   // bundleID → [secs]
        var appNames: [String: String?] = [:]
        for w in 1...lookbackWeeks {
            guard let priorDay = cal.date(byAdding: .day, value: -7 * w, to: today) else { continue }
            let rows = (try? EventStore.shared.appTimeSpent(date: priorDay)) ?? []
            for r in rows {
                samples[r.bundleID, default: []].append(r.seconds)
                appNames[r.bundleID] = r.appName
            }
        }

        let todayRows = (try? EventStore.shared.appTimeSpent(date: today)) ?? []
        var results: [Anomaly] = []

        for r in todayRows {
            let sample = samples[r.bundleID] ?? []
            // Need at least 2 historical samples to compute a meaningful baseline
            guard sample.count >= 2 else { continue }
            let med = median(sample)
            let mad = max(1, medianAbsoluteDeviation(sample, median: med))
            let deviation = abs(Double(r.seconds) - Double(med)) / Double(mad)
            // Only surface as anomaly if a notable absolute swing too — ignore
            // "5s today vs 3s usual" noise
            let absoluteSwing = abs(r.seconds - med)
            guard deviation > 2.5, absoluteSwing > 60 else { continue }

            let ratio = med == 0 ? 0 : Double(r.seconds) / Double(med)
            let severity: Anomaly.Severity
            if deviation > 6 { severity = .high }
            else if deviation > 4 { severity = .medium }
            else { severity = .low }

            results.append(Anomaly(
                bundleID: r.bundleID,
                appName: appNames[r.bundleID] ?? nil,
                observedSeconds: r.seconds,
                medianSeconds: med,
                ratio: ratio,
                severity: severity
            ))
            _ = weekday
        }
        return results.sorted { $0.ratio > $1.ratio }
    }

    private func median(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    private func medianAbsoluteDeviation(_ values: [Int], median m: Int) -> Int {
        let deviations = values.map { abs($0 - m) }
        return median(deviations)
    }
}

import Foundation
import TrackerBudCore
import OSLog

/// Sessionized n-gram miner over normalized event tokens.
/// - n ∈ {2,3,4,5}
/// - Consecutive duplicate tokens collapsed
/// - Sessions break on 5-minute idle gaps
/// - Recency-weighted scoring with 7-day half-life
public final class PatternMiner: @unchecked Sendable {
    public static let shared = PatternMiner()

    private let lock = NSLock()
    private var lastProcessedID: Int64 = UserDefaults.standard.object(forKey: "TrackerBud.lastMinedID") as? Int64 ?? 0
    private var runTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.arushsharma.trackerbud", category: "PatternMiner")
    private let idleGapSeconds: Double = 5 * 60

    public init() {}

    public func startBackgroundRefresh(intervalSeconds: TimeInterval = 5 * 60) {
        runTask?.cancel()
        runTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.runIncremental()
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
            }
        }
    }

    public func stopBackgroundRefresh() {
        runTask?.cancel()
        runTask = nil
    }

    public func runIncremental() {
        lock.lock()
        let startID = lastProcessedID
        lock.unlock()

        let events: [(id: Int64, sessionID: Int64, ts: Double, token: String)]
        do {
            events = try EventStore.shared.eventsForMining(afterID: startID)
        } catch {
            log.error("Mining fetch failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        if events.isEmpty { return }

        // Group by session
        var bySession: [Int64: [(id: Int64, ts: Double, token: String)]] = [:]
        for e in events {
            bySession[e.sessionID, default: []].append((id: e.id, ts: e.ts, token: e.token))
        }

        var newSignatures = 0
        for (_, items) in bySession {
            // Already ordered by id ASC due to query.
            // Collapse consecutive duplicate tokens.
            var collapsed: [(id: Int64, ts: Double, token: String)] = []
            var prevToken: String? = nil
            for item in items {
                if item.token != prevToken {
                    collapsed.append(item)
                    prevToken = item.token
                }
            }
            // Slide n=2..5
            for n in 2...5 where collapsed.count >= n {
                for i in 0...(collapsed.count - n) {
                    let window = collapsed[i..<(i + n)]
                    let signature = window.map { $0.token }.joined(separator: "|")
                    let lastSeen = window.last!.ts
                    let sampleIDs = window.map { $0.id }
                    let json = (try? String(
                        data: JSONSerialization.data(withJSONObject: sampleIDs, options: []),
                        encoding: .utf8
                    )) ?? "[]"
                    do {
                        try EventStore.shared.upsertPattern(
                            signature: signature,
                            length: n,
                            lastSeenAt: lastSeen,
                            sampleEventIDsJSON: json
                        )
                        newSignatures += 1
                    } catch {
                        log.error("Pattern upsert failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }

        do {
            try EventStore.shared.rescorePatterns()
        } catch {
            log.error("Rescore failed: \(error.localizedDescription, privacy: .public)")
        }

        let maxID = events.last!.id
        lock.lock()
        lastProcessedID = maxID
        lock.unlock()
        UserDefaults.standard.set(maxID, forKey: "TrackerBud.lastMinedID")
        log.info("Mining pass: \(events.count, privacy: .public) events, \(newSignatures, privacy: .public) signatures, lastID=\(maxID, privacy: .public)")
    }

    public func rebuildAll() throws {
        lock.lock()
        lastProcessedID = 0
        lock.unlock()
        UserDefaults.standard.set(0, forKey: "TrackerBud.lastMinedID")
        runIncremental()
    }
}

import Foundation
import TrackerBudCore
import OSLog

/// Background scheduler that periodically checks whether a daily or weekly
/// digest is due, generates it, persists it, and dispatches to enabled
/// delivery channels (in-app, notifications, markdown export).
public final class DigestScheduler: @unchecked Sendable {
    public static let shared = DigestScheduler()

    public struct Settings: Sendable {
        public var dailyEnabled: Bool
        public var weeklyEnabled: Bool
        public var dailyHour: Int      // 0..23 local hour
        public var weeklyDay: Int      // 1=Sun ... 7=Sat
        public var notificationsEnabled: Bool
        public var markdownExportEnabled: Bool

        public static let defaults = Settings(
            dailyEnabled: true,
            weeklyEnabled: true,
            dailyHour: 21,
            weeklyDay: 1,
            notificationsEnabled: true,
            markdownExportEnabled: true
        )
    }

    private let lock = NSLock()
    private var runTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.arushsharma.trackerbud", category: "DigestScheduler")
    private let checkInterval: TimeInterval = 30 * 60   // 30 minutes

    public init() {}

    public func startBackgroundLoop() {
        lock.lock()
        runTask?.cancel()
        runTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            // First tick at +60s so first launch doesn't fire immediately
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            while !Task.isCancelled {
                self.tick()
                try? await Task.sleep(nanoseconds: UInt64(self.checkInterval * 1_000_000_000))
            }
        }
        lock.unlock()
    }

    public func stopBackgroundLoop() {
        lock.lock()
        runTask?.cancel()
        runTask = nil
        lock.unlock()
    }

    public static func loadSettings() -> Settings {
        let d = UserDefaults.standard
        guard d.bool(forKey: "TrackerBud.digestSettingsSet") else { return .defaults }
        return Settings(
            dailyEnabled: d.bool(forKey: "TrackerBud.digestDailyEnabled"),
            weeklyEnabled: d.bool(forKey: "TrackerBud.digestWeeklyEnabled"),
            dailyHour: d.integer(forKey: "TrackerBud.digestDailyHour"),
            weeklyDay: max(1, d.integer(forKey: "TrackerBud.digestWeeklyDay")),
            notificationsEnabled: d.bool(forKey: "TrackerBud.digestNotificationsEnabled"),
            markdownExportEnabled: d.bool(forKey: "TrackerBud.digestMarkdownEnabled")
        )
    }

    public static func saveSettings(_ s: Settings) {
        let d = UserDefaults.standard
        d.set(true, forKey: "TrackerBud.digestSettingsSet")
        d.set(s.dailyEnabled, forKey: "TrackerBud.digestDailyEnabled")
        d.set(s.weeklyEnabled, forKey: "TrackerBud.digestWeeklyEnabled")
        d.set(s.dailyHour, forKey: "TrackerBud.digestDailyHour")
        d.set(s.weeklyDay, forKey: "TrackerBud.digestWeeklyDay")
        d.set(s.notificationsEnabled, forKey: "TrackerBud.digestNotificationsEnabled")
        d.set(s.markdownExportEnabled, forKey: "TrackerBud.digestMarkdownEnabled")
    }

    public func runNow(kind: Digest.Kind) async {
        let settings = Self.loadSettings()
        await fire(kind: kind, settings: settings, forceMarkdown: true, forceNotification: false)
    }

    private func tick() {
        let settings = Self.loadSettings()
        let cal = Calendar.current
        let now = Date()

        if settings.dailyEnabled && isPastDailyHour(now: now, hour: settings.dailyHour) {
            // Generate "today's" digest (or yesterday if past midnight by an hour)
            let target = cal.startOfDay(for: now)
            let lastRun = (try? EventStore.shared.lastSuccessfulDigestRun(kind: "daily")) ?? .distantPast
            if cal.startOfDay(for: lastRun) < target {
                Task { await self.fire(kind: .daily, settings: settings) }
            }
        }

        if settings.weeklyEnabled && cal.component(.weekday, from: now) == settings.weeklyDay {
            // Generate weekly digest covering the past 7 days ending today
            let lastRun = (try? EventStore.shared.lastSuccessfulDigestRun(kind: "weekly")) ?? .distantPast
            if cal.startOfDay(for: lastRun) < cal.startOfDay(for: now) {
                Task { await self.fire(kind: .weekly, settings: settings) }
            }
        }
    }

    private func isPastDailyHour(now: Date, hour: Int) -> Bool {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: now)
        return (comps.hour ?? 0) >= hour
    }

    private func fire(kind: Digest.Kind, settings: Settings, forceMarkdown: Bool = false, forceNotification: Bool = false) async {
        do {
            let digest: Digest
            switch kind {
            case .daily:  digest = try DigestGenerator.shared.generateDaily(for: Date())
            case .weekly: digest = try DigestGenerator.shared.generateWeekly(endingOn: Date())
            }
            try DigestGenerator.shared.persist(digest)
            try EventStore.shared.recordDigestRun(
                kind: kind.rawValue, status: "ok",
                message: "\(digest.appTime.count) apps, \(digest.topPatterns.count) patterns"
            )

            // Markdown
            if settings.markdownExportEnabled || forceMarkdown {
                let prose = renderMarkdown(digest)
                _ = try? MarkdownExporter.shared.writeDailyMarkdown(
                    prose: prose, day: digest.rangeStart
                )
            }

            // Notification
            if settings.notificationsEnabled || forceNotification {
                let title = kind == .daily ? "Daily digest ready" : "Weekly digest ready"
                let body = "\(digest.totalActiveMinutes) min active across \(digest.appTime.count) apps. \(digest.anomalies.count) anomalies."
                try? await NotificationsManager.shared.fireImmediate(
                    identifier: "tb.digest.\(kind.rawValue).\(Int(Date().timeIntervalSince1970))",
                    title: title, body: body
                )
            }
        } catch {
            try? EventStore.shared.recordDigestRun(
                kind: kind.rawValue, status: "error",
                message: error.localizedDescription
            )
            log.error("Digest fire failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func renderMarkdown(_ digest: Digest) -> String {
        let f = DateFormatter()
        f.dateStyle = .long
        let title: String
        switch digest.kind {
        case .daily:
            title = "TrackerBud Daily: \(f.string(from: digest.rangeStart))"
        case .weekly:
            let endf = DateFormatter(); endf.dateStyle = .medium
            let cal = Calendar.current
            let endDay = cal.date(byAdding: .day, value: -1, to: digest.rangeEnd) ?? digest.rangeStart
            title = "TrackerBud Weekly: \(endf.string(from: digest.rangeStart)) – \(endf.string(from: endDay))"
        }

        var lines: [String] = []
        lines.append("---")
        lines.append("kind: \(digest.kind.rawValue)")
        lines.append("range_start: \(ISO8601DateFormatter().string(from: digest.rangeStart))")
        lines.append("range_end: \(ISO8601DateFormatter().string(from: digest.rangeEnd))")
        lines.append("total_active_minutes: \(digest.totalActiveMinutes)")
        lines.append("---")
        lines.append("")
        lines.append("# \(title)")
        lines.append("")
        lines.append("**Active time:** \(digest.totalActiveMinutes) min across \(digest.appTime.count) apps.")
        lines.append("")

        lines.append("## Top apps")
        lines.append("")
        for entry in digest.appTime.prefix(10) {
            let name = entry.appName ?? entry.bundleID
            let mins = entry.seconds / 60
            lines.append("- **\(name)** — \(mins) min")
        }
        lines.append("")

        if !digest.siteTime.isEmpty {
            lines.append("## Top sites")
            lines.append("")
            for entry in digest.siteTime.prefix(10) {
                let mins = entry.seconds / 60
                lines.append("- \(entry.host) — \(mins) min")
            }
            lines.append("")
        }

        if !digest.topPatterns.isEmpty {
            lines.append("## Top patterns")
            lines.append("")
            for p in digest.topPatterns.prefix(10) {
                let pretty = prettySignature(p.signature)
                lines.append("- \(pretty) (×\(p.occurrences), score \(String(format: "%.1f", p.score)))")
            }
            lines.append("")
        }

        if !digest.newPatternsThisWeek.isEmpty {
            lines.append("## New patterns this week")
            lines.append("")
            for p in digest.newPatternsThisWeek.prefix(5) {
                lines.append("- \(prettySignature(p.signature)) (×\(p.occurrences))")
            }
            lines.append("")
        }

        if !digest.anomalies.isEmpty {
            lines.append("## Anomalies")
            lines.append("")
            for a in digest.anomalies {
                let name = a.appName ?? a.bundleID
                let ratio = String(format: "%.1f", a.ratio)
                lines.append("- **\(name)** — \(ratio)× your usual (\(a.observedSeconds / 60) min today vs \(a.medianSeconds / 60) min typical) — \(a.severity)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func prettySignature(_ sig: String) -> String {
        let pieces = sig.split(separator: "|").map(String.init)
        return pieces.map { tok in
            if let dot = tok.firstIndex(of: ":") {
                return String(tok[tok.index(after: dot)...])
            }
            return tok
        }.joined(separator: " → ")
    }
}

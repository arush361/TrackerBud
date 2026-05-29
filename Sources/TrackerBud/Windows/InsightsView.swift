import SwiftUI
import Charts
import TrackerBudCore
import Analysis
import ScreenTimeReader
import OSLog

struct InsightsView: View {
    @State private var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var appRows: [TimeAnalyzer.AppRow] = []
    @State private var siteRows: [TimeAnalyzer.SiteRow] = []
    @State private var totalSeconds: Int = 0
    @State private var screenTimeStatus: ScreenTimeReader.Status = .fileMissing
    @State private var loading = false
    @State private var includeAppleOverlay = true
    @State private var nlQuery: String = ""
    @State private var nlAnswer: String? = nil
    @State private var nlBusy: Bool = false
    @State private var nlError: String? = nil
    @State private var includeContent: Bool = false
    @State private var showPrivacyModal: Bool = false
    @State private var recentDigests: [EventStore.DigestRecord] = []

    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear { reload() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Insights")
                    .font(.title2).bold()
                Spacer()
                Button { reload() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
                Button { syncScreenTime() } label: {
                    Label("Sync Apple", systemImage: "icloud.and.arrow.down")
                }
                .controlSize(.small)
                .disabled(screenTimeStatus != .ready)
            }

            HStack(spacing: 12) {
                DatePicker("", selection: $selectedDate, displayedComponents: .date)
                    .labelsHidden()
                    .onChange(of: selectedDate) { _, newValue in
                        selectedDate = Calendar.current.startOfDay(for: newValue)
                        reload()
                    }
                Button("Today") { jumpTo(Date()) }
                Button("Yesterday") {
                    jumpTo(Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date())
                }
                Spacer()
                Toggle("Overlay Apple Screen Time", isOn: $includeAppleOverlay)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(screenTimeStatus != .ready)
            }
            .padding(.bottom, 4)

            screenTimeStatusBanner
        }
        .padding()
    }

    @ViewBuilder
    private var screenTimeStatusBanner: some View {
        switch screenTimeStatus {
        case .ready:
            EmptyView()
        case .fileMissing:
            statusBanner(text: "Apple's Screen Time database isn't present on this Mac.", systemImage: "questionmark.circle", color: .orange)
        case .notReadable:
            HStack {
                Image(systemName: "lock.fill").foregroundColor(.orange)
                Text("Grant Full Disk Access to overlay Apple's Screen Time data.")
                Spacer()
                Button("Open System Settings") {
                    PermissionsProbe.openSystemSettings(for: .fullDisk)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
        case .schemaUnsupported(let detail):
            statusBanner(text: "Screen Time schema unrecognized on this macOS (\(detail)).", systemImage: "exclamationmark.triangle", color: .yellow)
        }
    }

    private func statusBanner(text: String, systemImage: String, color: Color) -> some View {
        HStack {
            Image(systemName: systemImage).foregroundColor(color)
            Text(text).font(.caption)
            Spacer()
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.12)))
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    statsRow
                    askSection
                    digestHistoryStrip
                    chartSection
                    appsTable
                    sitesSection
                }
                .padding()
            }
        }
    }

    private var statsRow: some View {
        HStack(spacing: 24) {
            statBlock(label: "Active time (us)", value: TimeAnalyzer.formatDuration(seconds: totalSeconds))
            statBlock(label: "Active apps", value: "\(appRows.filter { $0.ourSeconds > 0 }.count)")
            if let appleTotal = appleTotalSeconds {
                statBlock(label: "Apple Screen Time", value: TimeAnalyzer.formatDuration(seconds: appleTotal))
            }
            Spacer()
        }
    }

    private var appleTotalSeconds: Int? {
        let total = appRows.compactMap { $0.appleSeconds }.reduce(0, +)
        return total > 0 ? total : nil
    }

    private func statBlock(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundColor(.secondary)
            Text(value).font(.title3).monospacedDigit()
        }
    }

    private var chartSection: some View {
        let top = Array(appRows.prefix(10))
        return VStack(alignment: .leading, spacing: 8) {
            Text("Top apps by time")
                .font(.headline)
            if top.isEmpty {
                Text("No app activity recorded for this day yet. App times accumulate as you switch between apps.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 12)
            } else {
                Chart {
                    ForEach(top) { row in
                        BarMark(
                            x: .value("Minutes (ours)", row.ourSeconds / 60),
                            y: .value("App", row.displayName)
                        )
                        .foregroundStyle(by: .value("Source", "TrackerBud"))
                        if includeAppleOverlay, let apple = row.appleSeconds, apple > 0 {
                            BarMark(
                                x: .value("Minutes (Apple)", apple / 60),
                                y: .value("App", row.displayName)
                            )
                            .foregroundStyle(by: .value("Source", "Apple"))
                            .opacity(0.55)
                        }
                    }
                }
                .frame(height: CGFloat(max(220, top.count * 28)))
                .chartLegend(position: .top, alignment: .leading)
            }
        }
    }

    private var appsTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Apps")
                .font(.headline)
            if appRows.isEmpty {
                Text("—").foregroundColor(.secondary)
            } else {
                Table(appRows) {
                    TableColumn("App") { (r: TimeAnalyzer.AppRow) in
                        Text(r.displayName)
                    }
                    TableColumn("TrackerBud") { (r: TimeAnalyzer.AppRow) in
                        Text(TimeAnalyzer.formatDuration(seconds: r.ourSeconds))
                            .monospacedDigit()
                    }
                    .width(min: 80, ideal: 100, max: 120)
                    TableColumn("Apple") { (r: TimeAnalyzer.AppRow) in
                        if let s = r.appleSeconds {
                            Text(TimeAnalyzer.formatDuration(seconds: s))
                                .monospacedDigit()
                        } else {
                            Text("—").foregroundColor(.secondary)
                        }
                    }
                    .width(min: 80, ideal: 100, max: 120)
                    TableColumn("Δ") { (r: TimeAnalyzer.AppRow) in
                        if let d = r.delta {
                            let sign = d >= 0 ? "+" : ""
                            Text("\(sign)\(d / 60)m")
                                .monospacedDigit()
                                .foregroundColor(d == 0 ? .secondary : (abs(d) > 600 ? .orange : .secondary))
                        } else {
                            Text("—").foregroundColor(.secondary)
                        }
                    }
                    .width(min: 60, ideal: 70, max: 90)
                }
                .frame(minHeight: 200)
            }
        }
    }

    @ViewBuilder
    private var sitesSection: some View {
        let top = Array(siteRows.prefix(10))
        if !top.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Top sites")
                    .font(.headline)
                ForEach(top) { row in
                    HStack {
                        Text(row.host)
                            .font(.callout)
                        Spacer()
                        Text(TimeAnalyzer.formatDuration(seconds: row.seconds))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var askSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Ask Claude about this day")
                    .font(.headline)
                Spacer()
                Toggle("Include content (window titles, URLs)", isOn: $includeContent)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("By default only normalized tokens are sent. Toggle on to include decrypted window titles, URLs, file names, and OCR text in this query.")
            }
            HStack {
                TextField("What did I work on?  e.g. \"How much time on Slack?\"  \"Show me where I jumped between docs and code\"", text: $nlQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runQuery() }
                Button(nlBusy ? "Asking…" : "Ask") { runQuery() }
                    .disabled(nlQuery.isEmpty || nlBusy)
            }
            if !APIKeyVault.shared.hasKey() {
                HStack {
                    Image(systemName: "key").foregroundColor(.orange)
                    Text("Add a Claude API key in Settings to enable this.")
                        .font(.caption)
                    Spacer()
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
            }
            if let answer = nlAnswer {
                VStack(alignment: .leading, spacing: 6) {
                    Text(answer)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Mode: \(includeContent ? "with content (sensitive data sent)" : "tokens only")")
                        .font(.caption2).foregroundColor(.secondary)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
            }
            if let err = nlError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .alert("This query will send your activity data to Anthropic", isPresented: $showPrivacyModal) {
            Button("Cancel", role: .cancel) { showPrivacyModal = false }
            Button("Send (tokens only)") { showPrivacyModal = false; performQuery() }
        } message: {
            Text("Tokens are normalized identifiers (app:bundle, browser:host, file:ext@hash). They don't include decrypted titles, URLs, or content. Toggle 'Include content' to also send those.")
        }
    }

    @ViewBuilder
    private var digestHistoryStrip: some View {
        if !recentDigests.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Recent daily digests")
                    .font(.headline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(recentDigests) { d in
                            DigestCard(digest: d) {
                                if let date = digestDate(d) {
                                    jumpTo(date)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func digestDate(_ d: EventStore.DigestRecord) -> Date? {
        return d.rangeStart
    }

    private func runQuery() {
        let trimmed = nlQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !APIKeyVault.shared.hasKey() {
            nlError = "No Claude API key set. Add one in Settings."
            return
        }
        nlError = nil
        if !UserDefaults.standard.bool(forKey: "TrackerBud.queryDisclosureAcked") {
            UserDefaults.standard.set(true, forKey: "TrackerBud.queryDisclosureAcked")
            showPrivacyModal = true
            return
        }
        performQuery()
    }

    private func performQuery() {
        let q = nlQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let date = selectedDate
        let mode: SessionSummarizer.PrivacyMode = includeContent ? .withContent : .tokensOnly
        let cal = Calendar.current
        let end = cal.date(byAdding: .day, value: 1, to: date) ?? date
        nlBusy = true
        nlAnswer = nil
        Task.detached(priority: .userInitiated) {
            do {
                let result = try await SessionSummarizer.shared.answer(
                    question: q, from: date, to: end, mode: mode
                )
                await MainActor.run {
                    self.nlAnswer = result.prose
                    self.nlBusy = false
                }
            } catch {
                await MainActor.run {
                    self.nlError = error.localizedDescription
                    self.nlBusy = false
                }
            }
        }
    }

    private func jumpTo(_ date: Date) {
        selectedDate = Calendar.current.startOfDay(for: date)
        reload()
    }

    private func reload() {
        loading = true
        let date = selectedDate
        Task.detached(priority: .userInitiated) {
            let st = ScreenTimeReader.shared.status()
            let apps = (try? TimeAnalyzer.shared.appRows(for: date)) ?? []
            let sites = (try? TimeAnalyzer.shared.siteRows(for: date)) ?? []
            let total = (try? TimeAnalyzer.shared.totalActiveSeconds(for: date)) ?? 0
            let digests = (try? EventStore.shared.recentDigests(kind: "daily", limit: 7)) ?? []
            await MainActor.run {
                self.screenTimeStatus = st
                self.appRows = apps
                self.siteRows = sites
                self.totalSeconds = total
                self.recentDigests = digests
                self.loading = false
            }
        }
    }

    struct DigestCard: View {
        let digest: EventStore.DigestRecord
        let onTap: () -> Void

        private let df: DateFormatter = {
            let f = DateFormatter()
            f.dateStyle = .medium
            return f
        }()

        var body: some View {
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(df.string(from: digest.rangeStart))
                        .font(.caption.bold())
                    Text(parsePreview())
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                .padding(10)
                .frame(width: 180, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
            }
            .buttonStyle(.plain)
        }

        private func parsePreview() -> String {
            // Best-effort: decode the payload and show "X min, top: VSCode"
            guard let data = digest.payloadJSON.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let mins = obj["totalActiveMinutes"] as? Int else {
                return "Digest"
            }
            let apps = (obj["appTime"] as? [[String: Any]]) ?? []
            let topApp = apps.first?["appName"] as? String ?? (apps.first?["bundleID"] as? String ?? "—")
            return "\(mins) min · top: \(topApp)"
        }
    }

    private func syncScreenTime() {
        let date = selectedDate
        loading = true
        Task.detached(priority: .userInitiated) {
            let log = Logger(subsystem: "com.arushsharma.trackerbud", category: "InsightsView")
            do {
                let count = try ScreenTimeReader.shared.syncCache(for: date)
                log.info("Synced \(count, privacy: .public) Screen Time rows")
            } catch {
                log.error("Screen Time sync failed: \(error.localizedDescription, privacy: .public)")
            }
            let apps = (try? TimeAnalyzer.shared.appRows(for: date)) ?? []
            await MainActor.run {
                self.appRows = apps
                self.loading = false
            }
        }
    }
}

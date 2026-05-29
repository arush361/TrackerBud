import SwiftUI
import TrackerBudCore
import AppKit

struct ScreenshotSearchView: View {
    @State private var query: String = ""
    @State private var results: [SearchResult] = []
    @State private var searching = false
    @State private var totalCount: Int = 0
    @State private var mode: Mode = .browse

    enum Mode { case browse, search }

    struct SearchResult: Identifiable, Hashable {
        let id: Int64
        let ts: Date
        let thumbPath: String
        let snippet: String
        let frontmostBundle: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(mode == .search ? "Screenshot search" : "Recent screenshots")
                    .font(.title2).bold()
                Spacer()
                Text("\(totalCount) total")
                    .foregroundColor(.secondary)
                    .font(.caption)
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
            }
            .padding()

            HStack {
                TextField("Search OCR text… (leave empty to browse all)", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runQuery() }
                    .onChange(of: query) { _, newValue in
                        if newValue.isEmpty {
                            mode = .browse
                            loadRecent()
                        }
                    }
                Button(mode == .search ? "Search" : "Browse") {
                    runQuery()
                }
                .disabled(searching)
            }
            .padding(.horizontal)
            .padding(.bottom)

            Divider()

            if searching {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty {
                ContentUnavailableView {
                    Label(mode == .search ? "No matches" : "No screenshots yet", systemImage: mode == .search ? "magnifyingglass" : "photo.on.rectangle")
                } description: {
                    Text(mode == .search
                         ? "No screenshots contain ‘\(query)’."
                         : "Screenshots are captured every 30 seconds (or 90 on battery). Grant Screen Recording in System Settings if this stays empty.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 220), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(results) { r in
                            ScreenshotCard(result: r, query: mode == .search ? query : "")
                        }
                    }
                    .padding()
                }
            }
        }
        .onAppear {
            loadRecent()
        }
    }

    private func runQuery() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            loadRecent()
        } else {
            mode = .search
            runSearch(q)
        }
    }

    private func loadRecent() {
        mode = .browse
        searching = true
        Task.detached(priority: .userInitiated) {
            let hits = (try? EventStore.shared.recentScreenshots(limit: 200)) ?? []
            let mapped = hits.map { hit in
                SearchResult(
                    id: hit.screenshotID, ts: hit.ts,
                    thumbPath: hit.thumbPath, snippet: hit.snippet,
                    frontmostBundle: hit.frontmostBundle
                )
            }
            let total = (try? EventStore.shared.countScreenshots()) ?? 0
            await MainActor.run {
                self.results = mapped
                self.totalCount = total
                self.searching = false
            }
        }
    }

    private func runSearch(_ q: String) {
        searching = true
        Task.detached(priority: .userInitiated) {
            let hits = (try? EventStore.shared.searchOCR(query: q)) ?? []
            let mapped = hits.map { hit in
                SearchResult(
                    id: hit.screenshotID, ts: hit.ts,
                    thumbPath: hit.thumbPath, snippet: hit.snippet,
                    frontmostBundle: nil
                )
            }
            await MainActor.run {
                self.results = mapped
                self.searching = false
            }
        }
    }

    private func refresh() {
        if mode == .search && !query.isEmpty {
            runSearch(query)
        } else {
            loadRecent()
        }
    }
}

struct ScreenshotCard: View {
    let result: ScreenshotSearchView.SearchResult
    let query: String

    private let df: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image = NSImage(contentsOfFile: result.thumbPath) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 130)
                    .overlay(Text("(thumb missing)").foregroundColor(.secondary).font(.caption))
            }
            Text(df.string(from: result.ts))
                .font(.caption)
                .foregroundColor(.secondary)
            if let bundle = result.frontmostBundle, !bundle.isEmpty {
                Text(displayName(forBundle: bundle))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            if !result.snippet.isEmpty {
                Text(snippet(result.snippet))
                    .font(.caption)
                    .lineLimit(3)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    private func snippet(_ s: String) -> String {
        guard !query.isEmpty else { return String(s.prefix(140)) }
        let lower = s.lowercased()
        let q = query.lowercased()
        guard let range = lower.range(of: q) else { return String(s.prefix(140)) }
        let startIndex = s.index(range.lowerBound, offsetBy: -40, limitedBy: s.startIndex) ?? s.startIndex
        let endIndex = s.index(range.upperBound, offsetBy: 60, limitedBy: s.endIndex) ?? s.endIndex
        let prefix = startIndex > s.startIndex ? "…" : ""
        let suffix = endIndex < s.endIndex ? "…" : ""
        return prefix + s[startIndex..<endIndex] + suffix
    }

    private func displayName(forBundle bundle: String) -> String {
        // Cheap nicety: strip the reverse-DNS prefix.
        if let last = bundle.split(separator: ".").last { return String(last) }
        return bundle
    }
}

import SwiftUI
import TrackerBudCore
import Analysis

struct PatternsView: View {
    @State private var patterns: [PatternRow] = []
    @State private var loading = false

    private let df: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Patterns")
                    .font(.title2).bold()
                Spacer()
                Button {
                    rebuild()
                } label: {
                    Label("Re-mine", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Force a full re-mine of all events")
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .padding()

            Divider()

            if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if patterns.isEmpty {
                ContentUnavailableView {
                    Label("No patterns yet", systemImage: "sparkles")
                } description: {
                    Text("Patterns emerge after a few sessions of varied activity. They appear when the same sequence (length 2 or more) repeats at least 3 times with a recency-weighted score of 1.5 or more.")
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(patterns) { p in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(displaySignature(p.signature))
                                .font(.body.monospaced())
                                .lineLimit(2)
                                .truncationMode(.middle)
                            Spacer()
                            Text("score \(String(format: "%.1f", p.score))")
                                .font(.caption2.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                        HStack(spacing: 12) {
                            Label("\(p.occurrences)×", systemImage: "repeat")
                            Label("length \(p.length)", systemImage: "rectangle.split.3x1")
                            Label(df.localizedString(for: p.lastSeenAt, relativeTo: Date()), systemImage: "clock")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        loading = true
        Task.detached(priority: .userInitiated) {
            let rows = (try? EventStore.shared.topPatterns()) ?? []
            await MainActor.run {
                self.patterns = rows
                self.loading = false
            }
        }
    }

    private func rebuild() {
        loading = true
        Task.detached(priority: .userInitiated) {
            try? PatternMiner.shared.rebuildAll()
            let rows = (try? EventStore.shared.topPatterns()) ?? []
            await MainActor.run {
                self.patterns = rows
                self.loading = false
            }
        }
    }

    private func displaySignature(_ sig: String) -> String {
        // Show as "A → B → C" using just the meaningful part of each token.
        let pieces = sig.split(separator: "|").map(String.init)
        let pretty = pieces.map { tok -> String in
            if let dot = tok.firstIndex(of: ":") {
                return String(tok[tok.index(after: dot)...])
            }
            return tok
        }
        return pretty.joined(separator: " → ")
    }
}

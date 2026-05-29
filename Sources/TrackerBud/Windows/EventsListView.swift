import SwiftUI
import TrackerBudCore

struct EventsListView: View {
    @EnvironmentObject var coordinator: TrackingCoordinator
    @State private var rows: [EventRow] = []
    @State private var totalCount: Int = 0
    @State private var refreshTask: Task<Void, Never>?

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent events")
                    .font(.title2).bold()
                Spacer()
                Text("\(totalCount) total")
                    .foregroundColor(.secondary)
                Button {
                    refreshNow()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh now")
            }
            .padding()

            Divider()

            if rows.isEmpty {
                ContentUnavailableView {
                    Label("No events yet", systemImage: "tray")
                } description: {
                    Text("Switch between apps to see TrackerBud capture activity. If window titles stay empty, grant Accessibility in System Settings.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(rows) {
                    TableColumn("Time") { (row: EventRow) in
                        Text(dateFormatter.string(from: row.ts))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                    .width(min: 80, ideal: 90, max: 110)

                    TableColumn("Source") { (row: EventRow) in
                        Text(row.source.rawValue)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(sourceColor(row.source).opacity(0.18))
                            .clipShape(Capsule())
                    }
                    .width(min: 60, ideal: 70, max: 90)

                    TableColumn("Type") { (row: EventRow) in
                        Text(row.type)
                            .font(.caption.monospaced())
                    }
                    .width(min: 90, ideal: 110, max: 160)

                    TableColumn("App") { (row: EventRow) in
                        Text(row.appName ?? row.bundleId ?? "—")
                    }
                    .width(min: 100, ideal: 140, max: 220)

                    TableColumn("Detail") { (row: EventRow) in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.primaryText ?? row.token)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundColor(row.primaryText == nil ? .secondary : .primary)
                            if let s = row.secondaryText, !s.isEmpty {
                                Text(s)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { startAutoRefresh() }
        .onDisappear { refreshTask?.cancel() }
        .onChange(of: coordinator.lastEvent?.ts) { _, _ in
            refreshNow()
        }
    }

    private func startAutoRefresh() {
        refreshNow()
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                refreshNow()
            }
        }
    }

    private func refreshNow() {
        Task.detached(priority: .userInitiated) {
            let snapshot = (try? EventStore.shared.recentEventRows(limit: 300)) ?? []
            let count = (try? EventStore.shared.countEvents()) ?? 0
            await MainActor.run {
                self.rows = snapshot
                self.totalCount = count
            }
        }
    }

    private func sourceColor(_ source: EventSource) -> Color {
        switch source {
        case .app: return .blue
        case .browser: return .purple
        case .file: return .orange
        case .input: return .red
        case .clipboard: return .yellow
        case .screen: return .green
        }
    }
}

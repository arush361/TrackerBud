import SwiftUI
import AppKit
import TrackerBudCore
import Analysis

struct MenuBarContent: View {
    @EnvironmentObject var coordinator: TrackingCoordinator
    @State private var topApps: [TimeAnalyzer.AppRow] = []
    @State private var topPatternSig: String? = nil
    @State private var activeMinutes: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: coordinator.isPaused ? "eye.slash" : "eye")
                Text(coordinator.isPaused ? "Tracking paused" : "Tracking active")
                    .font(.headline)
                Spacer()
                Text("\(activeMinutes)m today")
                    .foregroundColor(.secondary)
                    .font(.caption.monospacedDigit())
            }
            .padding(.horizontal)
            .padding(.top, 10)

            Divider().padding(.vertical, 6)

            // Today's top apps
            if !topApps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Today's top apps")
                        .font(.caption).foregroundColor(.secondary)
                        .padding(.horizontal)
                    ForEach(Array(topApps.prefix(3))) { app in
                        HStack {
                            Text(app.displayName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(TimeAnalyzer.formatDuration(seconds: app.ourSeconds))
                                .foregroundColor(.secondary)
                                .font(.caption.monospacedDigit())
                        }
                        .padding(.horizontal)
                    }
                }
                Divider().padding(.vertical, 6)
            }

            if let topSig = topPatternSig {
                HStack(alignment: .top) {
                    Image(systemName: "sparkles").foregroundColor(.purple)
                    Text(topSig)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .padding(.horizontal)
                .padding(.bottom, 6)
                Divider()
            }

            Toggle("Pause tracking", isOn: $coordinator.isPaused)
                .toggleStyle(.switch)
                .padding(.horizontal)
                .padding(.vertical, 6)

            Divider()

            ForEach(coordinator.trackerStatus.sorted(by: { $0.key < $1.key }), id: \.key) { key, running in
                HStack {
                    Circle()
                        .fill(running ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(key.capitalized)
                    Spacer()
                    Text(running ? "on" : "off")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .padding(.horizontal)
                .padding(.vertical, 2)
            }

            Divider().padding(.vertical, 6)

            Button("Open TrackerBud") { openMainWindow() }
                .buttonStyle(.borderless)
                .padding(.horizontal)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .padding(.horizontal)
                .padding(.bottom, 10)
        }
        .frame(width: 260)
        .onAppear { refresh() }
    }

    private func refresh() {
        Task.detached(priority: .userInitiated) {
            let apps = (try? TimeAnalyzer.shared.appRows(for: Date())) ?? []
            let totalSecs = (try? TimeAnalyzer.shared.totalActiveSeconds(for: Date())) ?? 0
            let mins = totalSecs / 60
            let patterns = (try? EventStore.shared.topPatterns(limit: 1)) ?? []
            let sig = patterns.first.map { Self.prettySignatureStatic($0.signature) }
            await MainActor.run {
                self.topApps = Array(apps.prefix(3))
                self.activeMinutes = mins
                self.topPatternSig = sig
            }
        }
    }

    static func prettySignatureStatic(_ sig: String) -> String {
        let pieces = sig.split(separator: "|").map(String.init)
        return pieces.map { tok in
            if let dot = tok.firstIndex(of: ":") {
                return String(tok[tok.index(after: dot)...])
            }
            return tok
        }.joined(separator: " → ")
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.title.contains("TrackerBud") {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }
}

import SwiftUI
import AppKit
import TrackerBudCore

struct MenuBarContent: View {
    @EnvironmentObject var coordinator: TrackingCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: coordinator.isPaused ? "eye.slash" : "eye")
                Text(coordinator.isPaused ? "Tracking paused" : "Tracking active")
                    .font(.headline)
            }
            .padding(.horizontal)
            .padding(.top, 10)

            Divider().padding(.vertical, 6)

            Toggle("Pause tracking", isOn: $coordinator.isPaused)
                .toggleStyle(.switch)
                .padding(.horizontal)
                .padding(.bottom, 6)

            Divider()

            ForEach(coordinator.trackerStatus.sorted(by: { $0.key < $1.key }), id: \.key) { key, running in
                HStack {
                    Circle()
                        .fill(running ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(key.capitalized + " tracker")
                    Spacer()
                    Text(running ? "running" : "off")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .padding(.horizontal)
                .padding(.vertical, 3)
            }

            Divider().padding(.vertical, 6)

            Button("Open TrackerBud") {
                openMainWindow()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal)
            .padding(.bottom, 10)
        }
        .frame(width: 240)
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI WindowGroup window is opened by name; the WindowGroup default is the app name.
        // Use the openWindow environment in a SwiftUI host, but here in AppKit we just bring app forward.
        for window in NSApp.windows where window.title.contains("TrackerBud") {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // Fallback: simulate the standard menu "New Window" or rely on WindowGroup's default behavior.
        if let url = URL(string: "trackerbud://open") {
            NSWorkspace.shared.open(url)
        }
    }
}

import SwiftUI
import AppKit
import TrackerBudCore
import AppTracker
import BrowserTracker
import FileTracker
import InputTracker
import ClipboardTracker
import ScreenTracker
import Analysis
import OSLog

@main
struct TrackerBudApp: App {
    @StateObject private var coordinator = TrackingCoordinator.shared
    private let log = Logger(subsystem: "com.arushsharma.trackerbud", category: "App")

    init() {
        let coord = TrackingCoordinator.shared
        coord.register(AppTracker())
        coord.register(BrowserTracker())
        coord.register(FileTracker())
        coord.register(InputTracker())
        coord.register(ClipboardTracker())
        coord.register(ScreenTracker())
    }

    var body: some Scene {
        WindowGroup("TrackerBud") {
            DashboardWindow()
                .environmentObject(coordinator)
                .frame(minWidth: 800, minHeight: 520)
                .task {
                    do {
                        try coordinator.startAll()
                        try EventStore.shared.seedDefaultPrivacyRules()
                        PatternMiner.shared.startBackgroundRefresh()
                    } catch {
                        Logger(subsystem: "com.arushsharma.trackerbud", category: "App")
                            .error("startAll failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(coordinator)
        } label: {
            Image(systemName: coordinator.isPaused ? "eye.slash" : "eye")
        }
    }
}

import SwiftUI
import TrackerBudCore

enum DashboardSection: String, CaseIterable, Identifiable, Hashable {
    case events, screenshots, patterns, settings
    var id: String { rawValue }

    var label: String {
        switch self {
        case .events: return "Events"
        case .screenshots: return "Screenshots"
        case .patterns: return "Patterns"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .events: return "list.bullet.rectangle"
        case .screenshots: return "photo.on.rectangle"
        case .patterns: return "sparkles"
        case .settings: return "gear"
        }
    }
}

struct DashboardWindow: View {
    @EnvironmentObject var coordinator: TrackingCoordinator
    @State private var selection: DashboardSection? = .events
    @State private var showOnboarding: Bool = !UserDefaults.standard.bool(forKey: "TrackerBud.onboardingComplete")

    var body: some View {
        NavigationSplitView {
            List(DashboardSection.allCases, selection: $selection) { section in
                NavigationLink(value: section) {
                    Label(section.label, systemImage: section.systemImage)
                }
            }
            .navigationTitle("TrackerBud")
            .listStyle(.sidebar)
        } detail: {
            switch selection {
            case .events:      EventsListView()
            case .screenshots: ScreenshotSearchView()
            case .patterns:    PatternsView()
            case .settings:    SettingsView()
            case .none:        EventsListView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(coordinator.isPaused ? .gray : .green)
                        .frame(width: 8, height: 8)
                    Text(coordinator.isPaused ? "Paused" : "Tracking")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
        }
        .sheet(isPresented: $showOnboarding) {
            PermissionsFlowView(onDismiss: { showOnboarding = false })
        }
    }
}

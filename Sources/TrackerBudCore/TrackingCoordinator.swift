import Foundation
import Combine
import OSLog

/// Owns the lifecycle of all trackers. Listens to the pause toggle and starts/stops
/// trackers as needed. Also forwards events from the EventBus into EventStore writes.
@MainActor
public final class TrackingCoordinator: ObservableObject {
    public static let shared = TrackingCoordinator()

    @Published public private(set) var isRunning: Bool = false
    @Published public var isPaused: Bool {
        didSet { handlePauseChanged() }
    }
    @Published public private(set) var lastEvent: EmittedEvent?
    @Published public private(set) var trackerStatus: [String: Bool] = [:]

    private let log = Logger(subsystem: "com.arushsharma.trackerbud", category: "Coordinator")
    private var trackers: [any Tracker] = []
    private var persistTask: Task<Void, Never>?

    public init() {
        // Restore pause state from UserDefaults
        self.isPaused = UserDefaults.standard.bool(forKey: "TrackerBud.isPaused")
    }

    public func register(_ tracker: any Tracker) {
        trackers.append(tracker)
        trackerStatus[type(of: tracker).id] = false
    }

    public func startAll() throws {
        guard !isRunning else { return }
        try EventStore.shared.start()
        startPersistLoop()

        if !isPaused {
            for tracker in trackers {
                do {
                    try tracker.start()
                    trackerStatus[type(of: tracker).id] = true
                } catch {
                    log.error("Tracker \(type(of: tracker).id, privacy: .public) failed to start: \(error.localizedDescription, privacy: .public)")
                    trackerStatus[type(of: tracker).id] = false
                }
            }
        }
        isRunning = true
    }

    public func stopAll() {
        for tracker in trackers {
            tracker.stop()
            trackerStatus[type(of: tracker).id] = false
        }
        persistTask?.cancel()
        persistTask = nil
        isRunning = false
    }

    private func startPersistLoop() {
        persistTask?.cancel()
        persistTask = Task.detached(priority: .utility) {
            for await event in EventBus.shared.stream() {
                if event.source == .app {
                    do {
                        _ = try EventStore.shared.writeAppEvent(
                            ts: event.ts,
                            type: event.type,
                            token: event.token,
                            bundleID: event.bundleID ?? "",
                            appName: event.appName ?? "",
                            windowTitle: event.windowTitle,
                            pid: nil
                        )
                    } catch {
                        Logger(subsystem: "com.arushsharma.trackerbud", category: "PersistLoop")
                            .error("Failed to persist event: \(error.localizedDescription, privacy: .public)")
                    }
                }
                await MainActor.run {
                    TrackingCoordinator.shared.lastEvent = event
                }
            }
        }
    }

    private func handlePauseChanged() {
        UserDefaults.standard.set(isPaused, forKey: "TrackerBud.isPaused")
        if isPaused {
            for tracker in trackers {
                tracker.stop()
                trackerStatus[type(of: tracker).id] = false
            }
        } else if isRunning {
            for tracker in trackers {
                do {
                    try tracker.start()
                    trackerStatus[type(of: tracker).id] = true
                } catch {
                    log.error("Resuming tracker \(type(of: tracker).id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}

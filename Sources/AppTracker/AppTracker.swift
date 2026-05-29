import Foundation
import AppKit
import ApplicationServices
import TrackerBudCore
import OSLog

public final class AppTracker: Tracker, @unchecked Sendable {
    public static let id = "app"

    private let lock = NSLock()
    private var observer: NSObjectProtocol?
    private var windowPollTimer: DispatchSourceTimer?
    private var lastBundleID: String?
    private var lastWindowTitle: String?
    private let log = Logger(subsystem: "com.arushsharma.trackerbud", category: "AppTracker")

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return observer != nil
    }

    public init() {}

    public func start() throws {
        lock.lock()
        guard observer == nil else { lock.unlock(); return }
        lock.unlock()

        let center = NSWorkspace.shared.notificationCenter
        let obs = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.handleActivated(app: app)
        }

        lock.lock()
        self.observer = obs
        lock.unlock()

        startWindowTitlePolling()

        // Emit current foreground app immediately so the events list isn't empty at start
        if let current = NSWorkspace.shared.frontmostApplication {
            handleActivated(app: current)
        }
        log.info("AppTracker started")
    }

    public func stop() {
        lock.lock()
        if let obs = observer {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        observer = nil
        windowPollTimer?.cancel()
        windowPollTimer = nil
        lock.unlock()
        log.info("AppTracker stopped")
    }

    public func currentPermissionStatus() -> PermissionStatus {
        // NSWorkspace activation events themselves don't need TCC.
        // The Accessibility check is for window title polling. Use a behavioral check.
        return AXIsProcessTrusted() ? .granted : .notDetermined
    }

    private func handleActivated(app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier else { return }
        let name = app.localizedName ?? bundleID

        lock.lock()
        let titleChanged = bundleID != lastBundleID
        if titleChanged {
            lastBundleID = bundleID
            lastWindowTitle = nil
        }
        lock.unlock()

        let token = "app:\(bundleID)"
        let payload = jsonEncode([
            "bundle_id": bundleID,
            "app_name": name,
            "pid": String(app.processIdentifier)
        ])

        EventBus.shared.emit(EmittedEvent(
            source: .app,
            type: "app.activated",
            token: token,
            appName: name,
            bundleID: bundleID,
            windowTitle: nil
        ))

        // Try to read the window title immediately (best-effort; will be nil if AX not granted)
        if let title = readFocusedWindowTitle(pid: app.processIdentifier), !title.isEmpty {
            lock.lock()
            let changed = title != lastWindowTitle
            lastWindowTitle = title
            lock.unlock()
            if changed {
                EventBus.shared.emit(EmittedEvent(
                    source: .app,
                    type: "app.window",
                    token: token + "|w:" + sanitizedTitleToken(title),
                    appName: name,
                    bundleID: bundleID,
                    windowTitle: title
                ))
            }
        }
        _ = payload // (kept for richer payload_json in a later milestone)
    }

    private func startWindowTitlePolling() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 2.0, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.pollCurrentWindowTitle()
        }
        timer.resume()
        lock.lock()
        windowPollTimer = timer
        lock.unlock()
    }

    private func pollCurrentWindowTitle() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier
        else { return }

        guard let title = readFocusedWindowTitle(pid: app.processIdentifier), !title.isEmpty else { return }

        lock.lock()
        let changed = (title != lastWindowTitle) || (bundleID != lastBundleID)
        lastBundleID = bundleID
        lastWindowTitle = title
        lock.unlock()

        if changed {
            let name = app.localizedName ?? bundleID
            EventBus.shared.emit(EmittedEvent(
                source: .app,
                type: "app.window",
                token: "app:\(bundleID)|w:\(sanitizedTitleToken(title))",
                appName: name,
                bundleID: bundleID,
                windowTitle: title
            ))
        }
    }

    private func readFocusedWindowTitle(pid: pid_t) -> String? {
        // Returns nil silently when Accessibility is not granted (TCC).
        let appElement = AXUIElementCreateApplication(pid)

        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        )
        guard result == .success, let window = focusedWindow else {
            return nil
        }

        var titleValue: CFTypeRef?
        let titleResult = AXUIElementCopyAttributeValue(
            window as! AXUIElement,
            kAXTitleAttribute as CFString,
            &titleValue
        )
        guard titleResult == .success, let title = titleValue as? String else {
            return nil
        }
        return title
    }

    private func sanitizedTitleToken(_ title: String) -> String {
        // Collapse whitespace and truncate, used only for the `token` column where
        // we want stable pattern-detection signatures rather than full titles.
        let collapsed = title
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(collapsed.prefix(80))
    }

    private func jsonEncode(_ dict: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }
}

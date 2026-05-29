import Foundation
import AppKit
import TrackerBudCore
import OSLog

public final class BrowserTracker: Tracker, @unchecked Sendable {
    public static let id = "browser"

    private let lock = NSLock()
    private var observer: NSObjectProtocol?
    private var pollTimer: DispatchSourceTimer?
    private var providers: [BrowserURLProvider]
    private var lastSnapshot: (bundleID: String, url: String)?
    private let log = Logger(subsystem: "com.arushsharma.trackerbud", category: "BrowserTracker")

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return observer != nil
    }

    public init(providers: [BrowserURLProvider] = [
        SafariURLProvider(),
        ChromeURLProvider(),
        ArcURLProvider()
    ]) {
        self.providers = providers
    }

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
            self.tryCapture(from: app)
        }
        lock.lock(); observer = obs; lock.unlock()

        // Also poll the foreground browser every 4s for in-app tab switches.
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 4.0, repeating: 4.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if let current = NSWorkspace.shared.frontmostApplication {
                self.tryCapture(from: current)
            }
        }
        timer.resume()
        lock.lock(); pollTimer = timer; lock.unlock()

        if let current = NSWorkspace.shared.frontmostApplication {
            tryCapture(from: current)
        }
        log.info("BrowserTracker started")
    }

    public func stop() {
        lock.lock()
        if let obs = observer {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        observer = nil
        pollTimer?.cancel()
        pollTimer = nil
        lock.unlock()
        log.info("BrowserTracker stopped")
    }

    public func currentPermissionStatus() -> PermissionStatus {
        // Apple Events automation: per-target TCC prompt happens on first send.
        // Behavioral check: try to query Safari/Chrome; if any succeeds we're at
        // least partially granted. If none of the apps are running we can't tell.
        let anyBrowserRunning = NSWorkspace.shared.runningApplications.contains { app in
            guard let bid = app.bundleIdentifier else { return false }
            return providers.contains { $0.handles(bundleID: bid) }
        }
        if !anyBrowserRunning { return .notDetermined }
        let result = providers.first { p in p.currentURL() != nil }
        return result != nil ? .granted : .denied
    }

    private func tryCapture(from app: NSRunningApplication) {
        guard let bid = app.bundleIdentifier else { return }
        guard let provider = providers.first(where: { $0.handles(bundleID: bid) }) else { return }
        guard let snap = provider.currentURL(), !snap.url.isEmpty else { return }

        lock.lock()
        let same = lastSnapshot?.bundleID == bid && lastSnapshot?.url == snap.url
        if same { lock.unlock(); return }
        lastSnapshot = (bid, snap.url)
        lock.unlock()

        let parsed = parseURL(snap.url)
        let token = "browser:\(parsed.host)\(parsed.firstSegment.isEmpty ? "" : "+\(parsed.firstSegment)")"

        // Persist directly through EventStore (not via EventBus) since browser/file/etc.
        // writes need source-specific tables.
        do {
            _ = try EventStore.shared.writeBrowserEvent(
                ts: Date(),
                browser: snap.browser,
                url: snap.url,
                urlHost: parsed.host,
                urlPath: parsed.path,
                pageTitle: snap.title,
                token: token
            )
            // Also emit through bus for live UI updates.
            EventBus.shared.emit(EmittedEvent(
                source: .browser,
                type: "browser.url",
                token: token,
                appName: snap.browser.capitalized,
                bundleID: bid,
                windowTitle: snap.title
            ))
        } catch {
            log.error("Browser write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func parseURL(_ urlString: String) -> (host: String, path: String, firstSegment: String) {
        guard let comps = URLComponents(string: urlString) else {
            return ("", "", "")
        }
        let host = comps.host ?? ""
        let path = comps.path
        let firstSegment: String = {
            let parts = path.split(separator: "/").map(String.init)
            guard let first = parts.first else { return "" }
            return "/" + first
        }()
        return (host, path, firstSegment)
    }
}

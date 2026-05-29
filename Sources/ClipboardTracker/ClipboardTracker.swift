import Foundation
import AppKit
import TrackerBudCore
import OSLog

public final class ClipboardTracker: Tracker, @unchecked Sendable {
    public static let id = "clipboard"

    private let lock = NSLock()
    private var pollTimer: DispatchSourceTimer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private let log = Logger(subsystem: "com.arushsharma.trackerbud", category: "ClipboardTracker")
    private let pollIntervalSeconds: TimeInterval = 1.0
    private let maxTextSize = 100_000 // 100 KB cap for clipboard content

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return pollTimer != nil
    }

    public init() {}

    public func start() throws {
        lock.lock()
        guard pollTimer == nil else { lock.unlock(); return }
        lock.unlock()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + pollIntervalSeconds, repeating: pollIntervalSeconds)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        lock.lock(); pollTimer = timer; lock.unlock()
        log.info("ClipboardTracker started")
    }

    public func stop() {
        lock.lock()
        pollTimer?.cancel()
        pollTimer = nil
        lock.unlock()
        log.info("ClipboardTracker stopped")
    }

    public func currentPermissionStatus() -> PermissionStatus {
        return .notRequired
    }

    private func poll() {
        let pb = NSPasteboard.general
        let change = pb.changeCount
        lock.lock()
        if change == lastChangeCount { lock.unlock(); return }
        lastChangeCount = change
        lock.unlock()

        // Frontmost app at moment of copy (best effort).
        let frontApp = NSWorkspace.shared.frontmostApplication
        let sourceBundle = frontApp?.bundleIdentifier

        // Check privacy rules.
        if let bid = sourceBundle, isExcluded(bundleID: bid) {
            log.debug("Skipping clipboard event from excluded app \(bid, privacy: .public)")
            return
        }

        // Determine kind. Prefer string; fall back to image; fall back to file URLs.
        if let text = pb.string(forType: .string) {
            let truncated = String(text.prefix(maxTextSize))
            let byteSize = text.lengthOfBytes(using: .utf8)
            do {
                _ = try EventStore.shared.writeClipboardEvent(
                    ts: Date(),
                    kind: "text",
                    textContent: truncated,
                    byteSize: byteSize,
                    sourceApp: sourceBundle,
                    token: "clip:text"
                )
                EventBus.shared.emit(EmittedEvent(
                    source: .clipboard,
                    type: "clipboard.copy",
                    token: "clip:text",
                    appName: frontApp?.localizedName,
                    bundleID: sourceBundle,
                    windowTitle: String(truncated.prefix(60))
                ))
            } catch {
                log.error("Clipboard write failed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }

        if pb.types?.contains(.tiff) == true || pb.types?.contains(.png) == true {
            recordNonText(kind: "image", sourceBundle: sourceBundle, frontApp: frontApp)
            return
        }
        if pb.types?.contains(.fileURL) == true {
            recordNonText(kind: "file-url", sourceBundle: sourceBundle, frontApp: frontApp)
            return
        }
    }

    private func recordNonText(kind: String, sourceBundle: String?, frontApp: NSRunningApplication?) {
        do {
            _ = try EventStore.shared.writeClipboardEvent(
                ts: Date(),
                kind: kind,
                textContent: nil,
                byteSize: nil,
                sourceApp: sourceBundle,
                token: "clip:\(kind)"
            )
            EventBus.shared.emit(EmittedEvent(
                source: .clipboard,
                type: "clipboard.copy",
                token: "clip:\(kind)",
                appName: frontApp?.localizedName,
                bundleID: sourceBundle,
                windowTitle: nil
            ))
        } catch {
            log.error("Clipboard non-text write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func isExcluded(bundleID: String) -> Bool {
        guard let rules = try? EventStore.shared.privacyRules() else { return false }
        return rules.contains { rule in
            (rule.action == "skip-all" || rule.action == "skip-clipboard")
                && rule.bundleID == bundleID
        }
    }
}

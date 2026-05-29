import Foundation
import AppKit
import TrackerBudCore
import OSLog

public final class InputTracker: Tracker, @unchecked Sendable {
    public static let id = "input"

    private let lock = NSLock()
    private var monitor: Any?
    private var lastShortcut: (mods: UInt, key: UInt16, ts: Date)?
    private let log = Logger(subsystem: "com.arushsharma.trackerbud", category: "InputTracker")

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return monitor != nil
    }

    public init() {}

    public func start() throws {
        lock.lock()
        guard monitor == nil else { lock.unlock(); return }
        lock.unlock()

        let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event: event)
        }
        lock.lock(); monitor = m; lock.unlock()
        log.info("InputTracker started")
    }

    public func stop() {
        lock.lock()
        if let m = monitor {
            NSEvent.removeMonitor(m)
        }
        monitor = nil
        lock.unlock()
        log.info("InputTracker stopped")
    }

    public func currentPermissionStatus() -> PermissionStatus {
        // addGlobalMonitorForEvents silently no-ops without Input Monitoring.
        // No clean way to probe without triggering a prompt; report notDetermined.
        // The user will see no shortcut events in the list which is the behavioral signal.
        return .notDetermined
    }

    private func handle(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Only log events with at least one non-shift modifier — pure character
        // keystrokes are not shortcuts and we don't want to capture them.
        let meaningfulMods: NSEvent.ModifierFlags = [.command, .control, .option]
        if flags.intersection(meaningfulMods).isEmpty { return }

        let mods = flags.rawValue
        let key = event.keyCode
        let now = Date()

        // Debounce identical shortcuts within 200ms (key repeat).
        lock.lock()
        if let last = lastShortcut,
           last.mods == mods, last.key == key,
           now.timeIntervalSince(last.ts) < 0.2 {
            lock.unlock(); return
        }
        lastShortcut = (mods, key, now)
        lock.unlock()

        let keyChar = event.charactersIgnoringModifiers ?? ""
        let modsInt64 = Int64(bitPattern: UInt64(mods))
        let token = InputKeyFormatter.tokenFor(
            modifiers: modsInt64,
            keyChar: keyChar,
            keyCode: Int64(key)
        )

        do {
            _ = try EventStore.shared.writeInputEvent(
                ts: now,
                modifiers: modsInt64,
                keyCode: Int64(key),
                keyChar: keyChar.isEmpty ? nil : keyChar,
                token: token
            )
            EventBus.shared.emit(EmittedEvent(
                source: .input,
                type: "input.shortcut",
                token: token,
                appName: NSWorkspace.shared.frontmostApplication?.localizedName,
                bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                windowTitle: nil
            ))
        } catch {
            log.error("Input write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

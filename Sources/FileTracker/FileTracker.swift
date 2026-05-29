import Foundation
import CoreServices
import TrackerBudCore
import OSLog

public final class FileTracker: Tracker, @unchecked Sendable {
    public static let id = "file"

    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var watchPaths: [String]
    private let log = Logger(subsystem: "com.arushsharma.trackerbud", category: "FileTracker")

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return stream != nil
    }

    public init(watchPaths: [String] = FileTracker.defaultWatchPaths()) {
        self.watchPaths = watchPaths
    }

    public static func defaultWatchPaths() -> [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/Documents",
            "\(home)/Desktop",
            "\(home)/Downloads"
        ]
    }

    public func start() throws {
        lock.lock()
        guard stream == nil else { lock.unlock(); return }
        lock.unlock()

        // Build paths array and ensure they exist (FSEvents silently ignores
        // missing paths but we want to log them).
        let fm = FileManager.default
        let existing = watchPaths.filter { fm.fileExists(atPath: $0) }
        if existing.isEmpty {
            log.warning("No watch paths exist; FileTracker has nothing to watch")
            return
        }

        let context = UnsafeMutablePointer<FSEventStreamContext>.allocate(capacity: 1)
        context.initialize(to: FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        ))
        defer { context.deallocate() }

        let callback: FSEventStreamCallback = { (
            _, info, count, eventPaths, eventFlags, _
        ) in
            guard let info else { return }
            let tracker = Unmanaged<FileTracker>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<NSArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
            for i in 0..<count {
                let path = i < paths.count ? paths[i] : ""
                let flags = eventFlags[i]
                tracker.handleFSEvent(path: path, flags: flags)
            }
        }

        let pathsCFArray = existing as CFArray
        let createdStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            context,
            pathsCFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.5,  // latency seconds (debounce)
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes
            )
        )
        guard let createdStream else {
            log.error("FSEventStreamCreate returned nil")
            return
        }

        FSEventStreamSetDispatchQueue(createdStream, DispatchQueue.global(qos: .utility))
        if !FSEventStreamStart(createdStream) {
            log.error("FSEventStreamStart returned false")
            FSEventStreamInvalidate(createdStream)
            return
        }

        lock.lock(); stream = createdStream; lock.unlock()
        log.info("FileTracker started watching \(existing.count) paths")
    }

    public func stop() {
        lock.lock()
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
        }
        stream = nil
        lock.unlock()
        log.info("FileTracker stopped")
    }

    public func currentPermissionStatus() -> PermissionStatus {
        // FSEvents on user folders requires either Full Disk Access OR per-folder
        // (Documents/Desktop/Downloads) TCC. We can't cleanly probe TCC; do a
        // behavioral check by listing each watched folder.
        let fm = FileManager.default
        for path in watchPaths {
            if !fm.fileExists(atPath: path) { continue }
            if (try? fm.contentsOfDirectory(atPath: path)) == nil {
                return .denied
            }
        }
        return .granted
    }

    private func handleFSEvent(path: String, flags: FSEventStreamEventFlags) {
        // Map FSEvents flag bitmask to a string action. Multiple bits may be set;
        // pick the most specific.
        var action: String? = nil
        if (flags & UInt32(kFSEventStreamEventFlagItemRemoved)) != 0 {
            action = "removed"
        } else if (flags & UInt32(kFSEventStreamEventFlagItemRenamed)) != 0 {
            action = "renamed"
        } else if (flags & UInt32(kFSEventStreamEventFlagItemCreated)) != 0 {
            action = "created"
        } else if (flags & UInt32(kFSEventStreamEventFlagItemModified)) != 0 {
            action = "modified"
        }
        guard let action else { return }

        // Skip directories (we only want file activity).
        if (flags & UInt32(kFSEventStreamEventFlagItemIsDir)) != 0 { return }

        // Skip hidden files and system noise.
        let leaf = (path as NSString).lastPathComponent
        if leaf.hasPrefix(".") { return }
        if path.contains("/.git/") || path.contains("/node_modules/") { return }

        // Token: file:<ext>@<dir-sha1-prefix>
        let dir = (path as NSString).deletingLastPathComponent
        let ext = (leaf as NSString).pathExtension.lowercased()
        let dirHashPrefix = String(stableHash(dir).prefix(6))
        let token = "file:\(ext.isEmpty ? "noext" : ext)@\(dirHashPrefix)"

        let inode = try? FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? Int

        do {
            _ = try EventStore.shared.writeFileEvent(
                ts: Date(),
                path: path,
                action: action,
                inode: Int64(inode ?? 0),
                fileExt: ext.isEmpty ? nil : ext,
                token: token
            )
            EventBus.shared.emit(EmittedEvent(
                source: .file,
                type: "file.\(action)",
                token: token,
                appName: nil,
                bundleID: nil,
                windowTitle: leaf
            ))
        } catch {
            log.error("File write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stableHash(_ s: String) -> String {
        // Simple FNV-1a 64-bit hash, hex encoded. Stable across processes.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

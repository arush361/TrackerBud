import Foundation

/// Stream of tracker-emitted records about to be persisted. Subscribers can
/// observe live activity for UI updates. The actual database write happens
/// in `EventStore`; the bus is purely a notification fan-out.
public struct EmittedEvent: Sendable {
    public let ts: Date
    public let source: EventSource
    public let type: String
    public let token: String
    public let appName: String?
    public let bundleID: String?
    public let windowTitle: String?

    public init(
        ts: Date = Date(),
        source: EventSource,
        type: String,
        token: String,
        appName: String? = nil,
        bundleID: String? = nil,
        windowTitle: String? = nil
    ) {
        self.ts = ts
        self.source = source
        self.type = type
        self.token = token
        self.appName = appName
        self.bundleID = bundleID
        self.windowTitle = windowTitle
    }
}

public final class EventBus: @unchecked Sendable {
    public static let shared = EventBus()

    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<EmittedEvent>.Continuation] = [:]

    public init() {}

    public func emit(_ event: EmittedEvent) {
        lock.lock()
        let conts = Array(continuations.values)
        lock.unlock()
        for c in conts { c.yield(event) }
    }

    public func stream() -> AsyncStream<EmittedEvent> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { @Sendable [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }
}

import Foundation

/// A pending outbound request, serialised when offline.
struct QueuedEvent: Codable, Sendable {
    enum EventKind: String, Codable {
        case track     // POST /attribr-track
        case attribute // POST /attribr-attribute
        case event     // POST /attribr-track (custom event payload)
        case delete    // DELETE /attribr-delete-user-data
    }

    let id: String           // UUID string for deduplication
    let kind: EventKind
    let payload: Data        // JSON-encoded request body
    let enqueuedAt: Date
    var attempts: Int
}

/// Thread-safe offline-resilient queue backed by `UserDefaults`.
///
/// - Max 500 events. When full, the **oldest** event is evicted.
/// - Events are flushed in FIFO order whenever the network is available.
/// - Persists across app restarts.
final class EventQueue: @unchecked Sendable {
    private let defaultsKey = "com.mrvltechnologies.attribr.queue"
    private let lock = NSLock()
    private let maxSize: Int
    private var events: [QueuedEvent] = []
    private let logger: AttribrLogger

    init(maxSize: Int = 500, logger: AttribrLogger) {
        self.maxSize = maxSize
        self.logger = logger
        self.events = Self.load()
    }

    // MARK: - Enqueue

    func enqueue(_ event: QueuedEvent) {
        lock.withLock {
            if events.count >= maxSize {
                logger.debug("Queue full — dropping oldest event")
                events.removeFirst()
            }
            events.append(event)
            persist()
        }
    }

    // MARK: - Drain

    /// Returns all queued events in FIFO order without removing them.
    func peek() -> [QueuedEvent] {
        lock.withLock { events }
    }

    /// Marks an event as successfully delivered and removes it.
    func remove(id: String) {
        lock.withLock {
            events.removeAll { $0.id == id }
            persist()
        }
    }

    /// Increments the attempt counter for a failed event.
    func markFailed(id: String) {
        lock.withLock {
            if let idx = events.firstIndex(where: { $0.id == id }) {
                events[idx].attempts += 1
            }
            persist()
        }
    }

    var count: Int {
        lock.withLock { events.count }
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private static func load() -> [QueuedEvent] {
        guard
            let data = UserDefaults.standard.data(forKey: "com.mrvltechnologies.attribr.queue"),
            let events = try? JSONDecoder().decode([QueuedEvent].self, from: data)
        else { return [] }
        return events
    }
}

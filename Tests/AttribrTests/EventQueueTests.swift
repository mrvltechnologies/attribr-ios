import XCTest
@testable import Attribr

final class EventQueueTests: XCTestCase {
    private let defaultsKey = "com.mrvltechnologies.attribr.queue"

    private func makeQueue(maxSize: Int = 500) -> EventQueue {
        let logger = AttribrLogger(enabled: false)
        return EventQueue(maxSize: maxSize, logger: logger)
    }

    private func makeEvent(kind: QueuedEvent.EventKind = .track) -> QueuedEvent {
        let payload = try! JSONSerialization.data(withJSONObject: ["test": "value"])
        return QueuedEvent(
            id: UUID().uuidString,
            kind: kind,
            payload: payload,
            enqueuedAt: Date(),
            attempts: 0
        )
    }

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        super.tearDown()
    }

    func testStartsEmpty() {
        let q = makeQueue()
        XCTAssertEqual(q.count, 0)
    }

    func testEnqueueAndPeek() {
        let q = makeQueue()
        let event = makeEvent()
        q.enqueue(event)
        XCTAssertEqual(q.count, 1)
        XCTAssertEqual(q.peek().first?.id, event.id)
    }

    func testRemove() {
        let q = makeQueue()
        let event = makeEvent()
        q.enqueue(event)
        q.remove(id: event.id)
        XCTAssertEqual(q.count, 0)
    }

    func testMarkFailed() {
        let q = makeQueue()
        let event = makeEvent()
        q.enqueue(event)
        q.markFailed(id: event.id)
        XCTAssertEqual(q.peek().first?.attempts, 1)
    }

    func testMaxSizeEvictsOldest() {
        let q = makeQueue(maxSize: 3)
        let e1 = makeEvent(); let e2 = makeEvent(); let e3 = makeEvent(); let e4 = makeEvent()
        q.enqueue(e1)
        q.enqueue(e2)
        q.enqueue(e3)
        q.enqueue(e4)  // should evict e1
        XCTAssertEqual(q.count, 3)
        XCTAssertFalse(q.peek().contains { $0.id == e1.id }, "Oldest event should be evicted")
        XCTAssertTrue(q.peek().contains { $0.id == e4.id }, "Newest event should be present")
    }

    func testFIFOOrdering() {
        let q = makeQueue()
        let e1 = makeEvent(); let e2 = makeEvent(); let e3 = makeEvent()
        q.enqueue(e1); q.enqueue(e2); q.enqueue(e3)
        let peeked = q.peek()
        XCTAssertEqual(peeked[0].id, e1.id)
        XCTAssertEqual(peeked[1].id, e2.id)
        XCTAssertEqual(peeked[2].id, e3.id)
    }

    func testPersistsToUserDefaults() {
        let q1 = makeQueue()
        let event = makeEvent()
        q1.enqueue(event)

        // New instance reads from same UserDefaults key
        let q2 = makeQueue()
        XCTAssertEqual(q2.count, 1)
        XCTAssertEqual(q2.peek().first?.id, event.id)
    }

    func testAllEventKinds() {
        let q = makeQueue()
        for kind in [QueuedEvent.EventKind.track, .attribute, .event, .delete] {
            q.enqueue(makeEvent(kind: kind))
        }
        XCTAssertEqual(q.count, 4)
    }

    func testRemoveUnknownIdIsNoOp() {
        let q = makeQueue()
        q.enqueue(makeEvent())
        q.remove(id: "nonexistent-id")
        XCTAssertEqual(q.count, 1)
    }
}

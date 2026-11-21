import Foundation

/// Thread-safe, process-local epoch for all optional analytics work.
/// A consent withdrawal permanently invalidates every task and queue snapshot
/// created before it, even if the user later grants consent again.
///
/// An already-started HTTP request cannot be recalled by a consent check.
/// This guard prevents NEW attempts, retries and re-queuing of stale payloads.
final class ConsentGeneration: @unchecked Sendable {
    static let shared = ConsentGeneration()

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var state: ConsentState = .unknown

    private init() {}

    func snapshot() -> UInt64 { lock.withLock { generation } }

    func permits(_ expected: UInt64) -> Bool {
        lock.withLock { generation == expected && state == .granted }
    }

    func sameGeneration(_ expected: UInt64) -> Bool {
        lock.withLock { generation == expected }
    }

    func transition(to newState: ConsentState) {
        lock.withLock {
            if newState != .granted {
                // Do not reuse an epoch on regrant. This includes an explicit
                // .revoked while already revoked, and resetting legacy implied
                // consent to .unknown on app startup.
                generation &+= 1
            }
            state = newState
        }
    }

    func adoptInitialState(_ current: ConsentState) {
        lock.withLock {
            generation &+= 1
            state = current
        }
    }

    func resetForTests() {
        lock.withLock {
            generation &+= 1
            state = .unknown
        }
    }
}

/// Task-local origin for work spawned while permission was valid.
/// Child async calls inherit this value across awaits and retry backoffs.
enum AttribrTelemetryContext {
    @TaskLocal static var generation: UInt64?
}

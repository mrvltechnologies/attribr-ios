import Foundation

/// Only local, app-scoped ratings state is stored here. No identity, photo
/// content, review text, sentiment, or remote configuration is persisted.
public struct RatingsStoreSnapshot: Sendable {
    public var state: RatingsLocalState
    public var requestAttemptHistory: [Date]

    public init(state: RatingsLocalState, requestAttemptHistory: [Date] = []) {
        self.state = state
        self.requestAttemptHistory = Array(requestAttemptHistory.sorted().suffix(8))
    }
}

public enum RatingsStorageError: Error, Equatable {
    case invalidNamespace
    case corruptSnapshot
    case unsupportedSchema
    case writeFailed
}

/// Isolated behind a protocol so every transition can be tested with a
/// throwing store. Implementations MUST throw on an unreadable snapshot;
/// silently resetting it can reset a review-request cooldown.
@MainActor
public protocol RatingsStateStore {
    func load() throws -> RatingsStoreSnapshot?
    func save(_ snapshot: RatingsStoreSnapshot) throws
}

/// A product-local state store. This deliberately does not use Attribr's
/// installation identity, analytics event queue, or network services.
/// UserDefaults is best-effort persistence; it is not an fsync transaction.
@MainActor
public final class RatingsUserDefaultsStore: RatingsStateStore {
    private let defaults: UserDefaults
    private let key: String

    public init(namespace: String, defaults: UserDefaults = .standard) throws {
        guard !namespace.isEmpty, namespace.count <= 128,
              namespace.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || $0 == 46 || $0 == 45 || $0 == 95
              }) else {
            throw RatingsStorageError.invalidNamespace
        }
        self.defaults = defaults
        self.key = "mrvl.ratings.state.v1." + namespace
    }

    public func load() throws -> RatingsStoreSnapshot? {
        guard let stored = defaults.object(forKey: key) else { return nil }
        guard let data = stored as? Data else { throw RatingsStorageError.corruptSnapshot }
        let wire: WireSnapshot
        do { wire = try JSONDecoder().decode(WireSnapshot.self, from: data) }
        catch { throw RatingsStorageError.corruptSnapshot }
        guard wire.schema == 1 else { throw RatingsStorageError.unsupportedSchema }
        guard wire.confirmedWins >= 0, wire.sessionCount >= 0,
              wire.receiptIDs.count <= 64, wire.requestAttemptHistory.count <= 8,
              wire.receiptIDs.count == Set(wire.receiptIDs).count,
              wire.requestAttemptHistory.allSatisfy({ $0.timeIntervalSince1970.isFinite }) else {
            throw RatingsStorageError.corruptSnapshot
        }
        return RatingsStoreSnapshot(
            state: RatingsLocalState(
                confirmedWins: wire.confirmedWins,
                sessionCount: wire.sessionCount,
                firstSeenAt: wire.firstSeenAt,
                lastRequestAttemptAt: wire.lastRequestAttemptAt,
                attemptedThisLaunch: false, // only in-memory for this launch
                lastFailureAt: wire.lastFailureAt,
                lastCrashAt: wire.lastCrashAt,
                recentReceiptIDs: wire.receiptIDs
            ),
            requestAttemptHistory: wire.requestAttemptHistory
        )
    }

    public func save(_ snapshot: RatingsStoreSnapshot) throws {
        let state = snapshot.state
        let wire = WireSnapshot(
            schema: 1,
            confirmedWins: state.confirmedWins,
            sessionCount: state.sessionCount,
            firstSeenAt: state.firstSeenAt,
            lastRequestAttemptAt: state.lastRequestAttemptAt,
            lastFailureAt: state.lastFailureAt,
            lastCrashAt: state.lastCrashAt,
            receiptIDs: Array(state.recentReceiptIDs.suffix(64)),
            requestAttemptHistory: Array(snapshot.requestAttemptHistory.sorted().suffix(8))
        )
        let data = try JSONEncoder().encode(wire)
        defaults.set(data, forKey: key)
        guard defaults.data(forKey: key) == data else {
            throw RatingsStorageError.writeFailed
        }
    }
}

private struct WireSnapshot: Codable {
    let schema: Int
    let confirmedWins: Int
    let sessionCount: Int
    let firstSeenAt: Date?
    let lastRequestAttemptAt: Date?
    let lastFailureAt: Date?
    let lastCrashAt: Date?
    let receiptIDs: [UUID]
    let requestAttemptHistory: [Date]
}

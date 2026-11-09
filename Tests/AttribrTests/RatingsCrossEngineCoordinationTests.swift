import Foundation
import XCTest
@testable import Attribr

/// Exact Berea P1-001 regression: both engines exist BEFORE either reserves.
/// Uses the real RatingsEngine and the same production state-store protocol.
@MainActor
private final class CoordinatedRatingsFakeStore: RatingsStateStore {
    var snapshot: RatingsStoreSnapshot?
    var failWrites = false
    var failReads = false
    var persistLaunchFlag = false
    var writes = 0
    var onSave: (() -> Void)?

    func load() throws -> RatingsStoreSnapshot? {
        if failReads { throw RatingsStorageError.corruptSnapshot }
        return snapshot
    }

    // Production stores (RatingsUserDefaultsStore) NEVER persist
    // attemptedThisLaunch; it is process memory only. The double must match,
    // otherwise cross-engine/restart tests pass or fail for the wrong reason.
    private func normalised(_ s: RatingsStoreSnapshot) -> RatingsStoreSnapshot {
        var c = s
        c.state.attemptedThisLaunch = false
        return c
    }

    func save(_ next: RatingsStoreSnapshot) throws {
        if failWrites { throw RatingsStorageError.writeFailed }
        snapshot = persistLaunchFlag ? next : normalised(next)
        writes += 1
        onSave?()
    }
}

@MainActor
final class RatingsCrossEngineCoordinationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func policy(cooldown: Int = 90) -> RatingsPolicy {
        RatingsPolicy(version: "berea-p1-v1", mode: .active,
                      minimumConfirmedWins: 1, cooldownDays: cooldown)
    }

    private func opportunity(_ time: Date? = nil) -> RatingsOpportunity {
        RatingsOpportunity(now: time ?? now, isForeground: true,
                           hasConfirmedValueMoment: true)
    }

    private func prepare(_ engine: RatingsEngine, receipt: UUID = UUID()) throws {
        try engine.beginSession(now: now)
        XCTAssertTrue(try engine.recordConfirmedValueMoment(
            .init(receiptID: receipt, strength: .strong, isConfirmed: true)))
    }

    func testTwoPreconstructedEnginesCountOneSessionPerProcessNamespace() throws {
        let store = CoordinatedRatingsFakeStore()
        let a = try RatingsEngine(policy: policy(), store: store,
                                  activeRequestsAuthorised: true)
        let b = try RatingsEngine(policy: policy(), store: store,
                                  activeRequestsAuthorised: true)

        XCTAssertTrue(try a.beginSession(now: now))
        XCTAssertFalse(try b.beginSession(now: now.addingTimeInterval(10)))
        XCTAssertEqual(try store.load()?.state.sessionCount, 1)
        XCTAssertEqual(a.state.sessionCount, 1)
        XCTAssertEqual(b.state.sessionCount, 1)

        // The joining engine is still part of the active process session and
        // can record value without creating a second persisted session.
        XCTAssertTrue(try b.recordConfirmedValueMoment(
            .init(receiptID: UUID(), strength: .strong, isConfirmed: true)))
        XCTAssertEqual(try store.load()?.state.confirmedWins, 1)
        XCTAssertEqual(try store.load()?.state.sessionCount, 1)
    }

    func testSeparateUserDefaultsHandlesCountOneSessionPerProcessNamespace() throws {
        let suite = "ratings.sessions." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let namespace = "com.mrvl.sessions." + UUID().uuidString
        let storeA = try RatingsUserDefaultsStore(namespace: namespace, defaults: defaults)
        let storeB = try RatingsUserDefaultsStore(namespace: namespace, defaults: defaults)
        let a = try RatingsEngine(policy: policy(), store: storeA)
        let b = try RatingsEngine(policy: policy(), store: storeB)

        XCTAssertTrue(try a.beginSession(now: now))
        XCTAssertFalse(try b.beginSession(now: now.addingTimeInterval(30)))
        XCTAssertEqual(try storeA.load()?.state.sessionCount, 1)
        XCTAssertEqual(try storeB.load()?.state.sessionCount, 1)
    }

    func testMinimumSessionsCannotBeSatisfiedByTwoEnginesInOneProcess() throws {
        let p = RatingsPolicy(
            version: "session-threshold-v1",
            mode: .active,
            minimumConfirmedWins: 1,
            minimumSessions: 2,
            cooldownDays: 0
        )
        let store = CoordinatedRatingsFakeStore()
        let a = try RatingsEngine(policy: p, store: store, activeRequestsAuthorised: true)
        let b = try RatingsEngine(policy: p, store: store, activeRequestsAuthorised: true)

        XCTAssertTrue(try a.beginSession(now: now))
        XCTAssertFalse(try b.beginSession(now: now))
        XCTAssertTrue(try b.recordConfirmedValueMoment(
            .init(receiptID: UUID(), strength: .strong, isConfirmed: true)))

        var calls = 0
        XCTAssertEqual(b.requestIfEligible(opportunity()) {
            calls += 1
            return true
        }, .suppressed(.insufficientSessions))
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(try store.load()?.state.sessionCount, 1)

        RatingsEngine.resetProcessReservationForTesting(store: store)
        let nextProcess = try RatingsEngine(
            policy: p, store: store, activeRequestsAuthorised: true)
        XCTAssertTrue(try nextProcess.beginSession(now: now.addingTimeInterval(86_400)))
        XCTAssertTrue(try nextProcess.recordConfirmedValueMoment(
            .init(receiptID: UUID(), strength: .strong, isConfirmed: true)))
        XCTAssertEqual(nextProcess.requestIfEligible(
            opportunity(now.addingTimeInterval(86_400))) {
                calls += 1
                return true
            }, .nativeRequestInvoked)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try store.load()?.state.sessionCount, 2)
    }

    func testFailedSessionPersistenceReleasesReservationForAnotherEngine() throws {
        let store = CoordinatedRatingsFakeStore()
        let a = try RatingsEngine(policy: policy(), store: store)
        let b = try RatingsEngine(policy: policy(), store: store)

        store.failWrites = true
        XCTAssertThrowsError(try a.beginSession(now: now))
        XCTAssertNil(try store.load())

        store.failWrites = false
        XCTAssertTrue(try b.beginSession(now: now))
        XCTAssertEqual(try store.load()?.state.sessionCount, 1)
    }

    func testSimulatedProcessRestartAddsExactlyOneNewSession() throws {
        let store = CoordinatedRatingsFakeStore()
        let first = try RatingsEngine(policy: policy(), store: store)
        let sameProcess = try RatingsEngine(policy: policy(), store: store)

        XCTAssertTrue(try first.beginSession(now: now))
        XCTAssertFalse(try sameProcess.beginSession(now: now))
        XCTAssertEqual(try store.load()?.state.sessionCount, 1)

        RatingsEngine.resetProcessReservationForTesting(store: store)

        let nextProcessA = try RatingsEngine(policy: policy(), store: store)
        let nextProcessB = try RatingsEngine(policy: policy(), store: store)
        XCTAssertTrue(try nextProcessA.beginSession(now: now.addingTimeInterval(86_400)))
        XCTAssertFalse(try nextProcessB.beginSession(now: now.addingTimeInterval(86_400)))
        XCTAssertEqual(try store.load()?.state.sessionCount, 2)
    }

    func testBereaTwoPreconstructedEnginesShareOneReservationAndKeepBothWins() throws {
        let store = CoordinatedRatingsFakeStore()
        let a = try RatingsEngine(policy: policy(), store: store,
                                  activeRequestsAuthorised: true)
        let b = try RatingsEngine(policy: policy(), store: store,
                                  activeRequestsAuthorised: true) // before A reserves
        let first = UUID(), second = UUID()
        try prepare(a, receipt: first)
        try prepare(b, receipt: second)
        var nativeCalls = 0

        XCTAssertEqual(a.requestIfEligible(opportunity()) {
            nativeCalls += 1; return true
        }, .nativeRequestInvoked)
        XCTAssertEqual(b.requestIfEligible(opportunity()) {
            nativeCalls += 1; return true
        }, .suppressed(.cooldown))
        XCTAssertEqual(nativeCalls, 1)
        let persisted = try XCTUnwrap(store.load())
        XCTAssertEqual(persisted.state.confirmedWins, 2)
        XCTAssertEqual(Set(persisted.state.recentReceiptIDs), Set([first, second]))
        XCTAssertEqual(persisted.requestAttemptHistory, [now])
        XCTAssertEqual(persisted.state.lastRequestAttemptAt, now)
    }

    func testTwoDifferentUserDefaultsStoreObjectsSameNamespace() throws {
        let suite = "ratings.berea." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let namespace = "com.mrvl.berea." + UUID().uuidString
        let storeA = try RatingsUserDefaultsStore(namespace: namespace, defaults: defaults)
        let storeB = try RatingsUserDefaultsStore(namespace: namespace, defaults: defaults)
        XCTAssertEqual(storeA.ratingsCoordinationKey, storeB.ratingsCoordinationKey)
        let a = try RatingsEngine(policy: policy(cooldown: 0), store: storeA,
                                  activeRequestsAuthorised: true)
        let b = try RatingsEngine(policy: policy(cooldown: 0), store: storeB,
                                  activeRequestsAuthorised: true)
        try prepare(a)
        try prepare(b)
        var nativeCalls = 0
        XCTAssertEqual(a.requestIfEligible(opportunity()) {
            nativeCalls += 1; return true
        }, .nativeRequestInvoked)
        XCTAssertEqual(b.requestIfEligible(opportunity()) {
            nativeCalls += 1; return true
        }, .suppressed(.alreadyAttemptedThisLaunch))
        XCTAssertEqual(nativeCalls, 1)
        XCTAssertEqual(try storeB.load()?.state.confirmedWins, 2)
        XCTAssertEqual(try storeB.load()?.requestAttemptHistory, [now])
    }

    func testStaleEngineCannotOverwriteReceiptsFailureCrashOrAttemptHistory() throws {
        let store = CoordinatedRatingsFakeStore()
        let a = try RatingsEngine(policy: policy(), store: store,
                                  activeRequestsAuthorised: true)
        let b = try RatingsEngine(policy: policy(), store: store,
                                  activeRequestsAuthorised: true)
        let ids = (0..<3).map { _ in UUID() }
        try prepare(a, receipt: ids[0])
        try prepare(b, receipt: ids[1])
        try a.noteFailure(at: now.addingTimeInterval(-7200))
        try b.noteCrashEvidence(at: now.addingTimeInterval(-7200))
        XCTAssertEqual(a.requestIfEligible(opportunity()) { true }, .nativeRequestInvoked)
        try b.recordConfirmedValueMoment(
            .init(receiptID: ids[2], strength: .standard, isConfirmed: true))
        let saved = try XCTUnwrap(store.load())
        XCTAssertEqual(saved.state.confirmedWins, 3)
        XCTAssertEqual(Set(saved.state.recentReceiptIDs), Set(ids))
        XCTAssertEqual(saved.state.lastFailureAt, now.addingTimeInterval(-7200))
        XCTAssertEqual(saved.state.lastCrashAt, now.addingTimeInterval(-7200))
        XCTAssertEqual(saved.state.lastRequestAttemptAt, now)
        XCTAssertEqual(saved.requestAttemptHistory, [now])
        XCTAssertNotNil(saved.state.firstSeenAt)
        // Two engines in one process share ONE persisted session (process-scoped
        // session coordination, 5a3b0c9); it must not be inflated to 2.
        XCTAssertEqual(saved.state.sessionCount, 1)
    }

    func testZeroDayCooldownStillAllowsOnlyOneRequestPerLaunch() throws {
        let store = CoordinatedRatingsFakeStore()
        let a = try RatingsEngine(policy: policy(cooldown: 0), store: store,
                                  activeRequestsAuthorised: true)
        let b = try RatingsEngine(policy: policy(cooldown: 0), store: store,
                                  activeRequestsAuthorised: true)
        try prepare(a)
        try prepare(b)
        var nativeCalls = 0
        XCTAssertEqual(a.requestIfEligible(opportunity()) {
            nativeCalls += 1; return true
        }, .nativeRequestInvoked)
        XCTAssertEqual(b.requestIfEligible(opportunity()) {
            nativeCalls += 1; return true
        }, .suppressed(.alreadyAttemptedThisLaunch))
        XCTAssertEqual(nativeCalls, 1)
    }

    func testTwoSchedulersBoundToTwoPreconstructedEnginesCannotDoubleInvoke() async throws {
        let store = CoordinatedRatingsFakeStore()
        let a = try RatingsEngine(policy: policy(cooldown: 0), store: store,
                                  activeRequestsAuthorised: true)
        let b = try RatingsEngine(policy: policy(cooldown: 0), store: store,
                                  activeRequestsAuthorised: true)
        try prepare(a)
        try prepare(b)
        var calls = 0
        let first = RatingsOpportunityScheduler()
        let second = RatingsOpportunityScheduler()
        first.schedule(engine: a, delayNanoseconds: 700_000_000,
                       currentOpportunity: { self.opportunity() },
                       nativeRequest: { calls += 1; return true })
        second.schedule(engine: b, delayNanoseconds: 700_000_000,
                        currentOpportunity: { self.opportunity() },
                        nativeRequest: { calls += 1; return true })
        try await Task.sleep(nanoseconds: 1_200_000_000)
        first.cancel()
        second.cancel()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try store.load()?.requestAttemptHistory.count, 1)
    }

    func testPersistenceFailureDoesNotSetLaunchReservationAndLaterRetryWorks() throws {
        let store = CoordinatedRatingsFakeStore()
        let a = try RatingsEngine(policy: policy(cooldown: 0), store: store,
                                  activeRequestsAuthorised: true)
        let b = try RatingsEngine(policy: policy(cooldown: 0), store: store,
                                  activeRequestsAuthorised: true)
        try prepare(a)
        try prepare(b)
        store.failWrites = true
        var nativeCalls = 0
        XCTAssertEqual(a.requestIfEligible(opportunity()) {
            nativeCalls += 1; return true
        }, .persistenceUnavailable)
        XCTAssertEqual(nativeCalls, 0)
        XCTAssertNil(try store.load()?.state.lastRequestAttemptAt)
        store.failWrites = false
        XCTAssertEqual(b.requestIfEligible(opportunity()) {
            nativeCalls += 1; return true
        }, .nativeRequestInvoked)
        XCTAssertEqual(nativeCalls, 1)
        XCTAssertEqual(try store.load()?.state.confirmedWins, 2)
    }

    func testReentrantStoreSaveCannotCauseSecondNativeInvocation() throws {
        let store = CoordinatedRatingsFakeStore()
        let a = try RatingsEngine(policy: policy(cooldown: 0), store: store,
                                  activeRequestsAuthorised: true)
        let b = try RatingsEngine(policy: policy(cooldown: 0), store: store,
                                  activeRequestsAuthorised: true)
        try prepare(a)
        try prepare(b)
        var calls = 0
        var attemptedReentry = false
        store.onSave = {
            guard !attemptedReentry else { return }
            attemptedReentry = true
            let result = b.requestIfEligible(self.opportunity()) {
                calls += 1; return true
            }
            XCTAssertEqual(result, .suppressed(.alreadyAttemptedThisLaunch))
        }
        XCTAssertEqual(a.requestIfEligible(opportunity()) {
            calls += 1; return true
        }, .nativeRequestInvoked)
        XCTAssertTrue(attemptedReentry)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try store.load()?.requestAttemptHistory.count, 1)
    }

    func testReadFailureFailsClosedWithoutNativeCallOrStateReplacement() throws {
        let store = CoordinatedRatingsFakeStore()
        let engine = try RatingsEngine(policy: policy(), store: store,
                                       activeRequestsAuthorised: true)
        try prepare(engine)
        store.failReads = true
        var calls = 0
        XCTAssertEqual(engine.requestIfEligible(opportunity()) {
            calls += 1; return true
        }, .persistenceUnavailable)
        XCTAssertEqual(calls, 0)
        store.failReads = false
        XCTAssertEqual(try store.load()?.state.confirmedWins, 1)
    }

    func testPreconstructedLegacyImportCannotResetAnotherEnginesCooldown() throws {
        let store = CoordinatedRatingsFakeStore()
        let a = try RatingsEngine(store: store)
        let b = try RatingsEngine(store: store)
        let previous = now.addingTimeInterval(-86_400)
        XCTAssertTrue(try a.importLegacyStateIfUninitialised(
            confirmedWins: 9, lastRequestAttemptAt: previous, now: now))
        XCTAssertFalse(try b.importLegacyStateIfUninitialised(
            confirmedWins: 0, lastRequestAttemptAt: nil, now: now))
        try b.beginSession(now: now)
        XCTAssertEqual(try store.load()?.state.confirmedWins, 9)
        XCTAssertEqual(try store.load()?.state.lastRequestAttemptAt, previous)
        XCTAssertEqual(try store.load()?.requestAttemptHistory, [previous])
    }

    func testReconstructionCooldownAndTrueProcessRestartSimulation() throws {
        let store = CoordinatedRatingsFakeStore()
        let a = try RatingsEngine(policy: policy(cooldown: 90), store: store,
                                  activeRequestsAuthorised: true)
        try prepare(a)
        XCTAssertEqual(a.requestIfEligible(opportunity()) { true }, .nativeRequestInvoked)
        let b = try RatingsEngine(policy: policy(cooldown: 90), store: store,
                                  activeRequestsAuthorised: true)
        try b.beginSession(now: now.addingTimeInterval(86_400))
        try b.recordConfirmedValueMoment(
            .init(receiptID: UUID(), strength: .standard, isConfirmed: true))
        XCTAssertEqual(b.requestIfEligible(opportunity(now.addingTimeInterval(86_400))) { true },
                       .suppressed(.cooldown))
        // A real new process starts with a fresh reservation ledger; this
        // INTERNAL test seam simulates that without weakening persisted state.
        RatingsEngine.resetProcessReservationForTesting(store: store)
        let c = try RatingsEngine(policy: policy(cooldown: 90), store: store,
                                  activeRequestsAuthorised: true)
        let later = Calendar(identifier: .gregorian).date(byAdding: .day, value: 91, to: now)!
        try c.beginSession(now: later)
        try c.recordConfirmedValueMoment(
            .init(receiptID: UUID(), strength: .standard, isConfirmed: true))
        XCTAssertEqual(c.requestIfEligible(opportunity(later)) { true },
                       .nativeRequestInvoked)
        XCTAssertEqual(try store.load()?.requestAttemptHistory.count, 2)
    }

    /// A custom store that (wrongly for a launch flag, but legally) persists the
    /// entire snapshot including attemptedThisLaunch must not carry that flag
    /// into a new launch.
    func testStoreThatPersistsLaunchFlagDoesNotSuppressNextLaunch() throws {
        let store = CoordinatedRatingsFakeStore()
        store.persistLaunchFlag = true
        let a = try RatingsEngine(policy: policy(cooldown: 0), store: store,
                                  activeRequestsAuthorised: true)
        try prepare(a)
        XCTAssertEqual(a.requestIfEligible(opportunity()) { true }, .nativeRequestInvoked)
        XCTAssertTrue(try XCTUnwrap(store.load()).state.attemptedThisLaunch)
        RatingsEngine.resetProcessReservationForTesting(store: store) // new process
        let b = try RatingsEngine(policy: policy(cooldown: 0), store: store,
                                  activeRequestsAuthorised: true)
        try b.beginSession(now: now)
        try b.recordConfirmedValueMoment(
            .init(receiptID: UUID(), strength: .standard, isConfirmed: true))
        XCTAssertEqual(b.requestIfEligible(opportunity()) { true }, .nativeRequestInvoked)
    }
}

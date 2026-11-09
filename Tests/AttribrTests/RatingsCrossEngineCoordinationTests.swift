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
    var writes = 0

    func load() throws -> RatingsStoreSnapshot? {
        if failReads { throw RatingsStorageError.corruptSnapshot }
        return snapshot
    }

    func save(_ next: RatingsStoreSnapshot) throws {
        if failWrites { throw RatingsStorageError.writeFailed }
        snapshot = next
        writes += 1
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
        XCTAssertGreaterThanOrEqual(saved.state.sessionCount, 2)
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
}

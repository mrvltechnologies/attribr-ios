import Foundation
import XCTest
@testable import Attribr

@MainActor
private final class RatingsFakeStore: RatingsStateStore {
    var snapshot: RatingsStoreSnapshot?
    var failLoad = false
    var failWrite = false
    var writes = 0

    init(_ snapshot: RatingsStoreSnapshot? = nil) { self.snapshot = snapshot }

    func load() throws -> RatingsStoreSnapshot? {
        if failLoad { throw RatingsStorageError.corruptSnapshot }
        return snapshot
    }

    func save(_ value: RatingsStoreSnapshot) throws {
        if failWrite { throw RatingsStorageError.writeFailed }
        writes += 1
        snapshot = value
    }
}

@MainActor
final class RatingsEngineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func activePolicy() -> RatingsPolicy {
        RatingsPolicy(version: "test-v1", mode: .active,
            minimumConfirmedWins: 1, cooldownDays: 30)
    }

    private func opportunity(_ now: Date, foreground: Bool = true) -> RatingsOpportunity {
        RatingsOpportunity(now: now, isForeground: foreground, hasConfirmedValueMoment: true)
    }

    func testDefaultShadowCannotRequestNativeReview() {
        let store = RatingsFakeStore()
        let engine = try! RatingsEngine(store: store)
        try! engine.beginSession(now: now)
        try! engine.recordConfirmedValueMoment(
            .init(receiptID: UUID(), strength: .strong, isConfirmed: true))
        var nativeCalls = 0
        let outcome = engine.requestIfEligible(opportunity(now)) {
            nativeCalls += 1
            return true
        }
        XCTAssertEqual(outcome, .suppressed(.insufficientWins))
        XCTAssertEqual(nativeCalls, 0)
    }

    func testEligibleShadowNeverCallsNativeBridge() {
        let engine = try! RatingsEngine(store: RatingsFakeStore())
        try! engine.beginSession(now: now)
        for _ in 0..<3 {
            try! engine.recordConfirmedValueMoment(.init(
                receiptID: UUID(), strength: .standard, isConfirmed: true))
        }
        XCTAssertTrue(engine.evaluate(opportunity(now)).isEligible)
        XCTAssertFalse(engine.evaluate(opportunity(now)).mayRequestNativeReview)
        var calls = 0
        XCTAssertEqual(engine.requestIfEligible(opportunity(now)) {
            calls += 1
            return true
        }, .shadowOnly)
        XCTAssertEqual(calls, 0)
    }

    func testActivePolicyStillRequiresExplicitProductAuthorisation() {
        let engine = try! RatingsEngine(policy: activePolicy(), store: RatingsFakeStore())
        try! engine.beginSession(now: now)
        try! engine.recordConfirmedValueMoment(.init(
            receiptID: UUID(), strength: .strong, isConfirmed: true))
        var calls = 0
        XCTAssertEqual(engine.requestIfEligible(opportunity(now)) {
            calls += 1
            return true
        }, .activeNotAuthorised)
        XCTAssertEqual(calls, 0)
    }

    func testNativeRequestIsPersistedBeforeExactlyOneInvocation() {
        let store = RatingsFakeStore()
        let engine = try! RatingsEngine(
            policy: activePolicy(), store: store, activeRequestsAuthorised: true)
        try! engine.beginSession(now: now)
        try! engine.recordConfirmedValueMoment(.init(
            receiptID: UUID(), strength: .strong, isConfirmed: true))
        var calls = 0
        XCTAssertEqual(engine.requestIfEligible(opportunity(now)) {
            calls += 1
            XCTAssertEqual(store.snapshot?.state.lastRequestAttemptAt, now)
            XCTAssertEqual(store.snapshot?.requestAttemptHistory.count, 1)
            return true
        }, .nativeRequestInvoked)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(engine.requestIfEligible(opportunity(now)) {
            calls += 1
            return true
        }, .suppressed(.alreadyAttemptedThisLaunch))
        XCTAssertEqual(calls, 1)
    }

    func testFailedWriteNeverInvokesNativeOrAdvancesMemory() {
        let store = RatingsFakeStore()
        let engine = try! RatingsEngine(
            policy: activePolicy(), store: store, activeRequestsAuthorised: true)
        try! engine.beginSession(now: now)
        try! engine.recordConfirmedValueMoment(.init(
            receiptID: UUID(), strength: .standard, isConfirmed: true))
        store.failWrite = true
        var calls = 0
        XCTAssertEqual(engine.requestIfEligible(opportunity(now)) {
            calls += 1
            return true
        }, .persistenceUnavailable)
        XCTAssertEqual(calls, 0)
        XCTAssertNil(engine.state.lastRequestAttemptAt)
        XCTAssertNil(store.snapshot?.state.lastRequestAttemptAt)
    }

    func testAnnualAttemptCapCannotBeBypassedByShortCooldown() {
        let history = (1...3).map { now.addingTimeInterval(TimeInterval(-$0 * 70 * 86_400)) }
        let store = RatingsFakeStore(.init(
            state: RatingsLocalState(confirmedWins: 2, sessionCount: 3),
            requestAttemptHistory: history))
        let engine = try! RatingsEngine(
            policy: activePolicy(), store: store, activeRequestsAuthorised: true)
        try! engine.beginSession(now: now)
        try! engine.recordConfirmedValueMoment(.init(
            receiptID: UUID(), strength: .standard, isConfirmed: true))
        var calls = 0
        XCTAssertEqual(engine.requestIfEligible(opportunity(now)) {
            calls += 1
            return true
        }, .annualAttemptLimit)
        XCTAssertEqual(calls, 0)
    }

    func testFutureAttemptHistoryFailsClosedOnClockRollback() {
        let store = RatingsFakeStore(.init(
            state: RatingsLocalState(confirmedWins: 3, sessionCount: 1),
            requestAttemptHistory: [now.addingTimeInterval(30)]))
        let engine = try! RatingsEngine(
            policy: activePolicy(), store: store, activeRequestsAuthorised: true)
        try! engine.beginSession(now: now)
        try! engine.recordConfirmedValueMoment(.init(
            receiptID: UUID(), strength: .strong, isConfirmed: true))
        XCTAssertEqual(engine.requestIfEligible(opportunity(now)) { true },
                       .suppressed(.clockRollback))
    }

    func testDuplicateReceiptAndNoSuccessEvidence() {
        let engine = try! RatingsEngine(
            policy: activePolicy(), store: RatingsFakeStore(), activeRequestsAuthorised: true)
        try! engine.beginSession(now: now)
        XCTAssertEqual(engine.requestIfEligible(opportunity(now)) { true },
                       .suppressed(.unconfirmedValueMoment))
        let id = UUID()
        XCTAssertFalse(try! engine.recordConfirmedValueMoment(.init(
            receiptID: id, strength: .strong, isConfirmed: false)))
        XCTAssertTrue(try! engine.recordConfirmedValueMoment(.init(
            receiptID: id, strength: .strong, isConfirmed: true)))
        XCTAssertFalse(try! engine.recordConfirmedValueMoment(.init(
            receiptID: id, strength: .strong, isConfirmed: true)))
        XCTAssertEqual(engine.state.confirmedWins, 1)
    }

    func testSessionIncrementsOnlyOnceAndRelaunchRetainsCooldown() {
        let store = RatingsFakeStore()
        let first = try! RatingsEngine(
            policy: activePolicy(), store: store, activeRequestsAuthorised: true)
        XCTAssertTrue(try! first.beginSession(now: now))
        XCTAssertFalse(try! first.beginSession(now: now))
        XCTAssertEqual(first.state.sessionCount, 1)
        try! first.recordConfirmedValueMoment(.init(
            receiptID: UUID(), strength: .standard, isConfirmed: true))
        XCTAssertEqual(first.requestIfEligible(opportunity(now)) { true },
                       .nativeRequestInvoked)
        // Simulate a genuine process relaunch. Constructing another engine
        // in the same process must not count as a new session.
        RatingsEngine.resetProcessReservationForTesting(store: store)
        let second = try! RatingsEngine(
            policy: activePolicy(), store: store, activeRequestsAuthorised: true)
        try! second.beginSession(now: now.addingTimeInterval(86_400))
        XCTAssertEqual(second.state.sessionCount, 2)
        XCTAssertFalse(second.state.attemptedThisLaunch)
        try! second.recordConfirmedValueMoment(.init(
            receiptID: UUID(), strength: .standard, isConfirmed: true))
        XCTAssertEqual(second.requestIfEligible(opportunity(now.addingTimeInterval(86_400))) { true },
                       .suppressed(.cooldown))
    }

    func testLegacyImportCannotResetExistingCooldown() {
        let store = RatingsFakeStore()
        let engine = try! RatingsEngine(store: store)
        let last = now.addingTimeInterval(-12 * 86_400)
        XCTAssertTrue(try! engine.importLegacyStateIfUninitialised(
            confirmedWins: 12, lastRequestAttemptAt: last, now: now))
        XCTAssertFalse(try! engine.importLegacyStateIfUninitialised(
            confirmedWins: 0, lastRequestAttemptAt: nil, now: now))
        XCTAssertEqual(engine.state.lastRequestAttemptAt, last)
        XCTAssertEqual(store.snapshot?.requestAttemptHistory.count, 1)
        let again = try! RatingsEngine(store: store)
        XCTAssertFalse(try! again.importLegacyStateIfUninitialised(
            confirmedWins: 0, lastRequestAttemptAt: nil, now: now))
        XCTAssertEqual(again.state.confirmedWins, 12)
    }

    func testNativeBridgeFailureKeepsConservativeCooldown() {
        let store = RatingsFakeStore()
        let engine = try! RatingsEngine(
            policy: activePolicy(), store: store, activeRequestsAuthorised: true)
        try! engine.beginSession(now: now)
        try! engine.recordConfirmedValueMoment(.init(
            receiptID: UUID(), strength: .standard, isConfirmed: true))
        XCTAssertEqual(engine.requestIfEligible(opportunity(now)) { false },
                       .bridgeUnavailableAfterReservation)
        XCTAssertEqual(store.snapshot?.requestAttemptHistory.count, 1)
        XCTAssertNotNil(engine.state.lastRequestAttemptAt)
    }

    func testBackgroundAndRecentFailureSuppressPrompt() {
        let p = RatingsPolicy(version:"safety-v1",mode:.active,minimumConfirmedWins:1,
                              cooldownDays:90,failureSuppressionSeconds:3600)
        let engine = try! RatingsEngine(
            policy:p,store:RatingsFakeStore(),activeRequestsAuthorised:true)
        try! engine.beginSession(now: now)
        try! engine.recordConfirmedValueMoment(.init(
            receiptID: UUID(), strength: .strong, isConfirmed:true))
        XCTAssertEqual(engine.requestIfEligible(opportunity(now,foreground:false)) { true },
                       .suppressed(.background))
        try! engine.noteFailure(at:now)
        XCTAssertEqual(engine.requestIfEligible(opportunity(now)) { true },
                       .suppressed(.recentFailure))
    }

    func testUserDefaultsStoreRejectsMalformedOrUnsupportedData() {
        let suite="ratings.engine.tests." + UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        XCTAssertThrowsError(try RatingsUserDefaultsStore(namespace:"bad/name",defaults:defaults))
        let store=try! RatingsUserDefaultsStore(namespace:"com.mrvl.demo",defaults:defaults)
        XCTAssertNil(try! store.load())
        defaults.set(Data("not-json".utf8),forKey:"mrvl.ratings.state.v1.com.mrvl.demo")
        XCTAssertThrowsError(try store.load())
        defaults.removeObject(forKey:"mrvl.ratings.state.v1.com.mrvl.demo")
        let state=RatingsLocalState(confirmedWins:3,sessionCount:2,
            lastRequestAttemptAt:now,recentReceiptIDs:[UUID()])
        try! store.save(.init(state:state,requestAttemptHistory:[now]))
        let saved=try! store.load()!
        XCTAssertEqual(saved.state.confirmedWins,3)
        XCTAssertEqual(saved.state.lastRequestAttemptAt,now)
        XCTAssertFalse(saved.state.attemptedThisLaunch)
        XCTAssertEqual(saved.requestAttemptHistory.count,1)
    }

    func testTelemetryForwarderRejectsWithoutBothExplicitPermissions() {
        let payload = RatingsTelemetryEvent(event:.valueMoment, mode:.shadow,
                                            policy:.cleanrLegacyParity,
                                            moment:.confirmedExport)
        XCTAssertFalse(RatingsAnalyticsForwarder.submitIfApproved(
            payload, productDisclosureApproved:false, analyticsConsentApproved:true))
        XCTAssertFalse(RatingsAnalyticsForwarder.submitIfApproved(
            payload, productDisclosureApproved:true, analyticsConsentApproved:false))
    }

    func testPrivacyContractUsesOnlyClosedFieldsWithoutNetwork() {
        let event=RatingsTelemetryEvent(
            event:.promptRequested,mode:.shadow,policy:.cleanrLegacyParity,
            moment:.confirmedExport,reason:.eligible)
        XCTAssertTrue(RatingsTelemetryContract.isApprovedShape(event))
        XCTAssertEqual(event.name,"ratings.prompt_requested")
        XCTAssertEqual(event.metadata.count,5)
        XCTAssertNil(event.metadata["review_text"])
        XCTAssertNil(event.metadata["device_id"])
        XCTAssertNil(event.metadata["rating_stars"])
    }
}

import Foundation
import XCTest
@testable import Attribr

@MainActor
private final class RatingsSchedulerStore: RatingsStateStore {
    var snapshot: RatingsStoreSnapshot?
    func load() throws -> RatingsStoreSnapshot? { snapshot }
    func save(_ newValue: RatingsStoreSnapshot) throws { snapshot = newValue }
}

final class RatingsOpportunitySchedulerTests: XCTestCase {
    func testCancelledOpportunityCannotInvokeNativeReview() async {
        let forbidden = expectation(description: "native bridge must never execute")
        forbidden.isInverted = true
        await MainActor.run {
            let store = RatingsSchedulerStore()
            let p = RatingsPolicy(version: "scheduler-v1", mode: .active,
                                  minimumConfirmedWins: 1, cooldownDays: 90)
            let engine = try! RatingsEngine(policy: p, store: store,
                                            activeRequestsAuthorised: true)
            try! engine.beginSession()
            try! engine.recordConfirmedValueMoment(
                .init(receiptID: UUID(), strength: .strong, isConfirmed: true))
            let scheduler = RatingsOpportunityScheduler()
            scheduler.schedule(engine: engine, delayNanoseconds: 700_000_000,
                currentOpportunity: {
                    RatingsOpportunity(now: Date(), isForeground: true, hasConfirmedValueMoment: true)
                },
                nativeRequest: {
                    forbidden.fulfill()
                    return true
                })
            scheduler.cancel()
        }
        await fulfillment(of: [forbidden], timeout: 1.0)
    }

    func testFreshBackgroundContextSuppressesAfterDeferredDelay() async {
        let completed = expectation(description: "safe context rechecked")
        let forbidden = expectation(description: "no native prompt in background")
        forbidden.isInverted = true
        await MainActor.run {
            let p = RatingsPolicy(version: "scheduler-v1", mode: .active,
                                  minimumConfirmedWins: 1, cooldownDays: 90)
            let engine = try! RatingsEngine(policy: p, store: RatingsSchedulerStore(),
                                            activeRequestsAuthorised: true)
            try! engine.beginSession()
            try! engine.recordConfirmedValueMoment(
                .init(receiptID: UUID(), strength: .strong, isConfirmed: true))
            let scheduler = RatingsOpportunityScheduler()
            scheduler.schedule(engine: engine, delayNanoseconds: 700_000_000,
                currentOpportunity: {
                    RatingsOpportunity(now: Date(), isForeground: false, hasConfirmedValueMoment: true)
                },
                nativeRequest: {
                    forbidden.fulfill()
                    return true
                },
                onOutcome: { result in
                    XCTAssertEqual(result, .suppressed(.background))
                    completed.fulfill()
                })
        }
        await fulfillment(of: [completed], timeout: 2)
        await fulfillment(of: [forbidden], timeout: 0.1)
    }
}

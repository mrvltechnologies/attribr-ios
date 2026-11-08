import Foundation
import XCTest
@testable import Attribr

final class RatingsEligibilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var policy: RatingsPolicy { .cleanrLegacyParity }
    private func opportunity(
        now: Date? = nil,
        foreground: Bool = true,
        onboarding: Bool = false,
        paywall: Bool = false,
        editing: Bool = false,
        bridge: Bool = true,
        confirmed: Bool = true
    ) -> RatingsOpportunity {
        RatingsOpportunity(now: now ?? self.now, isForeground: foreground,
            isOnboarding: onboarding, isPaywallPresented: paywall, isEditing: editing,
            nativeBridgeAvailable: bridge, hasConfirmedValueMoment: confirmed)
    }
    private func state(wins: Int = 3, sessions: Int = 1, daysSinceAttempt: Int? = nil) -> RatingsLocalState {
        RatingsLocalState(confirmedWins: wins, sessionCount: sessions,
            lastRequestAttemptAt: daysSinceAttempt.map { now.addingTimeInterval(TimeInterval(-$0 * 86_400)) })
    }
    /// Deterministic calendar: the default `Calendar(identifier:)` uses the machine's timezone, which made
    /// `now - N*86_400s` land on N-1 calendar days whenever a DST change fell inside the window (found on a
    /// Europe/London macOS run; the earlier Linux-UTC run could not see it).
    private func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }
    private func reason(_ state: RatingsLocalState, _ policy: RatingsPolicy? = nil,
                        _ context: RatingsOpportunity? = nil, zone: String = "UTC") -> RatingsReason {
        RatingsEligibility.evaluate(state: state, policy: policy ?? self.policy,
            opportunity: context ?? opportunity(), calendar: calendar(zone)).reason
    }
    func testCleanrParityConfigurationAndShadowNeverRequestsNativeReview() {
        XCTAssertEqual(policy.minimumConfirmedWins, 3)
        XCTAssertEqual(policy.cooldownDays, 90)
        let decision = RatingsEligibility.evaluate(state: state(), policy: policy, opportunity: opportunity())
        XCTAssertTrue(decision.isEligible)
        XCTAssertFalse(decision.mayRequestNativeReview)
        XCTAssertEqual(decision.configVersion, "cleanr-legacy-v1")
    }
    func testExactlyThreeWinsAndFewerThanThree() {
        XCTAssertEqual(reason(state(wins: 2)), .insufficientWins)
        XCTAssertEqual(reason(state(wins: 3)), .eligible)
    }
    func testCooldownBoundary() {
        XCTAssertEqual(reason(state(daysSinceAttempt: 89)), .cooldown)
        XCTAssertEqual(reason(state(daysSinceAttempt: 90)), .eligible)
        XCTAssertEqual(reason(state(daysSinceAttempt: 91)), .eligible)
    }
    /// Parity oracle: Cleanr's legacy ReviewPrompter computes
    /// `Calendar.current.dateComponents([.day], from: lastAsked, to: Date()).day >= 90`. The engine must agree with that
    /// exact formula in every timezone, including across DST changes (90*86_400s is NOT always 90 calendar days).
    func testCooldownMatchesLegacyCalendarDayFormulaAcrossTimezonesAndDST() {
        for zone in ["UTC", "Europe/London", "America/New_York", "Pacific/Auckland", "Asia/Kolkata"] {
            let cal = calendar(zone)
            for seconds in stride(from: 0, through: 200 * 86_400, by: 3 * 3_600) {
                let last = now.addingTimeInterval(TimeInterval(-seconds))
                var s = state()
                s.lastRequestAttemptAt = last
                let legacyAllows = (cal.dateComponents([.day], from: last, to: now).day ?? 0) >= 90
                XCTAssertEqual(reason(s, zone: zone) == .eligible, legacyAllows,
                               "\(zone): \(seconds)s since last attempt")
            }
        }
    }
    func testCooldownIsCalendarDaysNotElapsedSecondsAcrossDST() {
        let london = calendar("Europe/London")
        let ninetyCalendarDaysAgo = london.date(byAdding: .day, value: -90, to: now)!
        let eightyNineCalendarDaysAgo = london.date(byAdding: .day, value: -89, to: now)!
        var s = state(); s.lastRequestAttemptAt = ninetyCalendarDaysAgo
        XCTAssertEqual(reason(s, zone: "Europe/London"), .eligible)
        s.lastRequestAttemptAt = eightyNineCalendarDaysAgo
        XCTAssertEqual(reason(s, zone: "Europe/London"), .cooldown)
        // 90*86_400 elapsed seconds spans the UK autumn clock change here => only 89 calendar days (legacy behaviour).
        s.lastRequestAttemptAt = now.addingTimeInterval(-90 * 86_400)
        XCTAssertEqual(reason(s, zone: "Europe/London"), .cooldown)
    }
    func testOncePerLaunchAndAtomicTimestampMarker() {
        var s = state()
        RatingsEligibility.markNativeRequestAttempt(in: &s, at: now)
        XCTAssertEqual(reason(s), .alreadyAttemptedThisLaunch)
        XCTAssertEqual(s.lastRequestAttemptAt, now)
        RatingsEligibility.resetLaunchAttempt(in: &s)
        XCTAssertEqual(reason(s), .cooldown)
    }
    func testFutureTimestampCannotBypassCooldown() {
        var s = state()
        s.lastRequestAttemptAt = now.addingTimeInterval(86_400)
        XCTAssertEqual(reason(s), .clockRollback)
    }
    func testUIAndLifecycleSuppression() {
        let s = state()
        XCTAssertEqual(reason(s, nil, opportunity(foreground:false)), .background)
        XCTAssertEqual(reason(s, nil, opportunity(onboarding:true)), .onboarding)
        XCTAssertEqual(reason(s, nil, opportunity(paywall:true)), .paywall)
        XCTAssertEqual(reason(s, nil, opportunity(editing:true)), .editing)
        XCTAssertEqual(reason(s, nil, opportunity(bridge:false)), .nativeBridgeUnavailable)
        XCTAssertEqual(reason(s, nil, opportunity(confirmed:false)), .unconfirmedValueMoment)
    }
    func testRealValueMomentDedupAndNoUnconfirmedWins() {
        var s = RatingsLocalState()
        let id = UUID()
        XCTAssertFalse(RatingsEligibility.recordConfirmedValueMoment(.init(receiptID:id, strength:.strong, isConfirmed:false), into:&s))
        XCTAssertFalse(RatingsEligibility.recordConfirmedValueMoment(.init(receiptID:id, strength:.none, isConfirmed:true), into:&s))
        XCTAssertTrue(RatingsEligibility.recordConfirmedValueMoment(.init(receiptID:id, strength:.standard, isConfirmed:true), into:&s))
        XCTAssertFalse(RatingsEligibility.recordConfirmedValueMoment(.init(receiptID:id, strength:.strong, isConfirmed:true), into:&s))
        XCTAssertEqual(s.confirmedWins, 1)
        XCTAssertEqual(s.recentReceiptIDs, [id])
    }
    func testReceiptHistoryIsBounded() {
        var s = RatingsLocalState()
        for _ in 0..<100 {
            XCTAssertTrue(RatingsEligibility.recordConfirmedValueMoment(.init(receiptID:UUID(), strength:.standard, isConfirmed:true), into:&s))
        }
        XCTAssertEqual(s.confirmedWins, 100)
        XCTAssertEqual(s.recentReceiptIDs.count, 64)
    }
    func testDisabledAndInvalidConfigurationFailClosed() {
        let disabled = RatingsPolicy(version:"off",mode:.disabled,minimumConfirmedWins:3,cooldownDays:90)
        XCTAssertEqual(reason(state(),disabled), .disabled)
        let invalid = RatingsPolicy(version:"bad",mode:.active,minimumConfirmedWins:0,cooldownDays:-1)
        XCTAssertEqual(reason(state(),invalid), .invalidPolicy)
        let nan = RatingsPolicy(version:"bad",mode:.active,minimumConfirmedWins:1,cooldownDays:90,
            crashSuppressionSeconds:.nan)
        XCTAssertEqual(reason(state(),nan), .invalidPolicy)
    }
    func testActiveCanRequestOnlyAfterSuccessfulEligibility() {
        let active = RatingsPolicy(version:"generic-v1",mode:.active,minimumConfirmedWins:2,cooldownDays:30)
        let good = RatingsEligibility.evaluate(state:state(wins:2),policy:active,opportunity:opportunity())
        XCTAssertTrue(good.mayRequestNativeReview)
        let bad = RatingsEligibility.evaluate(state:state(wins:1),policy:active,opportunity:opportunity())
        XCTAssertFalse(bad.mayRequestNativeReview)
    }
    func testSessionsAndAppAgeWithoutInventingMetadata() {
        let p = RatingsPolicy(version:"config-v1",mode:.shadow,minimumConfirmedWins:2,minimumSessions:2,
            minimumAppAgeDays:5,cooldownDays:30)
        XCTAssertEqual(reason(state(wins:3,sessions:1),p),.insufficientSessions)
        XCTAssertEqual(reason(state(wins:3,sessions:2),p),.insufficientAppAge)
        var s=state(wins:3,sessions:2)
        s.firstSeenAt=now.addingTimeInterval(-6*86_400)
        XCTAssertEqual(reason(s,p),.eligible)
        s.firstSeenAt=now.addingTimeInterval(86_400)
        XCTAssertEqual(reason(s,p),.insufficientAppAge)
    }
    func testFailureCrashWindowsAndClockRollback() {
        let p = RatingsPolicy(version:"config-v1",mode:.shadow,minimumConfirmedWins:3,cooldownDays:30,
            failureSuppressionSeconds:3_600,crashSuppressionSeconds:86_400)
        var s=state()
        s.lastFailureAt=now.addingTimeInterval(-200)
        XCTAssertEqual(reason(s,p),.recentFailure)
        s.lastFailureAt=now.addingTimeInterval(-4_000)
        s.lastCrashAt=now.addingTimeInterval(-200)
        XCTAssertEqual(reason(s,p),.recentCrash)
        s.lastCrashAt=now.addingTimeInterval(-86_401)
        XCTAssertEqual(reason(s,p),.eligible)
        s.lastCrashAt=now.addingTimeInterval(60)
        XCTAssertEqual(reason(s,p),.recentCrash)
    }
    func testNoPhotoOrNetworkImportsRequired() {
        XCTAssertEqual(RatingsReason.eligible.rawValue,"eligible")
        XCTAssertEqual(RatingsStrength.strong.rawValue,"strong")
        XCTAssertEqual(RatingsMode.shadow.rawValue,"shadow")
    }
}

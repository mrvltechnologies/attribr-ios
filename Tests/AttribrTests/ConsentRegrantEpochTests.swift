import Foundation
import XCTest
@testable import Attribr

/// Regression for revoke -> regrant resurrecting work created during a previous grant.
/// These checks intercept HTTP dispatch, not just the ConsentManager Boolean.
@MainActor
final class ConsentRegrantEpochTests: XCTestCase {
    private let consentKey = "com.mrvltechnologies.attribr.consent"
    private let queueKey = "com.mrvltechnologies.attribr.queue"

    override func setUp() {
        super.setUp()
        Attribr.resetForTesting()
        UserDefaults.standard.removeObject(forKey: consentKey)
        UserDefaults.standard.removeObject(forKey: queueKey)
        HoldingURLProtocol.reset()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [HoldingURLProtocol.self]
        let session = URLSession(configuration: cfg)
        RevenueDiscoveryReporter.urlSession = session
        RevenueDiscoveryReporter.retryDelayNanoseconds = 650_000_000
        Attribr.initializeForTesting(apiKey: "attr_test_key", session: session)
    }

    override func tearDown() {
        RevenueDiscoveryReporter.urlSession = .shared
        RevenueDiscoveryReporter.retryDelayNanoseconds = 2_000_000_000
        HoldingURLProtocol.reset()
        Attribr.resetForTesting()
        UserDefaults.standard.removeObject(forKey: consentKey)
        UserDefaults.standard.removeObject(forKey: queueKey)
        super.tearDown()
    }

    private func until(_ timeout: TimeInterval = 3,
                       _ predicate: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < end {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testDeferredRevenueCannotSendAfterWithdrawalAndRegrant() async {
        Attribr.setConsent(.granted)
        Attribr.trackRevenue(amount: 2.50, currency: "GBP", transactionId: "old-grant")
        Attribr.setConsent(.revoked)
        Attribr.setConsent(.granted)
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(HoldingURLProtocol.requests.filter {
            $0.url?.path.hasSuffix("/attribr-revenue") == true
        }.count, 0, "regrant must never revive deferred revenue from an old grant")
    }

    func testBackoffRetryCannotSendAfterWithdrawalAndRegrant() async {
        Attribr.setConsent(.granted)
        try? await Task.sleep(nanoseconds: 100_000_000)
        HoldingURLProtocol.reset()
        HoldingURLProtocol.statusCode = 503
        Attribr.trackEvent(name: "old-grant", metadata: [:])
        await until { HoldingURLProtocol.requests.count >= 1 }
        XCTAssertEqual(HoldingURLProtocol.requests.count, 1)
        Attribr.setConsent(.revoked)
        Attribr.setConsent(.granted)
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        XCTAssertEqual(HoldingURLProtocol.requests.count, 1,
                       "retry after withdrawal and regrant must be blocked")
        XCTAssertEqual(Attribr.queuedEventCount, 0)
    }

    func testPurgedQueueSnapshotCannotDrainAfterRegrant() async {
        for i in 0..<4 {
            Attribr.enqueueRevenueDiscovery(Data("payload-\(i)".utf8), attempts: 0)
        }
        XCTAssertEqual(Attribr.queuedEventCount, 4)
        HoldingURLProtocol.holdFirst = true
        Attribr.setConsent(.granted)
        await until { HoldingURLProtocol.requests.count >= 1 }
        XCTAssertEqual(HoldingURLProtocol.requests.count, 1)
        Attribr.setConsent(.revoked)
        Attribr.setConsent(.granted)
        HoldingURLProtocol.releaseHeld()
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(HoldingURLProtocol.requests.count, 1)
        XCTAssertEqual(Attribr.queuedEventCount, 0)
    }

    func testFreshEventAfterExplicitRegrantStillSends() async {
        Attribr.setConsent(.granted)
        Attribr.setConsent(.revoked)
        Attribr.setConsent(.granted)
        try? await Task.sleep(nanoseconds: 100_000_000)
        HoldingURLProtocol.reset()
        Attribr.trackEvent(name: "new-consent-session", metadata: [:])
        await until { HoldingURLProtocol.requests.count >= 1 }
        XCTAssertEqual(HoldingURLProtocol.requests.count, 1,
                       "new work created after regrant must remain functional")
    }

    func testRevenueDiscoveryCannotRetryOrRequeueAfterRegrant() async {
        Attribr.setConsent(.granted)
        try? await Task.sleep(nanoseconds: 100_000_000)
        HoldingURLProtocol.reset()
        HoldingURLProtocol.failTransport = true
        let body = Data("regrant".utf8)
        let task = Task {
            await RevenueDiscoveryReporter.dispatch(body: body, apiKey: "k", label: "regrant")
        }
        await until { HoldingURLProtocol.requests.count >= 1 }
        XCTAssertEqual(HoldingURLProtocol.requests.count, 1)
        Attribr.setConsent(.revoked)
        Attribr.setConsent(.granted)
        await task.value
        XCTAssertEqual(HoldingURLProtocol.requests.count, 1,
                       "direct revenue-discovery retries must not resurrect old payloads")
        XCTAssertEqual(Attribr.queuedEventCount, 0)
    }
}

import XCTest
@testable import Attribr

/// attribr-ios issue #1 (Berea): consent withdrawn while sends are scheduled/in flight must stop further
/// requests; a legacy persisted grant reset by the host must not let an old backlog upload later.
/// These tests observe REQUESTS ON THE URLSession BOUNDARY (a stub protocol), not internal flags. They do not
/// prove wire silence on a device — see the PR for what remains unverified.
@MainActor
final class ConsentWithdrawalDispatchTests: XCTestCase {
    private let consentKey = "com.mrvltechnologies.attribr.consent"
    private let queueKey = "com.mrvltechnologies.attribr.queue"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: consentKey)
        UserDefaults.standard.removeObject(forKey: queueKey)
        Attribr.resetForTesting()
        HoldingURLProtocol.reset()
    }

    override func tearDown() {
        HoldingURLProtocol.reset()
        Attribr.resetForTesting()
        UserDefaults.standard.removeObject(forKey: consentKey)
        UserDefaults.standard.removeObject(forKey: queueKey)
        super.tearDown()
    }

    private func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [HoldingURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    private func start() {
        Attribr.initializeForTesting(apiKey: "attr_test_key", config: AttribrConfiguration(), session: session())
    }

    private func park(_ n: Int) {
        for i in 0..<n { Attribr.enqueueRevenueDiscovery(Data("{\"i\":\(i)}".utf8), attempts: 0) }
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ cond: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    /// grant -> flush starts -> request #1 is in flight -> revoke -> release. Only the in-flight request may exist.
    func test_revokeDuringFlush_sendsNoFurtherQueuedEvents_andPurgesBacklog() async {
        start()
        park(5)                                       // parked while .unknown
        XCTAssertEqual(Attribr.queuedEventCount, 5)
        HoldingURLProtocol.holdFirst = true
        Attribr.setConsent(.granted)                  // flush Task starts
        await waitUntil { HoldingURLProtocol.requests.count >= 1 }
        XCTAssertEqual(HoldingURLProtocol.requests.count, 1, "first request should be in flight")
        Attribr.setConsent(.revoked)                  // withdraw mid-flush
        HoldingURLProtocol.releaseHeld()
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(HoldingURLProtocol.requests.count, 1, "no queued event may be sent after withdrawal")
        XCTAssertEqual(Attribr.queuedEventCount, 0, "undelivered backlog must be discarded on withdrawal")
    }

    /// trackLaunch schedules an unstructured Task; revoke before it runs -> no request, nothing re-queued.
    func test_revokeBetweenTrackLaunchSchedulingAndExecution_sendsNothing() async {
        start()
        Attribr.setConsent(.granted)
        try? await Task.sleep(nanoseconds: 100_000_000)       // let the grant-time flush finish (queue empty)
        HoldingURLProtocol.reset()
        Attribr.trackLaunch()                                  // Task scheduled while granted
        Attribr.setConsent(.revoked)                           // revoked before the Task body runs
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(HoldingURLProtocol.requests.count, 0)
        XCTAssertEqual(Attribr.queuedEventCount, 0, "a consent-blocked send must be dropped, not parked for a later grant")
    }

    /// Build 56 left a persisted .granted and a backlog; Build 57's host resets to .unknown at launch.
    func test_legacyGrantResetToUnknown_noNetwork_noBacklogUploadOnLaterOptIn() async {
        UserDefaults.standard.set("granted", forKey: consentKey)            // legacy implied grant
        start()                                                              // SDK loads .granted
        XCTAssertEqual(Attribr.consentState, .granted)
        park(3)                                                              // legacy backlog on disk
        Attribr.setConsent(.unknown)                                         // host reconcile at launch
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(HoldingURLProtocol.requests.count, 0, "no request while undecided")
        XCTAssertEqual(Attribr.queuedEventCount, 0, "legacy backlog collected under an implied grant is discarded")
        Attribr.setConsent(.granted)                                         // later explicit opt-in
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(HoldingURLProtocol.requests.count, 0, "the old backlog must not upload after a later opt-in")
    }

    /// Events parked while .unknown (e.g. purchase evidence) still flush after an explicit first opt-in.
    func test_parkedWhileUnknown_stillFlushesAfterExplicitFirstGrant() async {
        start()
        park(2)
        Attribr.setConsent(.granted)
        await waitUntil { HoldingURLProtocol.requests.count >= 2 }
        XCTAssertEqual(HoldingURLProtocol.requests.count, 2)
    }

    /// Declining after parking discards the parked events.
    func test_declineAfterParking_discardsParkedEvents() async {
        start()
        park(4)
        Attribr.setConsent(.revoked)
        XCTAssertEqual(Attribr.queuedEventCount, 0)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(HoldingURLProtocol.requests.count, 0)
    }

    /// The GDPR deletion request is allowed (and survives the purge) even when consent is revoked.
    func test_deletionRequest_isStillSent_whenConsentRevoked() async {
        start()
        Attribr.setConsent(.revoked)
        Attribr.deleteAllData { _ in }
        await waitUntil { HoldingURLProtocol.requests.contains { $0.url?.path.hasSuffix("attribr-delete-user-data") == true } }
        XCTAssertTrue(HoldingURLProtocol.requests.contains { $0.url?.path.hasSuffix("attribr-delete-user-data") == true },
                      "DSR deletion must remain available after withdrawal")
    }

    /// A retry sleeping in back-off must re-check consent before the next attempt.
    func test_retryAfterBackoff_isBlockedIfConsentWithdrawnMeanwhile() async {
        start()
        Attribr.setConsent(.granted)
        try? await Task.sleep(nanoseconds: 100_000_000)
        HoldingURLProtocol.reset()
        HoldingURLProtocol.statusCode = 503                   // forces the retry/back-off path
        Attribr.trackEvent(name: "x", metadata: [:])
        await waitUntil { HoldingURLProtocol.requests.count >= 1 }
        Attribr.setConsent(.revoked)                           // during the 1 s back-off
        try? await Task.sleep(nanoseconds: 1_600_000_000)
        XCTAssertEqual(HoldingURLProtocol.requests.count, 1, "the back-off retry must not be sent after withdrawal")
    }
}

/// Records every request that reaches the URLSession boundary; can hold the first one in flight.
final class HoldingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static let lock = NSLock()
    nonisolated(unsafe) private static var _requests: [URLRequest] = []
    nonisolated(unsafe) private static var held: HoldingURLProtocol?
    nonisolated(unsafe) static var holdFirst = false
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var failTransport = false

    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    static func reset() { lock.lock(); _requests = []; held = nil; holdFirst = false; statusCode = 200; failTransport = false; lock.unlock() }
    static func releaseHeld() { releaseHeldWith(200) }
    static func releaseHeldWith(_ code: Int) {
        lock.lock(); let h = held; held = nil; lock.unlock()
        h?.finish(code)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self._requests.append(request)
        let shouldHold = Self.holdFirst && Self.held == nil
        if shouldHold { Self.held = self }
        let code = Self.statusCode
        let fail = Self.failTransport
        Self.lock.unlock()
        if fail { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        if !shouldHold { finish(code) }
    }

    func finish(_ code: Int) {
        let r = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

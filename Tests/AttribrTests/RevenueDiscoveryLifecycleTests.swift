import XCTest
import StoreKit
import StoreKitTest
@testable import Attribr

/// Capturing URLProtocol — intercepts `URLSession.shared` so no request ever leaves the machine.
final class CaptureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [(url: URL, key: String?, body: [String: Any])] = []
    nonisolated(unsafe) static var status = 200
    static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.absoluteString.contains("revenue-discovery") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody
        if data == nil, let s = request.httpBodyStream {
            s.open(); defer { s.close() }
            var buf = [UInt8](repeating: 0, count: 8192); var out = Data()
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; out.append(buf, count: n) }
            data = out
        }
        let body = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        Self.lock.lock(); Self.requests.append((request.url!, request.value(forHTTPHeaderField: "X-Attribr-Key"), body)); Self.lock.unlock()
        let resp = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"status\":\"ok\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func reset() { lock.lock(); requests = []; status = 200; lock.unlock() }
}

@available(iOS 16.0, macOS 13.0, *)
@MainActor
final class RevenueDiscoveryLifecycleTests: XCTestCase {
    var session: SKTestSession?
    let productID = "com.attribr.lifecycle.monthly"

    override func setUp() async throws {
        URLProtocol.registerClass(CaptureProtocol.self)
        CaptureProtocol.reset()
        RevenueDiscoveryLifecycle.defaults = UserDefaults(suiteName: "attribr.rdl.test.\(UUID().uuidString)")!
        RevenueDiscoveryLifecycle.resetForTesting()
        Attribr.resetForTesting()
    }

    /// StoreKitTest needs a hosted app AND a working StoreKit testing daemon — run via QA/StoreKitHarness
    /// from Xcode with ATTRIBR_STOREKIT_QA=1. Skipped (not failed) everywhere else, e.g. `swift test`.
    private func requireStoreKit() async throws {
        guard ProcessInfo.processInfo.environment["ATTRIBR_STOREKIT_QA"] == "1" else {
            throw XCTSkip("StoreKit runtime QA — set ATTRIBR_STOREKIT_QA=1 and run QA/StoreKitHarness in Xcode")
        }
        let s = try SKTestSession(configurationFileNamed: "Lifecycle")
        s.resetToDefaultState(); s.clearTransactions(); s.disableDialogs = true
        session = s
    }
    override func tearDown() async throws {
        URLProtocol.unregisterClass(CaptureProtocol.self)
        session?.clearTransactions()
    }

    private func initSDK(consent: ConsentState?) async {
        Attribr.initializeForTesting(apiKey: "attr_test_qa0000000000000000000000000000000000000000", session: .shared)
        if let c = consent { Attribr.setConsent(c) }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
    private func settle() async { try? await Task.sleep(nanoseconds: 800_000_000) }
    private func buy() async throws -> StoreKit.Transaction {
        try await requireStoreKit()
        try session!.buyProduct(productIdentifier: productID)
        guard let tx = await firstVerified() else { throw XCTSkip("no entitlement after buy") }
        return tx
    }
    private func firstVerified() async -> StoreKit.Transaction? {
        for await r in Transaction.currentEntitlements { if case .verified(let t) = r { return t } }
        return nil
    }

    // ---- pure policy ------------------------------------------------------------------------------
    func testPolicyFirstReconcileSendsAll() {
        XCTAssertEqual(RevenueDiscoveryLifecycle.plan(candidates: [1,2], reported: [:], lastReconcile: nil, isReconcile: true), [1,2])
    }
    func testPolicyThrottle24h() {
        let now = Date()
        XCTAssertEqual(RevenueDiscoveryLifecycle.plan(candidates: [1], reported: [:], lastReconcile: now.addingTimeInterval(-3600), now: now, isReconcile: true), [])
        XCTAssertEqual(RevenueDiscoveryLifecycle.plan(candidates: [1], reported: [:], lastReconcile: now.addingTimeInterval(-90_000), now: now, isReconcile: true), [1])
    }
    func testPolicyTransactionCapAndDedupe() {
        XCTAssertEqual(RevenueDiscoveryLifecycle.plan(candidates: [1,2,2], reported: [1: 3, 2: 2], lastReconcile: nil, isReconcile: true), [2])
    }
    func testPolicyLaunchCap() {
        let ids = (1...80).map { UInt64($0) }
        XCTAssertEqual(RevenueDiscoveryLifecycle.plan(candidates: ids, reported: [:], lastReconcile: nil, isReconcile: true).count, 50)
    }
    func testPolicyUpdatePathBypassesThrottle() {
        XCTAssertEqual(RevenueDiscoveryLifecycle.plan(candidates: [9], reported: [:], lastReconcile: Date(), isReconcile: false), [9])
    }
    func testEventIdIsDeterministic() {
        XCTAssertEqual(RevenueDiscoveryReporter.sdkEventID(forTransactionID: 42), "storekit:42")
    }
    func testXcodeEnvironmentIsNeverProduction() {
        XCTAssertEqual(RevenueDiscoveryReporter.environmentString(.xcode), "sandbox")
        XCTAssertEqual(RevenueDiscoveryReporter.environmentString(.sandbox), "sandbox")
        XCTAssertEqual(RevenueDiscoveryReporter.environmentString(.production), "production")
    }

    // ---- real StoreKit (StoreKitTest) ---------------------------------------------------------------
    func testUnverifiedIsIgnored() async throws {
        let tx = try await buy()
        _ = tx
        // VerificationResult.unverified can't be fabricated with a real Transaction; the guard is exercised
        // by constructing the unverified case from a verified payload.
        guard let verified = await firstVerified() else { return XCTFail("no entitlement") }
        let unverified = VerificationResult<StoreKit.Transaction>.unverified(verified, .invalidSignature)
        final class Box: @unchecked Sendable { var n = 0 }
        let box = Box()
        let hit = RevenueDiscoveryLifecycle.process(update: unverified, token: { _ in nil }, report: { _, _ in box.n += 1 })
        XCTAssertFalse(hit); XCTAssertEqual(box.n, 0)
        let ids = RevenueDiscoveryLifecycle.process(entitlements: [unverified], token: { _ in nil }, report: { _, _ in })
        XCTAssertTrue(ids.isEmpty)
    }

    func testPurchaseReportsOnceWithExpectedShape() async throws {
        await initSDK(consent: .granted)
        _ = try await buy()
        guard let tx = await firstVerified() else { return XCTFail("no entitlement") }
        RevenueDiscoveryReporter.report(transaction: tx)
        await settle()
        XCTAssertEqual(CaptureProtocol.requests.count, 1)
        let r = CaptureProtocol.requests[0]
        XCTAssertEqual(r.url.absoluteString, "https://attribr.dev/api/v1/revenue-discovery")
        XCTAssertNotNil(r.key)
        XCTAssertEqual(r.body["source"] as? String, "sdk_storekit")
        XCTAssertEqual(r.body["environment"] as? String, "sandbox")          // .xcode must not be "production"
        XCTAssertEqual(r.body["sdk_event_id"] as? String, "storekit:\(tx.id)")
        XCTAssertEqual(r.body["transaction_id"] as? String, String(tx.id))
        XCTAssertEqual(r.body["original_transaction_id"] as? String, String(tx.originalID))
        XCTAssertEqual(r.body["product_id"] as? String, productID)
        XCTAssertEqual(r.body["sdk_install_instance_id_hash"] as? String, InstallInstance.hashHex())
        XCTAssertNil(r.body["appAccountToken"])                              // never fabricated
        for forbidden in ["amount", "price", "revenue", "currency", "paid", "status"] { XCTAssertNil(r.body[forbidden], forbidden) }
    }

    func testRelaunchReconcileReportsThenThrottles() async throws {
        await initSDK(consent: .granted)
        _ = try await buy()
        RevenueDiscoveryLifecycle.start(reconcileOnLaunch: true)
        await settle()
        let first = CaptureProtocol.requests.count
        XCTAssertEqual(first, 1)
        // "relaunch": a new process would have started=false but the same defaults.
        RevenueDiscoveryLifecycle.resetForTesting_keepLedger()
        RevenueDiscoveryLifecycle.start(reconcileOnLaunch: true)
        await settle()
        XCTAssertEqual(CaptureProtocol.requests.count, first, "24h throttle must suppress the second reconcile")
    }

    func testRestoreAfterThrottleStillCappedAndIdempotentId() async throws {
        await initSDK(consent: .granted)
        _ = try await buy()
        guard let tx = await firstVerified() else { return XCTFail() }
        let report: RevenueDiscoveryLifecycle.Report = { t, tok in RevenueDiscoveryReporter.report(transaction: t, appAccountToken: tok) }
        for _ in 0..<5 {   // restore button spam
            RevenueDiscoveryLifecycle.process(update: .verified(tx), token: { _ in nil }, report: report)
        }
        await settle()
        XCTAssertEqual(CaptureProtocol.requests.count, 3, "≤3 reports per transaction")
        XCTAssertEqual(Set(CaptureProtocol.requests.compactMap { $0.body["sdk_event_id"] as? String }), ["storekit:\(tx.id)"])
    }

    func testTransactionUpdatesListenerFires() async throws {
        await initSDK(consent: .granted)
        RevenueDiscoveryLifecycle.start(reconcileOnLaunch: false)
        try await Task.sleep(nanoseconds: 300_000_000)
        _ = try await buy()
        await settle()
        XCTAssertGreaterThanOrEqual(CaptureProtocol.requests.count, 1)
    }

    func testRevokedConsentDrops() async throws {
        await initSDK(consent: .revoked)
        _ = try await buy()
        guard let tx = await firstVerified() else { return XCTFail() }
        RevenueDiscoveryReporter.report(transaction: tx)
        await settle()
        XCTAssertEqual(CaptureProtocol.requests.count, 0)
    }

    func testUnknownConsentParksThenFlushesOnGrant() async throws {
        await initSDK(consent: nil)   // .unknown
        _ = try await buy()
        guard let tx = await firstVerified() else { return XCTFail() }
        RevenueDiscoveryReporter.report(transaction: tx)
        await settle()
        XCTAssertEqual(CaptureProtocol.requests.count, 0, "nothing sent before consent")
        Attribr.setConsent(.granted)
        await settle()
        XCTAssertGreaterThanOrEqual(CaptureProtocol.requests.filter { ($0.body["sdk_event_id"] as? String) == "storekit:\(tx.id)" }.count, 1)
    }
}

@available(iOS 16.0, macOS 13.0, *)
extension RevenueDiscoveryLifecycle {
    /// Simulates a process relaunch: new `started` state, same on-device ledger.
    static func resetForTesting_keepLedger() {
        let d = defaults
        let c = d.dictionary(forKey: "attribr.rdl.v1.counts"); let l = d.object(forKey: "attribr.rdl.v1.last")
        resetForTesting()
        if let c { d.set(c, forKey: "attribr.rdl.v1.counts") }
        if let l { d.set(l, forKey: "attribr.rdl.v1.last") }
    }
}

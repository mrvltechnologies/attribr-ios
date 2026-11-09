import XCTest
@testable import Attribr

/// PR #2 review (Berea): `RevenueDiscoveryReporter` sent via `URLSession.shared` directly, re-tried after back-off
/// without re-checking consent, and re-queued after withdrawal. These observe requests at the URLSession boundary.
/// They do not prove wire silence on a device; a request already on the wire cannot be recalled.
@MainActor
final class RevenueDiscoveryConsentTests: XCTestCase {
    private let consentKey = "com.mrvltechnologies.attribr.consent"
    private let queueKey = "com.mrvltechnologies.attribr.queue"
    private let body = Data("{\"sdk_event_id\":\"storekit:1\"}".utf8)

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: consentKey)
        UserDefaults.standard.removeObject(forKey: queueKey)
        Attribr.resetForTesting()
        HoldingURLProtocol.reset()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [HoldingURLProtocol.self]
        let session = URLSession(configuration: cfg)
        RevenueDiscoveryReporter.urlSession = session
        RevenueDiscoveryReporter.retryDelayNanoseconds = 600_000_000
        Attribr.initializeForTesting(apiKey: "attr_test_key", config: AttribrConfiguration(), session: session)
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

    private func intakeRequests() -> [URLRequest] {
        HoldingURLProtocol.requests.filter { $0.url?.host == "attribr.dev" && $0.value(forHTTPHeaderField: "X-Attribr-Key") == "k" }
    }

    func test_notGrantedAtDispatch_sendsNothing_andQueuesNothing() async {
        for state in [ConsentState.unknown, .revoked] {
            Attribr.setConsent(state)
            await RevenueDiscoveryReporter.dispatch(body: body, apiKey: "k", label: "t")
            XCTAssertEqual(intakeRequests().count, 0, "state \(state) must not dispatch")
            XCTAssertEqual(Attribr.queuedEventCount, 0)
        }
    }

    func test_grantedAtDispatch_sends() async {
        Attribr.setConsent(.granted)
        await RevenueDiscoveryReporter.dispatch(body: body, apiKey: "k", label: "t")
        XCTAssertEqual(intakeRequests().count, 1)
    }

    /// Transport failure -> back-off sleep -> consent withdrawn during the sleep -> the retry must not be sent,
    /// and the payload must not be re-queued.
    func test_revokeDuringBackoff_blocksRetry_andDoesNotRequeue() async {
        Attribr.setConsent(.granted)
        HoldingURLProtocol.failTransport = true
        let task = Task { await RevenueDiscoveryReporter.dispatch(body: body, apiKey: "k", label: "t") }
        let end = Date().addingTimeInterval(3)
        while intakeRequests().count < 1 && Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(intakeRequests().count, 1)
        Attribr.setConsent(.revoked)                    // during the 0.6 s back-off
        await task.value
        XCTAssertEqual(intakeRequests().count, 1, "the retry after back-off must not be sent after withdrawal")
        XCTAssertEqual(Attribr.queuedEventCount, 0, "a failed send must not be persisted after withdrawal")
    }

    /// Withdrawal while the request is in flight, server answers 503: nothing may be queued afterwards.
    func test_revokeWhileRequestInFlight_thenServerError_doesNotRequeue() async {
        Attribr.setConsent(.granted)
        HoldingURLProtocol.holdFirst = true
        let task = Task { await RevenueDiscoveryReporter.dispatch(body: body, apiKey: "k", label: "t") }
        let end = Date().addingTimeInterval(3)
        while intakeRequests().count < 1 && Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(intakeRequests().count, 1)
        Attribr.setConsent(.revoked)
        HoldingURLProtocol.statusCode = 503
        HoldingURLProtocol.releaseHeldWith(503)
        await task.value
        XCTAssertEqual(intakeRequests().count, 1)
        XCTAssertEqual(Attribr.queuedEventCount, 0, "5xx after withdrawal must not re-queue fresh data")
    }

    func test_enqueuePolicy_perConsentState() {
        Attribr.setConsent(.revoked)
        Attribr.enqueueRevenueDiscovery(body, attempts: 0)
        Attribr.enqueueRevenueDiscovery(body, attempts: 1)
        XCTAssertEqual(Attribr.queuedEventCount, 0, "revoked: never queue")

        Attribr.setConsent(.unknown)
        Attribr.enqueueRevenueDiscovery(body, attempts: 1)
        XCTAssertEqual(Attribr.queuedEventCount, 0, "unknown: a post-failure re-queue is refused")
        Attribr.enqueueRevenueDiscovery(body, attempts: 0)
        XCTAssertEqual(Attribr.queuedEventCount, 1, "unknown: first-time parking is the approved policy and still works")

        Attribr.setConsent(.granted)
        Attribr.enqueueRevenueDiscovery(body, attempts: 1)
        XCTAssertGreaterThanOrEqual(Attribr.queuedEventCount ?? 0, 1, "granted: re-queue allowed")
    }

    /// Alternate-egress scan: nothing but NetworkClient and the (gated) reporter may open a URLSession request.
    func test_noOtherDirectNetworkingInSDKSources() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Attribr")
        let allowed: Set<String> = ["NetworkClient.swift", "RevenueDiscoveryReporter.swift"]
        let needles = ["URLSession.shared", ".dataTask(", ".data(for:", ".data(from:", ".upload(", ".download(", "URLSession("]
        var offenders: [String] = []
        for f in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where f.pathExtension == "swift" && !allowed.contains(f.lastPathComponent) {
            let text = try String(contentsOf: f, encoding: .utf8)
                .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for n in needles where text.contains(n) {
                // Attribr.swift only *constructs* the injected test session type in doc/params, never sends with it.
                if f.lastPathComponent == "Attribr.swift" && (n == "URLSession(" ) { continue }
                offenders.append("\(f.lastPathComponent): \(n)")
            }
        }
        XCTAssertEqual(offenders, [], "direct networking outside the consent-gated paths")
    }

    func test_reporterChecksConsentBeforeItsOnlySend() throws {
        let f = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Attribr/RevenueDiscoveryReporter.swift")
        let text = try String(contentsOf: f, encoding: .utf8)
        let send = try XCTUnwrap(text.range(of: "urlSession.data(for:"))
        let gate = try XCTUnwrap(text.range(of: "guard await Attribr.isConsentGranted"))
        XCTAssertLessThan(gate.lowerBound, send.lowerBound)
        XCTAssertEqual(text.components(separatedBy: "urlSession.data(for:").count - 1, 1, "exactly one send site")
        XCTAssertFalse(text.contains("URLSession.shared.data"))
    }
}

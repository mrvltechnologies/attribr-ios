import XCTest
@testable import Attribr

/// Identity Foundation Phase 12 — Swift SDK `attribr_web_click_id` handoff.
///
/// Two things are covered:
/// 1. `DeepLinkHandler.extractWebClickId(from:)` — a pure, stateless static
///    helper with no network/device dependency. Tested directly.
/// 2. `Attribr.trackLaunch(webClickId:)` → `attribr-track` payload — since
///    `sendTrack` is `private` (not reachable via `@testable import` — Swift's
///    `private` is file-scoped even across the module boundary), this is
///    exercised end-to-end through the public `trackLaunch` API using
///    `Attribr.initializeForTesting(apiKey:config:session:)`, an internal
///    test-only seam (mirrors the existing `resetForTesting()` hook) that
///    threads a stubbed `URLSession` through to the real `NetworkClient` —
///    the same per-session stub-protocol mechanism `NetworkClientTests` uses.
final class DeepLinkHandlerWebClickIdTests: XCTestCase {

    func testValidURLWithParam() {
        let url = URL(string: "https://myapp.example/launch?attribr_web_click_id=awc_0123456789abcdef01234567")!
        XCTAssertEqual(DeepLinkHandler.extractWebClickId(from: url), "awc_0123456789abcdef01234567")
    }

    func testMissingParameter() {
        let url = URL(string: "https://myapp.example/launch?other=1")!
        XCTAssertNil(DeepLinkHandler.extractWebClickId(from: url))
    }

    func testNoQueryAtAll() {
        let url = URL(string: "https://myapp.example/launch")!
        XCTAssertNil(DeepLinkHandler.extractWebClickId(from: url))
    }

    func testEmptyParameter() {
        let url = URL(string: "https://myapp.example/launch?attribr_web_click_id=")!
        XCTAssertNil(DeepLinkHandler.extractWebClickId(from: url))
    }

    func testRepeatedParameterTakesFirst() {
        let url = URL(string: "https://myapp.example/launch?attribr_web_click_id=awc_0123456789abcdef01234567&attribr_web_click_id=awc_ffffffffffffffffffffffff")!
        XCTAssertEqual(DeepLinkHandler.extractWebClickId(from: url), "awc_0123456789abcdef01234567")
    }

    func testMalformedTokenRejected() {
        // Wrong shape entirely — not the awc_[0-9a-f]{24} format the backend mints.
        let url = URL(string: "https://myapp.example/launch?attribr_web_click_id=not-a-real-token")!
        XCTAssertNil(DeepLinkHandler.extractWebClickId(from: url))
    }

    func testWrongLengthTokenRejected() {
        let url = URL(string: "https://myapp.example/launch?attribr_web_click_id=awc_0123")!
        XCTAssertNil(DeepLinkHandler.extractWebClickId(from: url))
    }

    func testUppercaseHexRejected() {
        // Backend mints lowercase hex only — uppercase must not be silently accepted.
        let url = URL(string: "https://myapp.example/launch?attribr_web_click_id=awc_0123456789ABCDEF01234567")!
        XCTAssertNil(DeepLinkHandler.extractWebClickId(from: url))
    }

    func testUnrelatedSmartLinkParamsUnaffected() {
        // Attribr's own smart-link query param (`attribr_link`) must not be
        // confused with this new, unrelated parameter — and vice versa.
        let url = URL(string: "https://attribr.dev/?attribr_link=abc123&attribr_web_click_id=awc_0123456789abcdef01234567")!
        XCTAssertEqual(DeepLinkHandler.extractWebClickId(from: url), "awc_0123456789abcdef01234567")
    }

    func testSmartLinkURLWithoutWebClickIdParamReturnsNil() {
        let url = URL(string: "https://attribr.dev/l/abc123")!
        XCTAssertNil(DeepLinkHandler.extractWebClickId(from: url))
    }

    func testMalformedURLLikeInputHandledGracefully() {
        // URLComponents tolerates most strings that construct into a URL at all;
        // the important property is: never crash, never force-unwrap.
        guard let url = URL(string: "not a valid url at all") else {
            // If Foundation refuses to construct the URL, there is nothing to test —
            // callers can never reach extractWebClickId with an un-constructable URL.
            return
        }
        XCTAssertNil(DeepLinkHandler.extractWebClickId(from: url))
    }

    func testCustomSchemeURLWithParam() {
        let url = URL(string: "myapp://open?attribr_web_click_id=awc_0123456789abcdef01234567")!
        XCTAssertEqual(DeepLinkHandler.extractWebClickId(from: url), "awc_0123456789abcdef01234567")
    }
}

/// End-to-end: `Attribr.trackLaunch(webClickId:)` → `attribr-track` request body.
/// Uses `Attribr.initializeForTesting(apiKey:config:session:)` — an internal,
/// test-only seam (mirrors the existing `resetForTesting()` hook) that threads
/// a stubbed `URLSession` through to the SDK's `NetworkClient`, exactly like
/// `NetworkClientTests`' per-session `WebClickIdStubURLProtocol`. No public API changed.
@MainActor
final class TrackLaunchWebClickIdPayloadTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Attribr.resetForTesting()
        WebClickIdStubURLProtocol.requestHandler = nil
    }

    override func tearDown() {
        WebClickIdStubURLProtocol.requestHandler = nil
        Attribr.resetForTesting()
        super.tearDown()
    }

    private func makeStubbedSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [WebClickIdStubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    private func capturedBody(_ request: URLRequest) -> [String: Any] {
        var data = Data()
        if let body = request.httpBody {
            data = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            let bufferSize = 4096
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: bufferSize)
                if read > 0 { data.append(buffer, count: read) }
                else { break }
            }
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func captureLaunchRequest(webClickId: String??, timeout: TimeInterval = 3) -> URLRequest? {
        Attribr.initializeForTesting(
            apiKey: "attr_test_TESTKEY000000000000000000000000000000000",
            session: makeStubbedSession()
        )
        Attribr.setConsent(.granted)

        let expectation = XCTestExpectation(description: "request captured")
        var captured: URLRequest?
        WebClickIdStubURLProtocol.requestHandler = { request in
            captured = request
            expectation.fulfill()
            let resp = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        if let webClickId {
            Attribr.trackLaunch(webClickId: webClickId)
        } else {
            Attribr.trackLaunch()
        }
        wait(for: [expectation], timeout: timeout)
        return captured
    }

    func testTrackLaunchIncludesWebClickIdWhenSupplied() {
        guard let request = captureLaunchRequest(webClickId: "awc_0123456789abcdef01234567") else {
            return XCTFail("no request captured")
        }
        let body = capturedBody(request)
        XCTAssertEqual(body["attribr_web_click_id"] as? String, "awc_0123456789abcdef01234567")
        // Must not affect/replace attribution_code — this is a launch payload, not attributeInstall.
        XCTAssertNil(body["attribution_code"])
    }

    func testTrackLaunchOmitsFieldWhenAbsent() {
        guard let request = captureLaunchRequest(webClickId: .none) else {
            return XCTFail("no request captured")
        }
        let body = capturedBody(request)
        XCTAssertNil(body["attribr_web_click_id"])
    }

    func testTrackLaunchOmitsFieldWhenBlank() {
        guard let request = captureLaunchRequest(webClickId: .some("")) else {
            return XCTFail("no request captured")
        }
        let body = capturedBody(request)
        XCTAssertNil(body["attribr_web_click_id"])
    }

    func testExistingZeroArgTrackLaunchStillCompilesAndSends() {
        // Backward compatibility: the pre-Phase-12 call site `Attribr.trackLaunch()`
        // must still compile and behave identically (default parameter = nil).
        let request = captureLaunchRequest(webClickId: .none)
        XCTAssertNotNil(request, "trackLaunch() with no arguments must still fire a request")
    }
}

// MARK: - Stub protocol (scoped to the injected test session)

final class WebClickIdStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

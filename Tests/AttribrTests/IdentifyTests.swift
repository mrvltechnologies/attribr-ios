import XCTest
@testable import Attribr

/// Identity Foundation Phase 36 — `Attribr.identify(userId:)`.
///
/// Uses `Attribr.initializeForTesting(apiKey:config:session:)` — the same
/// internal test-only seam `WebClickIdHandoffTests`/`NetworkClientTests` use
/// — to exercise the public API end-to-end through a stubbed `URLSession`.
@MainActor
final class IdentifyTests: XCTestCase {

    // ConsentManager persists across process runs via UserDefaults.standard
    // (by design — see Consent.swift) — NOT reset by Attribr.resetForTesting(),
    // which only clears the in-memory singleton. Every other test file that
    // needs a known consent starting state clears this key directly
    // (SetConsentCrashTests does the same); without it, whichever test
    // granted consent last in this process leaks into every later test here.
    private let consentDefaultsKey = "com.mrvltechnologies.attribr.consent"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: consentDefaultsKey)
        Attribr.resetForTesting()
        IdentifyStubURLProtocol.requestHandler = nil
    }

    override func tearDown() {
        IdentifyStubURLProtocol.requestHandler = nil
        Attribr.resetForTesting()
        UserDefaults.standard.removeObject(forKey: consentDefaultsKey)
        super.tearDown()
    }

    private func makeStubbedSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [IdentifyStubURLProtocol.self]
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

    /// Captures the request `identify(userId:)` fires, or nil if none fired
    /// within the timeout (used to assert the no-op cases below).
    private func captureIdentifyRequest(
        userId: String,
        grantConsent: Bool = true,
        timeout: TimeInterval = 1.5
    ) -> URLRequest? {
        Attribr.initializeForTesting(
            apiKey: "attr_test_TESTKEY000000000000000000000000000000000",
            session: makeStubbedSession()
        )
        if grantConsent {
            Attribr.setConsent(.granted)
        }

        let expectation = XCTestExpectation(description: "identify request captured")
        expectation.isInverted = !grantConsent // for the no-consent case, expect it NOT to fire
        var captured: URLRequest?
        IdentifyStubURLProtocol.requestHandler = { request in
            captured = request
            expectation.fulfill()
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"{"ok":true}"#.utf8))
        }
        Attribr.identify(userId: userId)
        wait(for: [expectation], timeout: timeout)
        return captured
    }

    // MARK: - Happy path

    func testIdentifyPostsToTheDashboardHostNotTheEdgeFunctionsBase() {
        guard let request = captureIdentifyRequest(userId: "user-abc-123") else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(request.url?.absoluteString, "https://attribr.dev/api/v1/identify")
    }

    func testIdentifySendsOnlyUserIdAppIdAndDeviceHash() {
        guard let request = captureIdentifyRequest(userId: "user-abc-123") else {
            return XCTFail("no request captured")
        }
        let body = capturedBody(request)
        XCTAssertEqual(body["user_id"] as? String, "user-abc-123")
        XCTAssertNotNil(body["app_id"])
        XCTAssertNotNil(body["device_hash"])
        // Structural PII guarantee: the payload has exactly these three keys —
        // there is no email/name/phone/metadata field for this call to leak
        // through, because the public API signature doesn't accept one.
        XCTAssertEqual(Set(body.keys), Set(["user_id", "app_id", "device_hash"]))
    }

    func testIdentifySendsTheAttribrKeyHeader() {
        guard let request = captureIdentifyRequest(userId: "user-abc-123") else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Attribr-Key"), "attr_test_TESTKEY000000000000000000000000000000000")
    }

    // MARK: - Never sends PII, regardless of what a caller passes as the opaque id

    func testIdentifyNeverAddsAnEmailFieldEvenIfCallerPassesAnEmailShapedString() {
        // identify(userId:) has no email/name/phone parameter to begin with —
        // this proves that even a caller who (incorrectly) passes an
        // email-shaped string through the one string parameter still cannot
        // produce a request body containing an "email" key. The value itself
        // is opaque to the SDK; only the SERVER'S hashing step
        // (dashboard/src/lib/identity/hashing.ts) is what actually protects
        // it at rest — the same guarantee documented in api/v1/identify's own
        // "we do NOT accept email/phone/name in this route" contract.
        guard let request = captureIdentifyRequest(userId: "someone@example.com") else {
            return XCTFail("no request captured")
        }
        let body = capturedBody(request)
        XCTAssertNil(body["email"])
        XCTAssertNil(body["name"])
        XCTAssertNil(body["phone"])
        XCTAssertNil(body["metadata"])
    }

    func testIdentifyNeverSendsDeviceHashAsTheUserIdField() {
        guard let request = captureIdentifyRequest(userId: "user-abc-123") else {
            return XCTFail("no request captured")
        }
        let body = capturedBody(request)
        XCTAssertNotEqual(body["user_id"] as? String, body["device_hash"] as? String)
    }

    // MARK: - Non-fatal / no-op guarantees

    func testIdentifyDoesNothingWithoutConsent() {
        let request = captureIdentifyRequest(userId: "user-abc-123", grantConsent: false)
        XCTAssertNil(request, "identify() must not fire any request before consent is granted")
    }

    func testIdentifyDoesNothingForAnEmptyUserId() {
        Attribr.initializeForTesting(
            apiKey: "attr_test_TESTKEY000000000000000000000000000000000",
            session: makeStubbedSession()
        )
        Attribr.setConsent(.granted)

        let expectation = XCTestExpectation(description: "no request for empty userId")
        expectation.isInverted = true
        IdentifyStubURLProtocol.requestHandler = { request in
            expectation.fulfill()
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        Attribr.identify(userId: "")
        wait(for: [expectation], timeout: 1.0)
    }

    func testIdentifyFailureDoesNotThrowOrCrash() {
        Attribr.initializeForTesting(
            apiKey: "attr_test_TESTKEY000000000000000000000000000000000",
            session: makeStubbedSession()
        )
        Attribr.setConsent(.granted)

        let expectation = XCTestExpectation(description: "failed request handled")
        IdentifyStubURLProtocol.requestHandler = { request in
            expectation.fulfill()
            let resp = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        // Calling identify() with a failing backend must not throw/crash —
        // there's nothing to assert beyond "this completes normally".
        Attribr.identify(userId: "user-abc-123")
        wait(for: [expectation], timeout: 1.5)
    }

    func testIdentifyBeforeInitializeIsANoOp() {
        Attribr.resetForTesting()
        IdentifyStubURLProtocol.requestHandler = { request in
            XCTFail("identify() must not fire any request before initialize()")
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        Attribr.identify(userId: "user-abc-123")
    }
}

// MARK: - Stub protocol (scoped to the injected test session)

final class IdentifyStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = IdentifyStubURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "IdentifyStubURLProtocol", code: 0))
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

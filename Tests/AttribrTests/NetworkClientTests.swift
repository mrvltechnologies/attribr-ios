import XCTest
@testable import Attribr

/// Tests the NetworkClient using a stubbed URLSession via URLProtocol.
final class NetworkClientTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.requestHandler = nil
    }

    override func tearDown() {
        StubURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeClient(stubURL: URL = URL(string: "https://stub.test/v1")!) -> NetworkClient {
        let logger = AttribrLogger(enabled: false)
        let config = AttribrConfiguration(
            baseURL: stubURL,
            maxQueueSize: 500,
            requestTimeout: 5,
            debugLogging: false,
            maxRetries: 2
        )
        // Inject stub protocol via session configuration
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        let stubbedSession = URLSession(configuration: cfg)
        return NetworkClient(
            apiKey: "attr_test_TESTKEY000000000000000000000000000000000",
            config: config,
            logger: logger,
            session: stubbedSession
        )
    }

    func testSuccessful204() async {
        StubURLProtocol.requestHandler = { _ in
            let resp = HTTPURLResponse(url: URL(string: "https://stub.test")!, statusCode: 204, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let client = makeClient()
        let result = await client.post(path: "attribr-track", body: Data())
        if case .success(_, let code) = result {
            XCTAssertEqual(code, 204)
        } else {
            XCTFail("Expected success, got failure")
        }
    }

    func testSuccessful201WithBody() async {
        let responseBody = "{\"attributed\":true}".data(using: .utf8)!
        StubURLProtocol.requestHandler = { _ in
            let resp = HTTPURLResponse(url: URL(string: "https://stub.test")!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            return (resp, responseBody)
        }
        let client = makeClient()
        let result = await client.post(path: "attribr-attribute", body: Data())
        if case .success(let data, let code) = result {
            XCTAssertEqual(code, 201)
            XCTAssertEqual(data, responseBody)
        } else {
            XCTFail("Expected success")
        }
    }

    func testAttribrKeyHeaderIsSet() async {
        var capturedRequest: URLRequest?
        StubURLProtocol.requestHandler = { request in
            capturedRequest = request
            let resp = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let client = makeClient()
        _ = await client.post(path: "attribr-track", body: Data())
        XCTAssertEqual(
            capturedRequest?.value(forHTTPHeaderField: "X-Attribr-Key"),
            "attr_test_TESTKEY000000000000000000000000000000000"
        )
    }

    func testContentTypeHeaderIsSet() async {
        var capturedRequest: URLRequest?
        StubURLProtocol.requestHandler = { request in
            capturedRequest = request
            let resp = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let client = makeClient()
        _ = await client.post(path: "attribr-track", body: Data())
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func test401DoesNotRetry() async {
        var callCount = 0
        StubURLProtocol.requestHandler = { _ in
            callCount += 1
            let resp = HTTPURLResponse(url: URL(string: "https://stub.test")!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let client = makeClient()
        let result = await client.post(path: "attribr-track", body: Data())
        XCTAssertEqual(callCount, 1, "4xx must not be retried")
        if case .failure(.httpError(let code, _)) = result {
            XCTAssertEqual(code, 401)
        } else {
            XCTFail("Expected httpError(401)")
        }
    }

    func testDeleteMethod() async {
        var capturedMethod: String?
        StubURLProtocol.requestHandler = { request in
            capturedMethod = request.httpMethod
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let client = makeClient()
        _ = await client.delete(path: "attribr-delete-user-data", body: Data())
        XCTAssertEqual(capturedMethod, "DELETE")
    }
}

// MARK: - URLProtocol stub

final class StubURLProtocol: URLProtocol {
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

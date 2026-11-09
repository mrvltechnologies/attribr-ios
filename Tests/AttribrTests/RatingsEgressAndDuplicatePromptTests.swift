import Foundation
import XCTest
@testable import Attribr

/// Capturing URLProtocol — records every request the real SDK pipeline attempts. Nothing leaves the machine.
final class RatingsEgressStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [[String: Any]] = []
    static let lock = NSLock()

    static func reset() { lock.lock(); requests = []; bodies = []; lock.unlock() }
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
        }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        Self.lock.lock(); Self.requests.append(request); Self.bodies.append(json); Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
private final class EgressFakeStore: RatingsStateStore {
    var snapshot: RatingsStoreSnapshot?
    func load() throws -> RatingsStoreSnapshot? { snapshot }
    func save(_ value: RatingsStoreSnapshot) throws { snapshot = value }
}

/// Requirement: the Ratings Engine cannot send ratings analytics without BOTH product disclosure AND analytics
/// consent AND SDK consent, and never sends anything on its own. Exercised through the REAL Attribr SDK pipeline.
@MainActor
final class RatingsTelemetryEgressTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        Attribr.resetForTesting()
        RatingsEgressStubURLProtocol.reset()
    }
    override func tearDown() async throws { Attribr.resetForTesting() }

    private func startSDK(consent: ConsentState?) async {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [RatingsEgressStubURLProtocol.self]
        Attribr.initializeForTesting(apiKey: "attr_test_RATINGSEGRESS00000000000000000000000000",
                                     session: URLSession(configuration: cfg))
        if let consent { Attribr.setConsent(consent) }
        try? await Task.sleep(nanoseconds: 300_000_000)   // let any init/consent flush settle
        RatingsEgressStubURLProtocol.reset()              // baseline: only count what ratings code causes
    }
    private var event: RatingsTelemetryEvent {
        RatingsTelemetryEvent(event: .valueMoment, mode: .shadow, policy: .cleanrLegacyParity, moment: .confirmedExport)
    }
    private func settle() async { try? await Task.sleep(nanoseconds: 500_000_000) }

    func testNoRequestWhenSDKConsentUnknownEvenIfProductApproved() async {
        await startSDK(consent: nil)
        _ = RatingsAnalyticsForwarder.submitIfApproved(event, productDisclosureApproved: true, analyticsConsentApproved: true)
        await settle()
        XCTAssertEqual(RatingsEgressStubURLProtocol.count, 0)
    }

    func testNoRequestWhenSDKConsentRevoked() async {
        await startSDK(consent: .revoked)
        _ = RatingsAnalyticsForwarder.submitIfApproved(event, productDisclosureApproved: true, analyticsConsentApproved: true)
        await settle()
        XCTAssertEqual(RatingsEgressStubURLProtocol.count, 0)
    }

    func testNoRequestWithoutProductDisclosureOrWithoutAnalyticsConsent() async {
        await startSDK(consent: .granted)
        XCTAssertFalse(RatingsAnalyticsForwarder.submitIfApproved(event, productDisclosureApproved: false, analyticsConsentApproved: true))
        XCTAssertFalse(RatingsAnalyticsForwarder.submitIfApproved(event, productDisclosureApproved: true, analyticsConsentApproved: false))
        XCTAssertFalse(RatingsAnalyticsForwarder.submitIfApproved(event, productDisclosureApproved: false, analyticsConsentApproved: false))
        await settle()
        XCTAssertEqual(RatingsEgressStubURLProtocol.count, 0)
    }

    func testMalformedPayloadIsNeverForwardedEvenWhenFullyApproved() async {
        await startSDK(consent: .granted)
        let bad = RatingsTelemetryEvent(event: .valueMoment, mode: .shadow,
            policy: RatingsPolicy(version: "has spaces and an email a@b.c", mode: .shadow, minimumConfirmedWins: 3, cooldownDays: 90))
        XCTAssertFalse(RatingsAnalyticsForwarder.submitIfApproved(bad, productDisclosureApproved: true, analyticsConsentApproved: true))
        await settle()
        XCTAssertEqual(RatingsEgressStubURLProtocol.count, 0)
    }

    func testTelemetryValidatorRejectsAnythingOutsideTheClosedContract() {
        let ok: [String: String] = ["v": "1", "mode": "shadow", "config_v": "cleanr-legacy-v1", "moment": "confirmed_export", "reason": "eligible"]
        XCTAssertTrue(RatingsTelemetryContract.isApprovedShape(name: "ratings.eligible", metadata: ok))
        for extraKey in ["user_id", "email", "device_id", "review_text", "rating_stars", "file_name", "photo_hash"] {
            var m = ok; m[extraKey] = "x"
            XCTAssertFalse(RatingsTelemetryContract.isApprovedShape(name: "ratings.eligible", metadata: m), extraKey)
        }
        XCTAssertFalse(RatingsTelemetryContract.isApprovedShape(name: "ratings.other", metadata: ok))
        var bad = ok; bad["mode"] = "turbo"; XCTAssertFalse(RatingsTelemetryContract.isApprovedShape(name: "ratings.eligible", metadata: bad))
        bad = ok; bad["moment"] = "free text"; XCTAssertFalse(RatingsTelemetryContract.isApprovedShape(name: "ratings.eligible", metadata: bad))
        bad = ok; bad["reason"] = "because"; XCTAssertFalse(RatingsTelemetryContract.isApprovedShape(name: "ratings.eligible", metadata: bad))
        bad = ok; bad["config_v"] = "a@b.c"; XCTAssertFalse(RatingsTelemetryContract.isApprovedShape(name: "ratings.eligible", metadata: bad))
        bad = ok; bad["v"] = "2"; XCTAssertFalse(RatingsTelemetryContract.isApprovedShape(name: "ratings.eligible", metadata: bad))
        bad = ok; bad.removeValue(forKey: "config_v"); XCTAssertFalse(RatingsTelemetryContract.isApprovedShape(name: "ratings.eligible", metadata: bad))
    }

    func testFullyApprovedEventIsExactlyOneRequestWithOnlyClosedFields() async {
        await startSDK(consent: .granted)
        XCTAssertTrue(RatingsAnalyticsForwarder.submitIfApproved(event, productDisclosureApproved: true, analyticsConsentApproved: true))
        await settle()
        XCTAssertEqual(RatingsEgressStubURLProtocol.count, 1)
        let body = RatingsEgressStubURLProtocol.bodies.first ?? [:]
        // existing SDK custom-event envelope — no ratings-specific identity, text or extra fields
        XCTAssertEqual(Set(body.keys), ["app_id", "device_hash", "event_name", "metadata"])
        XCTAssertEqual(body["event_name"] as? String, "ratings.value_moment")
        let metadata = body["metadata"] as? [String: String] ?? [:]
        XCTAssertTrue(Set(metadata.keys).isSubset(of: ["v", "mode", "config_v", "moment", "reason"]))
        XCTAssertEqual(metadata["mode"], "shadow")
        XCTAssertNil(metadata["rating_stars"]); XCTAssertNil(metadata["review_text"])
    }

    func testEngineAndSchedulerAloneNeverTransmitAnything_evenWithSDKConsentGranted() async {
        await startSDK(consent: .granted)
        let store = EgressFakeStore()
        let engine = try! RatingsEngine(store: store)                      // default: shadow, inactive
        try! engine.beginSession(now: now)
        for _ in 0..<3 {
            try! engine.recordConfirmedValueMoment(.init(receiptID: UUID(), strength: .strong, isConfirmed: true))
        }
        let opp = RatingsOpportunity(now: now, isForeground: true, hasConfirmedValueMoment: true)
        _ = engine.evaluate(opp)
        var nativeCalls = 0
        _ = engine.requestIfEligible(opp) { nativeCalls += 1; return true }
        let scheduler = RatingsOpportunityScheduler()
        scheduler.schedule(engine: engine, delayNanoseconds: 700_000_000,
                           currentOpportunity: { RatingsOpportunity(now: Date(), isForeground: true, hasConfirmedValueMoment: true) },
                           nativeRequest: { nativeCalls += 1; return true })
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        scheduler.cancel()
        XCTAssertEqual(RatingsEgressStubURLProtocol.count, 0, "no automatic telemetry from engine/scheduler")
        XCTAssertEqual(nativeCalls, 0, "shadow mode never invokes the native bridge")
    }
}

/// Requirement: the engine cannot cause duplicate App Store prompts.
@MainActor
final class RatingsDuplicatePromptTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let active = RatingsPolicy(version: "dup-v1", mode: .active, minimumConfirmedWins: 1, cooldownDays: 90)
    private func opp(_ at: Date) -> RatingsOpportunity {
        RatingsOpportunity(now: at, isForeground: true, hasConfirmedValueMoment: true)
    }
    private func readyEngine(_ store: EgressFakeStore) -> RatingsEngine {
        let e = try! RatingsEngine(policy: active, store: store, activeRequestsAuthorised: true)
        try! e.beginSession(now: now)
        try! e.recordConfirmedValueMoment(.init(receiptID: UUID(), strength: .strong, isConfirmed: true))
        return e
    }

    func testSecondRequestInSameLaunchIsBlocked() {
        let e = readyEngine(EgressFakeStore())
        var calls = 0
        XCTAssertEqual(e.requestIfEligible(opp(now)) { calls += 1; return true }, .nativeRequestInvoked)
        XCTAssertEqual(e.requestIfEligible(opp(now)) { calls += 1; return true }, .suppressed(.alreadyAttemptedThisLaunch))
        XCTAssertEqual(calls, 1)
    }

    func testSecondEngineOnTheSamePersistedStateIsBlockedByCooldown() {
        let store = EgressFakeStore()
        var calls = 0
        XCTAssertEqual(readyEngine(store).requestIfEligible(opp(now)) { calls += 1; return true }, .nativeRequestInvoked)
        // e.g. a host that accidentally constructs a second engine, or a relaunch minutes later
        let second = try! RatingsEngine(policy: active, store: store, activeRequestsAuthorised: true)
        try! second.beginSession(now: now.addingTimeInterval(60))
        try! second.recordConfirmedValueMoment(.init(receiptID: UUID(), strength: .strong, isConfirmed: true))
        XCTAssertEqual(second.requestIfEligible(opp(now.addingTimeInterval(120))) { calls += 1; return true }, .suppressed(.cooldown))
        XCTAssertEqual(calls, 1)
    }

    func testManyConcurrentlyScheduledOpportunitiesInvokeTheNativeBridgeAtMostOnce() async {
        let e = readyEngine(EgressFakeStore())
        var calls = 0
        var schedulers: [RatingsOpportunityScheduler] = []
        for _ in 0..<8 {
            let s = RatingsOpportunityScheduler()
            s.schedule(engine: e, delayNanoseconds: 700_000_000,
                       currentOpportunity: { RatingsOpportunity(now: Date(), isForeground: true, hasConfirmedValueMoment: true) },
                       nativeRequest: { calls += 1; return true })
            schedulers.append(s)
        }
        try? await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertEqual(calls, 1)
        schedulers.forEach { $0.cancel() }
    }

    func testRescheduleReplacesThePendingOpportunity() async {
        let e = readyEngine(EgressFakeStore())
        var calls = 0
        var outcomes = 0
        let s = RatingsOpportunityScheduler()
        for _ in 0..<5 {   // e.g. repeated Save taps: each call must replace, not stack
            s.schedule(engine: e, delayNanoseconds: 700_000_000,
                       currentOpportunity: { RatingsOpportunity(now: Date(), isForeground: true, hasConfirmedValueMoment: true) },
                       nativeRequest: { calls += 1; return true },
                       onOutcome: { _ in outcomes += 1 })
        }
        try? await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(outcomes, 1, "earlier pending opportunities must be cancelled, not merely deduplicated by the engine")
        s.cancel()
    }

    func testSchedulerEnforcesAMinimumDelayEvenIfAHostPassesZero() async {
        let e = readyEngine(EgressFakeStore())
        var calls = 0
        let s = RatingsOpportunityScheduler()
        s.schedule(engine: e, delayNanoseconds: 0,
                   currentOpportunity: { RatingsOpportunity(now: Date(), isForeground: true, hasConfirmedValueMoment: true) },
                   nativeRequest: { calls += 1; return true })
        try? await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(calls, 0, "no request in the same moment as the Save action")
        try? await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertEqual(calls, 1)
        s.cancel()
    }

    func testCancelAfterSchedulingPreventsTheRequestEvenForAnEligibleEngine() async {
        let e = readyEngine(EgressFakeStore())
        var calls = 0
        let s = RatingsOpportunityScheduler()
        s.schedule(engine: e, delayNanoseconds: 700_000_000,
                   currentOpportunity: { RatingsOpportunity(now: Date(), isForeground: true, hasConfirmedValueMoment: true) },
                   nativeRequest: { calls += 1; return true })
        try? await Task.sleep(nanoseconds: 200_000_000)
        s.cancel()                                   // e.g. user opened a modal / started editing / backgrounded
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(calls, 0)
    }

    func testFailedPersistenceNeverInvokesTheNativeBridge() {
        final class FailingStore: RatingsStateStore {
            var snapshot: RatingsStoreSnapshot?
            var allowSaves = 2 // session + value moment succeed, reservation fails
            func load() throws -> RatingsStoreSnapshot? { snapshot }
            func save(_ value: RatingsStoreSnapshot) throws {
                guard allowSaves > 0 else { throw RatingsStorageError.writeFailed }
                allowSaves -= 1
                snapshot = value
            }
        }
        let e = try! RatingsEngine(policy: active, store: FailingStore(), activeRequestsAuthorised: true)
        try! e.beginSession(now: now)
        try! e.recordConfirmedValueMoment(.init(receiptID: UUID(), strength: .strong, isConfirmed: true))
        var calls = 0
        XCTAssertEqual(e.requestIfEligible(opp(now)) { calls += 1; return true }, .persistenceUnavailable)
        XCTAssertEqual(calls, 0)
    }
}

/// Static invariants over the Ratings sources (read from the package checkout; skipped if sources are not on disk,
/// e.g. when the tests run from an archived bundle).
final class RatingsStaticInvariantTests: XCTestCase {
    private func sources() throws -> [(name: String, text: String)] {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Attribr")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            throw XCTSkip("Sources/Attribr not on disk")
        }
        return try files.filter { $0.hasPrefix("Ratings") && $0.hasSuffix(".swift") }.sorted().map {
            ($0, try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8))
        }
    }
    /// Strip comments so doc text cannot mask or trigger an assertion.
    private func code(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let t = line.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix("//") ? "" : String(line)
            }.joined(separator: "\n")
    }

    func testRatingsSourcesHaveNoNetworkingTimersOrNativeReviewCalls() throws {
        let all = try sources()
        XCTAssertGreaterThanOrEqual(all.count, 7)
        for (name, text) in all {
            let c = code(text)
            for forbidden in ["URLSession", "URLRequest", "NWConnection", "SKStoreReviewController",
                              "requestReview(in", "Timer.scheduledTimer", "asyncAfter", "UIApplication"] {
                XCTAssertFalse(c.contains(forbidden), "\(name) must not reference \(forbidden)")
            }
        }
    }

    func testOnlyTheOptionalBridgeImportsStoreKitAndOnlyTheForwarderCallsAttribr() throws {
        for (name, text) in try sources() {
            let c = code(text)
            if name != "RatingsSwiftUIRequestBridge.swift" {
                XCTAssertFalse(c.contains("import StoreKit"), "\(name) must not import StoreKit")
                XCTAssertFalse(c.contains("import SwiftUI"), "\(name) must not import SwiftUI")
            }
            if name != "RatingsAnalyticsForwarder.swift" {
                XCTAssertFalse(c.contains("Attribr.track"), "\(name) must not call the Attribr transport")
            }
            for line in c.split(separator: "\n") where line.hasPrefix("import ") {
                XCTAssertTrue(["import Foundation", "import StoreKit", "import SwiftUI"].contains(String(line)),
                              "\(name): unexpected import \(line)")
            }
        }
    }

    func testBridgeIsAvailabilityGatedAndIOSOnly() throws {
        let bridge = try sources().first { $0.name == "RatingsSwiftUIRequestBridge.swift" }!.text
        XCTAssertTrue(bridge.contains("#if os(iOS) && canImport(StoreKit) && canImport(SwiftUI)"))
        XCTAssertTrue(bridge.contains("@available(iOS 16.0, *)"))
    }

    func testPackageHasNoThirdPartyDependencies() throws {
        let manifest = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Package.swift")
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { throw XCTSkip("Package.swift not on disk") }
        XCTAssertFalse(code(text).contains(".package("), "SDK must keep zero third-party dependencies")
    }
}

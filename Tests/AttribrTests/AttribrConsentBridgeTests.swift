// SPDX-License-Identifier: MIT
//
// 2026-08-12 scan fix — consent bridge for RevenueDiscoveryReporter.
//
// The reporter used to check only `Attribr._apiKey != nil`, bypassing the
// GDPR consent gate entirely. It now consults `Attribr.consentState` /
// `Attribr.isConsentGranted` and parks payloads on the durable queue via
// `Attribr.enqueueRevenueDiscovery(_:attempts:)` when consent is pending.
//
// These tests deliberately run BEFORE any `Attribr.initialize()` call
// (nothing in this suite ever initialises the singleton) and lock the
// pre-init contract: consent reads as "not granted" and enqueue is a safe
// no-op — i.e. the reporter can never send or store anything through the
// bridge before the host app has set the SDK up.

import XCTest
@testable import Attribr

@MainActor
final class AttribrConsentBridgeTests: XCTestCase {

    private let queueDefaultsKey = "com.mrvltechnologies.attribr.queue"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: queueDefaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: queueDefaultsKey)
        super.tearDown()
    }

    func testConsentStateIsNilBeforeInitialize() {
        XCTAssertNil(Attribr.consentState,
                     "pre-init consent state must be nil (SDK not set up)")
    }

    func testIsConsentGrantedIsFalseBeforeInitialize() {
        XCTAssertFalse(Attribr.isConsentGranted,
                       "pre-init must always read as consent NOT granted (fail closed)")
    }

    func testEnqueueRevenueDiscoveryBeforeInitializeIsSafeNoOp() {
        // No singleton → no queue → nothing may be persisted.
        Attribr.enqueueRevenueDiscovery(Data("{}".utf8), attempts: 0)
        XCTAssertNil(UserDefaults.standard.data(forKey: queueDefaultsKey),
                     "pre-init enqueue must not persist anything")
    }
}

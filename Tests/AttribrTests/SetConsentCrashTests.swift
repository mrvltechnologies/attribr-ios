// SPDX-License-Identifier: MIT
//
// v1.4.1 — setConsent()/registerSKAN() previously called preconditionFailure()
// when invoked before Attribr.initialize(), which crashes the host app. An
// external developer's own nonisolated wrapper hit this because their guard
// against it lived in their own code, not the SDK's — meaning any other SDK
// consumer without an equivalent guard would crash. Both are now a safe no-op
// (logged as an error) instead.
//
// Uses Attribr.resetForTesting() (internal, not public API) so this suite can
// exercise both the pre-init and post-init paths without permanently
// initialising the process-wide singleton for every other test file.

import XCTest
@testable import Attribr

@MainActor
final class SetConsentCrashTests: XCTestCase {

    private let consentDefaultsKey = "com.mrvltechnologies.attribr.consent"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: consentDefaultsKey)
    }

    override func tearDown() {
        Attribr.resetForTesting()
        UserDefaults.standard.removeObject(forKey: consentDefaultsKey)
        super.tearDown()
    }

    // MARK: - Pre-init: must not crash

    func testSetConsentBeforeInitializeDoesNotCrash() {
        // If this were still `preconditionFailure`, the test process would abort here.
        Attribr.setConsent(.granted)
        XCTAssertNil(Attribr.consentState, "a no-op call must not create a phantom consent state")
    }

    func testRegisterSKANBeforeInitializeDoesNotCrash() {
        Attribr.registerSKAN()
        // No assertion beyond "did not crash" — there is no observable state change to check
        // for a call that silently no-ops when the singleton doesn't exist yet.
    }

    // MARK: - Normal path: initialize -> setConsent unchanged

    func testInitializeThenSetConsentGrantedWorksNormally() {
        Attribr.initialize(apiKey: "attr_test_TESTKEY000000000000000000000000000000000")
        XCTAssertFalse(Attribr.isConsentGranted, "consent must default to not-granted immediately after initialize")

        Attribr.setConsent(.granted)
        XCTAssertEqual(Attribr.consentState, .granted)
        XCTAssertTrue(Attribr.isConsentGranted)
    }

    func testInitializeThenSetConsentRevokedWorksNormally() {
        Attribr.initialize(apiKey: "attr_test_TESTKEY000000000000000000000000000000000")
        Attribr.setConsent(.revoked)
        XCTAssertEqual(Attribr.consentState, .revoked)
        XCTAssertFalse(Attribr.isConsentGranted)
    }

    // MARK: - No network before consent

    func testTrackingCallsAreNoOpsBeforeConsentIsGranted() {
        // Regression guard for the core consent contract (unchanged by this fix):
        // every tracking entry point synchronously checks `consent.isGranted`
        // BEFORE it ever spawns a Task or touches the network layer, so calling
        // these with consent still `.unknown` must be a same-thread no-op.
        Attribr.initialize(apiKey: "attr_test_TESTKEY000000000000000000000000000000000")
        XCTAssertFalse(Attribr.isConsentGranted)

        Attribr.trackLaunch()
        Attribr.updateConversionValue(eventName: "purchase", value: 4.99)
        Attribr.registerSKAN()

        // Still not granted — none of the above calls could have silently granted
        // consent or otherwise mutated state as a side effect of "trying" to track.
        XCTAssertFalse(Attribr.isConsentGranted)
        XCTAssertEqual(Attribr.consentState, .unknown)
    }
}

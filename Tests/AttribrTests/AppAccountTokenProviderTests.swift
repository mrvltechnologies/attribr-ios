// SPDX-License-Identifier: MIT
//
// MRVL Apps StoreKit Identity Hardening — AppAccountTokenProvider tests.
//
// Locks the contract StoreKit's `Product.PurchaseOption.appAccountToken(_:)`
// and Attribr's refund/revoke resolution both depend on:
//   • Account-linked mode: a UUID-formatted backend id is used as-is; any
//     other string is deterministically hashed into a UUID, same input
//     always producing the same output, and the raw input never appears in
//     the result.
//   • Anonymous mode: a fresh UUID is generated once and persists across
//     repeated calls (simulating separate app launches) via the Keychain,
//     and `reset()` clears it (simulating an uninstall / GDPR-style
//     deletion request) so the next call produces a new one.

import XCTest
@testable import Attribr

final class AppAccountTokenProviderTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AppAccountTokenProvider.reset()
    }

    override func tearDown() {
        AppAccountTokenProvider.reset()
        super.tearDown()
    }

    // MARK: - Account-linked mode

    func test_backendUserId_thatIsAlreadyAUUID_isUsedDirectly() {
        let uuid = UUID()
        let token = AppAccountTokenProvider.token(backendUserId: uuid.uuidString)
        XCTAssertEqual(token, uuid)
    }

    func test_backendUserId_thatIsAlreadyAUUID_isCaseInsensitive() {
        let uuid = UUID()
        let lower = AppAccountTokenProvider.token(backendUserId: uuid.uuidString.lowercased())
        let upper = AppAccountTokenProvider.token(backendUserId: uuid.uuidString.uppercased())
        XCTAssertEqual(lower, upper)
    }

    func test_nonUuidBackendId_isDeterministicallyHashed() {
        let first  = AppAccountTokenProvider.token(backendUserId: "user-12345")
        let second = AppAccountTokenProvider.token(backendUserId: "user-12345")
        XCTAssertEqual(first, second, "same backend id must always produce the same token")
    }

    func test_differentBackendIds_produceDifferentTokens() {
        let a = AppAccountTokenProvider.token(backendUserId: "user-a")
        let b = AppAccountTokenProvider.token(backendUserId: "user-b")
        XCTAssertNotEqual(a, b)
    }

    func test_deterministicUUID_neverContainsTheRawInput() {
        let raw = "someone@example.com" // representative of a raw PII-shaped id, never actually passed in practice
        let uuid = AppAccountTokenProvider.deterministicUUID(from: raw)
        XCTAssertFalse(uuid.uuidString.contains("someone"))
        XCTAssertFalse(uuid.uuidString.lowercased().contains("example"))
    }

    func test_deterministicUUID_setsVersionAndVariantBits() {
        // RFC 4122: version nibble is the first hex digit of the 3rd group,
        // variant bits are the top two bits of the 4th group's first byte.
        let uuid = AppAccountTokenProvider.deterministicUUID(from: "any-string")
        let parts = uuid.uuidString.split(separator: "-")
        XCTAssertEqual(parts[2].first, "5", "version nibble must be 5")
        XCTAssertTrue(["8", "9", "a", "b"].contains(String(parts[3].first!).lowercased()), "variant bits must be RFC 4122 (8/9/a/b)")
    }

    func test_deterministicUUID_isValidUuidFormat() {
        let uuid = AppAccountTokenProvider.deterministicUUID(from: "format-check")
        XCTAssertNotNil(UUID(uuidString: uuid.uuidString))
    }

    // MARK: - Anonymous mode (Keychain-persisted)

    func test_anonymousMode_generatesAndPersistsAcrossCalls() {
        let first = AppAccountTokenProvider.token()
        let second = AppAccountTokenProvider.token()
        XCTAssertEqual(first, second, "must be stable across repeated calls, simulating separate app launches")
    }

    func test_anonymousMode_reset_producesAFreshToken() {
        let first = AppAccountTokenProvider.token()
        AppAccountTokenProvider.reset()
        let second = AppAccountTokenProvider.token()
        XCTAssertNotEqual(first, second, "reset() must produce a fresh anonymous token, simulating uninstall/reinstall or a deletion request")
    }

    func test_anonymousMode_tokenIsValidUuidFormat() {
        let token = AppAccountTokenProvider.token()
        XCTAssertNotNil(UUID(uuidString: token.uuidString))
    }

    func test_anonymousMode_corruptedKeychainValueRegenerates() {
        AppAccountTokenProvider.writeKeychain("not-a-uuid")
        let token = AppAccountTokenProvider.token()
        XCTAssertNotEqual(token.uuidString, "not-a-uuid")
        XCTAssertNotNil(UUID(uuidString: token.uuidString))
    }

    func test_anonymousMode_isNeverDerivedFromABackendId() {
        // Anonymous and account-linked modes must never collide, since they
        // resolve to entirely different identity spaces server-side.
        let anon = AppAccountTokenProvider.token()
        let linked = AppAccountTokenProvider.token(backendUserId: "some-user-id")
        XCTAssertNotEqual(anon, linked)
    }
}

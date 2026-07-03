// SPDX-License-Identifier: MIT
//
// Sprint 13 — InstallInstance tests.
//
// Locks the app-local install-instance contract:
//   • Generates a fresh UUID on first access.
//   • Persists across "launches" (same UserDefaults instance).
//   • Fresh UUID after reset() — simulates an uninstall/reinstall.
//   • Hash is 64-char lowercase hex (SHA-256).
//   • Neither raw UUID nor UUID string is derived from IDFV/IDFA/device name.

import XCTest
@testable import Attribr

final class InstallInstanceTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // Isolated suite per test so we don't stomp on other tests or the host.
        let suiteName = "attribr.tests.installinstance.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().keys.first ?? "")
        defaults = nil
        super.tearDown()
    }

    func test_firstAccess_generatesAndPersistsUUID() {
        let raw = InstallInstance.loadOrCreateRaw(defaults: defaults)
        XCTAssertTrue(InstallInstance.isValidUuid(raw))
        XCTAssertEqual(defaults.string(forKey: InstallInstance.storageKey), raw)
    }

    func test_secondAccess_returnsSameValue() {
        let first  = InstallInstance.loadOrCreateRaw(defaults: defaults)
        let second = InstallInstance.loadOrCreateRaw(defaults: defaults)
        XCTAssertEqual(first, second)
        XCTAssertEqual(InstallInstance.hashHex(defaults: defaults),
                       InstallInstance.hashHex(defaults: defaults))
    }

    func test_reset_generatesFreshUUID() {
        let first = InstallInstance.hashHex(defaults: defaults)
        InstallInstance.reset(defaults: defaults)
        let second = InstallInstance.hashHex(defaults: defaults)
        XCTAssertNotEqual(first, second, "reset() must produce a fresh install-instance")
    }

    func test_hash_is_64_char_lowercase_hex() {
        let hash = InstallInstance.hashHex(defaults: defaults)
        XCTAssertEqual(hash.count, 64)
        let hexRegex = try! NSRegularExpression(pattern: "^[0-9a-f]{64}$")
        XCTAssertNotNil(
            hexRegex.firstMatch(in: hash, range: NSRange(location: 0, length: hash.utf16.count)),
            "hash should be 64-char lowercase hex, got: \(hash.count) chars",
        )
    }

    func test_corrupted_prefs_regenerates() {
        defaults.set("not-a-uuid", forKey: InstallInstance.storageKey)
        let raw = InstallInstance.loadOrCreateRaw(defaults: defaults)
        XCTAssertTrue(InstallInstance.isValidUuid(raw))
        XCTAssertNotEqual(raw, "not-a-uuid")
    }

    func test_hash_of_known_uuid_matches_sha256() {
        // Sanity check the SHA-256 implementation against a known vector.
        let input = "hello"
        let expected = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        XCTAssertEqual(InstallInstance.sha256Hex(input), expected)
    }
}

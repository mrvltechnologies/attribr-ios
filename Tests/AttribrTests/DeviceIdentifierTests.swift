import XCTest
import CryptoKit
@testable import Attribr

final class DeviceIdentifierTests: XCTestCase {

    func testHashIs64HexChars() {
        let hash = DeviceIdentifier.computeHash()
        XCTAssertEqual(hash.count, 64, "SHA-256 hex must be exactly 64 characters")
        XCTAssertTrue(hash.allSatisfy { $0.isHexDigit }, "Hash must be lowercase hex")
    }

    func testHashIsLowercaseHex() {
        let hash = DeviceIdentifier.computeHash()
        XCTAssertEqual(hash, hash.lowercased(), "Hash must be lowercase")
    }

    func testHashIsDeterministic() {
        // Same inputs → same output (SHA-256 is deterministic)
        let h1 = DeviceIdentifier.computeHash()
        let h2 = DeviceIdentifier.computeHash()
        XCTAssertEqual(h1, h2, "Hash must be deterministic")
    }

    func testHashUsesKnownAlgorithm() {
        // Verify against a known SHA-256 value to confirm algorithm hasn't changed.
        // On the test host (macOS, no UIKit), IDFV = "test-idfv-placeholder"
        // and bundle = the test bundle identifier.
        let bundle = Bundle.main.bundleIdentifier ?? "unknown"
        let raw = "test-idfv-placeholder:\(bundle):attribr.mrvl.2026"
        let digest = SHA256.hash(data: Data(raw.utf8))
        let expected = digest.compactMap { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(DeviceIdentifier.computeHash(), expected)
    }

    func testInstanceCachesHash() {
        let identifier = DeviceIdentifier()
        let first = identifier.hash()
        let second = identifier.hash()
        XCTAssertEqual(first, second, "Cached value must match first call")
    }

    func testHashDoesNotContainPII() {
        // Raw IDFV must never appear in the hash string
        let hash = DeviceIdentifier.computeHash()
        XCTAssertFalse(hash.contains("test-idfv-placeholder"), "Raw IDFV must not appear in hash")
    }
}

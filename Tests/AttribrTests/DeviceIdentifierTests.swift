import XCTest
import CryptoKit
@testable import Attribr

final class DeviceIdentifierTests: XCTestCase {

    /// Mutable IDFV source for injecting into DeviceIdentifier — simulates
    /// the pre-first-unlock window (nil) and its end (value appears).
    private final class IDFVBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: String?
        var value: String? {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
        init(_ value: String?) { _value = value }
    }

    override func setUp() {
        super.setUp()
        // The nil-IDFV tests assert nothing gets persisted to iCloud KV, so
        // start from a clean slate (other tests legitimately write this key).
        NSUbiquitousKeyValueStore.default.removeObject(forKey: DeviceIdentifier.kvKey)
    }

    override func tearDown() {
        NSUbiquitousKeyValueStore.default.removeObject(forKey: DeviceIdentifier.kvKey)
        super.tearDown()
    }

    func testHashIs64HexChars() throws {
        let hash = try XCTUnwrap(DeviceIdentifier.computeHash())
        XCTAssertEqual(hash.count, 64, "SHA-256 hex must be exactly 64 characters")
        XCTAssertTrue(hash.allSatisfy { $0.isHexDigit }, "Hash must be lowercase hex")
    }

    func testHashIsLowercaseHex() throws {
        let hash = try XCTUnwrap(DeviceIdentifier.computeHash())
        XCTAssertEqual(hash, hash.lowercased(), "Hash must be lowercase")
    }

    func testHashIsDeterministic() {
        // Same inputs → same output (SHA-256 is deterministic)
        let h1 = DeviceIdentifier.computeHash()
        let h2 = DeviceIdentifier.computeHash()
        XCTAssertNotNil(h1)
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

    func testHashDoesNotContainPII() throws {
        // Raw IDFV must never appear in the hash string
        let hash = try XCTUnwrap(DeviceIdentifier.computeHash())
        XCTAssertFalse(hash.contains("test-idfv-placeholder"), "Raw IDFV must not appear in hash")
    }

    // ── Nil IDFV (pre-first-unlock) fail-closed behaviour ─────────────────

    func testNilIDFVReturnsEphemeralHashWithoutCaching() {
        let identifier = DeviceIdentifier(idfvProvider: { nil })

        let h1 = identifier.hash()
        let h2 = identifier.hash()

        // Still a well-formed hash — callers never see a failure…
        XCTAssertEqual(h1.count, 64)
        XCTAssertTrue(h1.allSatisfy { $0.isHexDigit })
        // …but nothing was cached: each call re-derives from a fresh random
        // UUID, so two calls differ (the old bug cached the first one forever).
        XCTAssertNotEqual(h1, h2, "nil-IDFV hash must be ephemeral, never memoised")
        // And crucially, nothing was persisted to iCloud KV.
        XCTAssertNil(
            NSUbiquitousKeyValueStore.default.string(forKey: DeviceIdentifier.kvKey),
            "nil-IDFV hash must never be written to iCloud KV"
        )
    }

    func testHashRecoversOnceIDFVBecomesAvailable() {
        let box = IDFVBox(nil)
        let identifier = DeviceIdentifier(idfvProvider: { box.value })

        // Pre-unlock: ephemeral, uncached.
        _ = identifier.hash()

        // Device unlocked — IDFV now available. The next call must derive the
        // real IDFV-based hash and cache it (the old bug made this impossible).
        box.value = "test-idfv-placeholder"
        let real = identifier.hash()
        XCTAssertEqual(real, DeviceIdentifier.computeHash(idfv: "test-idfv-placeholder"))
        XCTAssertEqual(identifier.hash(), real, "IDFV-derived hash must now be cached")
        // iCloud KV persistence is best-effort and silently no-ops on the
        // unentitled test host (see DeviceIdentifier doc comment), so only
        // assert that IF anything was persisted, it is the real hash — an
        // ephemeral nil-IDFV hash must never end up there.
        if let persisted = NSUbiquitousKeyValueStore.default.string(forKey: DeviceIdentifier.kvKey) {
            XCTAssertEqual(persisted, real,
                           "only the IDFV-derived hash may ever reach iCloud KV")
        }
    }
}

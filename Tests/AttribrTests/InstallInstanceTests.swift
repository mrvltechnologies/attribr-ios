// SPDX-License-Identifier: MIT
//
// Sprint 13 — InstallInstance tests.
//
// Locks the app-local install-instance contract:
//   • Generates a fresh UUID on first access.
//   • Persists across "launches" (same backing directory).
//   • Fresh UUID after reset() — simulates an uninstall/reinstall.
//   • Hash is 64-char lowercase hex (SHA-256).
//   • Neither raw UUID nor UUID string is derived from IDFV/IDFA/device name.
//
// 2026-08-12 — storage moved from UserDefaults to a backup-excluded file
// (restore-contamination fix). Tests now inject a temp directory instead of
// a UserDefaults suite; a suite is kept only for the legacy-migration tests.

import XCTest
@testable import Attribr

final class InstallInstanceTests: XCTestCase {

    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        // Isolated per-test directory + defaults suite so we don't stomp on
        // other tests or the host.
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("attribr.tests.installinstance.\(UUID().uuidString)", isDirectory: true)
        suiteName = "attribr.tests.installinstance.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func test_firstAccess_generatesAndPersistsUUID() throws {
        let raw = InstallInstance.loadOrCreateRaw(directory: directory, defaults: defaults)
        XCTAssertTrue(InstallInstance.isValidUuid(raw))
        let stored = try String(contentsOf: InstallInstance.fileURL(in: directory), encoding: .utf8)
        XCTAssertEqual(stored, raw)
    }

    func test_secondAccess_returnsSameValue() {
        let first  = InstallInstance.loadOrCreateRaw(directory: directory, defaults: defaults)
        let second = InstallInstance.loadOrCreateRaw(directory: directory, defaults: defaults)
        XCTAssertEqual(first, second)
        XCTAssertEqual(InstallInstance.hashHex(directory: directory, defaults: defaults),
                       InstallInstance.hashHex(directory: directory, defaults: defaults))
    }

    func test_reset_generatesFreshUUID() {
        let first = InstallInstance.hashHex(directory: directory, defaults: defaults)
        InstallInstance.reset(directory: directory, defaults: defaults)
        let second = InstallInstance.hashHex(directory: directory, defaults: defaults)
        XCTAssertNotEqual(first, second, "reset() must produce a fresh install-instance")
    }

    func test_hash_is_64_char_lowercase_hex() {
        let hash = InstallInstance.hashHex(directory: directory, defaults: defaults)
        XCTAssertEqual(hash.count, 64)
        let hexRegex = try! NSRegularExpression(pattern: "^[0-9a-f]{64}$")
        XCTAssertNotNil(
            hexRegex.firstMatch(in: hash, range: NSRange(location: 0, length: hash.utf16.count)),
            "hash should be 64-char lowercase hex, got: \(hash.count) chars",
        )
    }

    func test_corrupted_file_regenerates() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data("not-a-uuid".utf8).write(to: InstallInstance.fileURL(in: directory))
        let raw = InstallInstance.loadOrCreateRaw(directory: directory, defaults: defaults)
        XCTAssertTrue(InstallInstance.isValidUuid(raw))
        XCTAssertNotEqual(raw, "not-a-uuid")
    }

    func test_hash_of_known_uuid_matches_sha256() {
        // Sanity check the SHA-256 implementation against a known vector.
        let input = "hello"
        let expected = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        XCTAssertEqual(InstallInstance.sha256Hex(input), expected)
    }

    // ── Migration from the legacy UserDefaults store ───────────────────────

    func test_migration_adoptsLegacyUserDefaultsValue() throws {
        // A pre-fix install has its UUID in UserDefaults only.
        let legacy = UUID().uuidString
        defaults.set(legacy, forKey: InstallInstance.storageKey)

        let raw = InstallInstance.loadOrCreateRaw(directory: directory, defaults: defaults)

        // Identity is preserved for current installs…
        XCTAssertEqual(raw, legacy, "migration must keep the existing install identity")
        // …the file store now owns it…
        let stored = try String(contentsOf: InstallInstance.fileURL(in: directory), encoding: .utf8)
        XCTAssertEqual(stored, legacy)
        // …and the UserDefaults copy is gone so backups stop carrying it.
        XCTAssertNil(defaults.string(forKey: InstallInstance.storageKey),
                     "legacy UserDefaults copy must be removed after migration")
    }

    func test_migration_ignoresCorruptLegacyValue() {
        defaults.set("not-a-uuid", forKey: InstallInstance.storageKey)
        let raw = InstallInstance.loadOrCreateRaw(directory: directory, defaults: defaults)
        XCTAssertTrue(InstallInstance.isValidUuid(raw))
        XCTAssertNotEqual(raw, "not-a-uuid")
    }

    func test_fileStore_winsOverLegacyValue() {
        // Once migrated (or freshly created), the file is authoritative even
        // if a stale UserDefaults value reappears (e.g. restored backup).
        let current = InstallInstance.loadOrCreateRaw(directory: directory, defaults: defaults)
        defaults.set(UUID().uuidString, forKey: InstallInstance.storageKey)
        let again = InstallInstance.loadOrCreateRaw(directory: directory, defaults: defaults)
        XCTAssertEqual(again, current)
    }

    func test_reset_clearsLegacyUserDefaultsCopyToo() {
        defaults.set(UUID().uuidString, forKey: InstallInstance.storageKey)
        _ = InstallInstance.hashHex(directory: directory, defaults: defaults)
        InstallInstance.reset(directory: directory, defaults: defaults)
        XCTAssertNil(defaults.string(forKey: InstallInstance.storageKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: InstallInstance.fileURL(in: directory).path))
    }

    // ── Backup exclusion ───────────────────────────────────────────────────

    func test_storeFile_isExcludedFromBackup() throws {
        _ = InstallInstance.loadOrCreateRaw(directory: directory, defaults: defaults)
        let url = InstallInstance.fileURL(in: directory)
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true,
                       "install-instance file must never ride an iCloud backup onto a fresh install")
    }
}

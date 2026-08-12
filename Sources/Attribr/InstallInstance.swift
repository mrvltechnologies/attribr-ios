// SPDX-License-Identifier: MIT
//
// InstallInstance — Sprint 13.
//
// Generates and persists a random, app-local UUID that Attribr uses to
// distinguish `returning_launch` from `reinstall_candidate` events.
//
// The RAW UUID never leaves the device. Only its SHA-256 hex digest is sent
// on the wire, in the `sdk_install_instance_id_hash` field. When the user
// uninstalls the app, iOS clears the app container, so a reinstall produces
// a fresh UUID → the backend correctly classifies the next `trackLaunch()`
// as `reinstall_candidate` for that (app_id, device_hash) pair.
//
// STORAGE (2026-08-12 scan fix, mirrors the Kotlin SDK's `no_backup` fix):
// the UUID originally lived in UserDefaults, but UserDefaults is included in
// iCloud backups and device transfers — a restore onto a *fresh* install
// resurrected the old UUID and defeated `reinstall_candidate` classification.
// It now lives in a file under Application Support/Attribr with
// `isExcludedFromBackup = true`, so backups/transfers never carry it. A
// one-time migration adopts any legacy UserDefaults value (current installs
// keep their identity) and then deletes the UserDefaults copy so backups
// stop carrying it going forward.
//
// This value is NOT:
//   • an advertising identifier (IDFA)
//   • a platform-provided device identifier (IDFV)
//   • hardware fingerprint (serial, MAC, device name)
//   • a user identifier
//
// It is a per-install-instance random value, useful only for Attribr's
// own new/returning/reinstall_candidate classification.

import Foundation
import CryptoKit

public enum InstallInstance {

    /// Legacy UserDefaults key — now only a migration SOURCE, never written.
    /// Deliberately in the SDK's own namespace to avoid clashing with
    /// host-app keys.
    static let storageKey = "attribr.installInstanceId"

    /// File name of the backup-excluded store inside `defaultDirectory()`.
    static let fileName = "attribr.install-instance"

    /// Reset the stored UUID. Called from `Attribr.deleteAllData` so the
    /// user's GDPR-style deletion request is honoured on-device too.
    public static func reset() {
        reset(directory: defaultDirectory(), defaults: .standard)
    }

    /// Return the SHA-256 hex digest of the app-local UUID, generating and
    /// persisting the UUID on first call. Deterministic across launches
    /// until the app is uninstalled or `reset()` is called.
    public static func hashHex() -> String {
        hashHex(directory: defaultDirectory(), defaults: .standard)
    }

    // ── Internals (injectable for tests) ──────────────────────────────────

    /// Production storage directory: `Application Support/Attribr`. App-
    /// container-scoped, wiped on uninstall (preserving the reinstall
    /// signal), and each write marks the file backup-excluded so iCloud
    /// backup / device transfer never carries it onto a fresh install.
    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Attribr", isDirectory: true)
    }

    static func reset(directory: URL, defaults: UserDefaults = .standard) {
        try? FileManager.default.removeItem(at: fileURL(in: directory))
        // Also clear any lingering legacy copy so it can't be re-migrated.
        defaults.removeObject(forKey: storageKey)
    }

    static func hashHex(directory: URL, defaults: UserDefaults = .standard) -> String {
        let raw = loadOrCreateRaw(directory: directory, defaults: defaults)
        return sha256Hex(raw)
    }

    /// Load-or-create the raw UUID. Kept `internal` (test-accessible) but
    /// not `public` — the raw value is intentionally never exposed to
    /// host-app code.
    ///
    /// Resolution order:
    ///   1. Backup-excluded file (current store).
    ///   2. Legacy UserDefaults value → migrated into the file once, then
    ///      removed from UserDefaults so future backups stop carrying it.
    ///   3. Fresh UUID.
    static func loadOrCreateRaw(directory: URL, defaults: UserDefaults = .standard) -> String {
        let url = fileURL(in: directory)

        if let existing = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           isValidUuid(existing) {
            return existing
        }

        // One-time migration from the legacy UserDefaults store — keeps the
        // identity of installs that predate the file-backed store.
        if let legacy = defaults.string(forKey: storageKey), isValidUuid(legacy) {
            write(legacy, to: url)
            defaults.removeObject(forKey: storageKey)
            return legacy
        }

        let fresh = UUID().uuidString
        write(fresh, to: url)
        return fresh
    }

    /// Persist the UUID and mark the file backup-excluded. Best-effort: if
    /// the write fails (disk full, sandbox oddity) we still return a working
    /// in-memory value upstream — a re-generated UUID on the next launch is
    /// a tolerable false `reinstall_candidate`, whereas crashing is not.
    private static func write(_ value: String, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data(value.utf8).write(to: url, options: .atomic)
        // The whole point of the file-backed store: never let this value
        // ride an iCloud backup onto a different install.
        var resourceURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? resourceURL.setResourceValues(values)
    }

    static func fileURL(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Sanity check — UUID string format. Rejects any value that isn't a
    /// canonical UUID (guards against a corrupted store entry).
    static func isValidUuid(_ s: String) -> Bool {
        UUID(uuidString: s) != nil
    }

    static func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

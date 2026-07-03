// SPDX-License-Identifier: MIT
//
// InstallInstance — Sprint 13.
//
// Generates and persists a random, app-local UUID that Attribr uses to
// distinguish `returning_launch` from `reinstall_candidate` events.
//
// The RAW UUID never leaves the device. Only its SHA-256 hex digest is sent
// on the wire, in the `sdk_install_instance_id_hash` field. When the user
// uninstalls the app, iOS clears UserDefaults, so a reinstall produces a
// fresh UUID → the backend correctly classifies the next `trackLaunch()`
// as `reinstall_candidate` for that (app_id, device_hash) pair.
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

    /// UserDefaults key. Deliberately in the SDK's own namespace to avoid
    /// clashing with host-app keys.
    static let storageKey = "attribr.installInstanceId"

    /// Reset the stored UUID. Called from `Attribr.deleteAllData` so the
    /// user's GDPR-style deletion request is honoured on-device too.
    public static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }

    /// Return the SHA-256 hex digest of the app-local UUID, generating and
    /// persisting the UUID on first call. Deterministic across launches
    /// until the app is uninstalled or `reset()` is called.
    public static func hashHex(defaults: UserDefaults = .standard) -> String {
        let raw = loadOrCreateRaw(defaults: defaults)
        return sha256Hex(raw)
    }

    // ── Internals ──────────────────────────────────────────────────────────

    /// Load-or-create the raw UUID. Kept `internal` (test-accessible) but
    /// not `public` — the raw value is intentionally never exposed to
    /// host-app code.
    static func loadOrCreateRaw(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: storageKey), isValidUuid(existing) {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: storageKey)
        return fresh
    }

    /// Sanity check — UUID string format. Rejects any value that isn't a
    /// canonical UUID (guards against a corrupted UserDefaults entry).
    static func isValidUuid(_ s: String) -> Bool {
        UUID(uuidString: s) != nil
    }

    static func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

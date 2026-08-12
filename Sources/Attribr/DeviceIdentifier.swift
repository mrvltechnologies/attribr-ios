import Foundation
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

/// Generates and caches a privacy-preserving device fingerprint.
///
/// Algorithm: SHA-256( identifierForVendor + bundleId + staticSalt )
///
/// - ATT-compliant: no IDFA used at any point.
/// - The raw IDFV never leaves the device; only its SHA-256 does.
/// - iCloud KV persistence: attempted but silently no-ops when the host app
///   lacks the `com.apple.developer.ubiquity-kvstore-identifier` entitlement
///   (e.g. Guard). In that case, the hash is IDFV-derived only and is NOT
///   reinstall-persistent via iCloud.
/// - Deletion: call `clearPersistedHash()` from `deleteAllData` to clear
///   iCloud KV, the in-memory cache, and `lastSeenAt`. Without this,
///   the iCloud-resident copy (when the entitlement IS present) would survive.
final class DeviceIdentifier: @unchecked Sendable {
    // A fixed per-SDK salt so two SDKs using the same IDFV produce
    // different hashes. Not a secret — just a domain separator.
    private static let salt = "attribr.mrvl.2026"
    static let kvKey = "com.mrvltechnologies.attribr.device_hash"
    private let lock = NSLock()
    private var _cached: String?

    /// Injectable IDFV source — production default reads
    /// `UIDevice.current.identifierForVendor`; tests inject `nil` to exercise
    /// the pre-first-unlock path (unreachable on the macOS test host).
    private let idfvProvider: @Sendable () -> String?

    init(idfvProvider: @escaping @Sendable () -> String? = DeviceIdentifier.idfvString) {
        self.idfvProvider = idfvProvider
    }

    func hash() -> String {
        lock.withLock {
            if let cached = _cached { return cached }

            // Check iCloud KV first (survives reinstalls when entitlement present)
            let kv = NSUbiquitousKeyValueStore.default
            if let stored = kv.string(forKey: Self.kvKey), !stored.isEmpty {
                _cached = stored
                return stored
            }

            // FAIL CLOSED when IDFV is unavailable. identifierForVendor is
            // nil before the first device unlock after a restart (and briefly
            // after reinstalls). The old behaviour substituted a random UUID
            // and then CACHED the result — permanently poisoning the iCloud
            // KV copy with an identity no other launch can ever re-derive.
            // Instead: return an ephemeral hash for this call only, persist
            // NOTHING (no memory cache, no iCloud KV), so the next call
            // retries and derives the real IDFV-based hash once available.
            guard let idfv = idfvProvider() else {
                return Self.computeHash(idfv: UUID().uuidString)
            }

            // Derive fresh hash from IDFV + bundleId + salt
            let hash = Self.computeHash(idfv: idfv)

            // Persist to iCloud KV (best-effort — silent no-op if entitlement absent)
            kv.set(hash, forKey: Self.kvKey)
            kv.synchronize()

            _cached = hash
            return hash
        }
    }

    /// Remove the persisted device hash from iCloud KV and clear the in-memory cache.
    /// The next call to `hash()` will re-derive from the current IDFV.
    /// Call this from `deleteAllData` to ensure GDPR deletion is complete
    /// even when the iCloud KV entitlement is present.
    func clearPersistedHash() {
        lock.withLock {
            _cached = nil
            let kv = NSUbiquitousKeyValueStore.default
            kv.removeObject(forKey: Self.kvKey)
            kv.synchronize()
        }
    }

    /// Convenience for the common case — nil when IDFV is unavailable
    /// (pre-first-unlock on iOS); the caller must NOT persist anything then.
    static func computeHash() -> String? {
        guard let idfv = idfvString() else { return nil }
        return computeHash(idfv: idfv)
    }

    static func computeHash(idfv: String) -> String {
        let bundle = Bundle.main.bundleIdentifier ?? "unknown"
        let raw = "\(idfv):\(bundle):\(salt)"

        let data = Data(raw.utf8)
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func idfvString() -> String? {
        #if canImport(UIKit)
        // nil before first unlock / early after install — see hash().
        return UIDevice.current.identifierForVendor?.uuidString
        #else
        // macOS fallback (not used in production SDK but needed for unit tests)
        return "test-idfv-placeholder"
        #endif
    }
}

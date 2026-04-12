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
/// - Reinstall-exploit guard: final hash is stored in iCloud KV
///   (`NSUbiquitousKeyValueStore`) so it survives app reinstalls tied
///   to the same Apple ID.
/// - The raw IDFV never leaves the device; only its SHA-256 does.
final class DeviceIdentifier: @unchecked Sendable {
    // A fixed per-SDK salt so two SDKs using the same IDFV produce
    // different hashes. Not a secret — just a domain separator.
    private static let salt = "attribr.mrvl.2026"
    private static let kvKey = "com.mrvltechnologies.attribr.device_hash"
    private let lock = NSLock()
    private var _cached: String?

    func hash() -> String {
        lock.withLock {
            if let cached = _cached { return cached }

            // Check iCloud KV first (survives reinstalls)
            let kv = NSUbiquitousKeyValueStore.default
            if let stored = kv.string(forKey: Self.kvKey), !stored.isEmpty {
                _cached = stored
                return stored
            }

            // Derive fresh hash from IDFV + bundleId + salt
            let hash = Self.computeHash()

            // Persist to iCloud KV (best-effort — no crash if iCloud unavailable)
            kv.set(hash, forKey: Self.kvKey)
            kv.synchronize()

            _cached = hash
            return hash
        }
    }

    static func computeHash() -> String {
        let idfv = idfvString()
        let bundle = Bundle.main.bundleIdentifier ?? "unknown"
        let raw = "\(idfv):\(bundle):\(salt)"

        let data = Data(raw.utf8)
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func idfvString() -> String {
        #if canImport(UIKit)
        return UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        #else
        // macOS fallback (not used in production SDK but needed for unit tests)
        return "test-idfv-placeholder"
        #endif
    }
}

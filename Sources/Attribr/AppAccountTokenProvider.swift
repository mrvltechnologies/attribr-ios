// SPDX-License-Identifier: MIT
//
// AppAccountTokenProvider — MRVL Apps StoreKit Identity Hardening.
//
// Produces the UUID host apps pass to StoreKit's
// `Product.PurchaseOption.appAccountToken(_:)` when calling
// `product.purchase(options:)`. Apple echoes this value back on every S2S
// notification for that transaction (including REFUND/REVOKE), which lets
// Attribr's backend strongly tie a confirmed refund back to the specific
// app account or device-local install that made the purchase — closing the
// gap where a transaction could only be resolved to
// customer_id/app_id/original_transaction_id, never to an actual user.
//
// Two modes, chosen automatically by whether the host app passes a backend
// account id:
//
// - **Account-linked apps** (`backendUserId` provided): the app's own
//   backend user id is used to derive the token. If it's already a UUID
//   (e.g. a Supabase `auth.uid()`), it's used directly. Otherwise it is
//   deterministically hashed into a UUID (SHA-256, RFC 4122 version/variant
//   bits set) — never the raw id itself. Same backend id always produces
//   the same token, on every device, which is what you want when the
//   value has to match across a signed-in user's multiple devices.
//
// - **Anonymous/local-only apps** (no `backendUserId`): a random UUID is
//   generated once and persisted in the Keychain — deliberately Keychain,
//   not UserDefaults, so the SAME token survives an app reinstall on the
//   same device. This matters for refund-abuse detection specifically: a
//   "buy, consume, refund, reinstall, buy again" pattern should still
//   resolve to the same appAccountToken. (Contrast with
//   `InstallInstance`, which deliberately resets on reinstall because its
//   job is new/returning/reinstall_candidate *classification* — the
//   opposite persistence goal.)
//
// Never derived from IDFV, any hardware identifier, or raw PII: this value
// is either an opaque one-way hash of an app-issued account id, or a plain
// random value with no meaning outside Attribr's own systems. Rotation:
// call `reset()` from your app's data-deletion flow (GDPR-style) to clear
// the anonymous-mode Keychain value — a fresh token is generated on next
// use. Account-linked tokens aren't "rotated" by this type at all; they
// simply stop being derivable once the backend account itself is deleted.

import Foundation
import CryptoKit
#if canImport(Security)
import Security
#endif

public enum AppAccountTokenProvider {

    private static let keychainService = "com.mrvltechnologies.attribr.appAccountToken"
    private static let keychainAccount = "token"

    /// Returns the stable appAccountToken to pass to
    /// `Product.PurchaseOption.appAccountToken(_:)`.
    ///
    /// - Parameter backendUserId: the host app's own backend user/account id,
    ///   if it has one (e.g. `session.user.id` from Supabase auth). Pass
    ///   `nil` (the default) for anonymous/local-only apps.
    public static func token(backendUserId: String? = nil) -> UUID {
        if let backendUserId, !backendUserId.isEmpty {
            if let parsed = UUID(uuidString: backendUserId) { return parsed }
            return deterministicUUID(from: backendUserId)
        }
        if let existing = readKeychain(), let uuid = UUID(uuidString: existing) {
            return uuid
        }
        let fresh = UUID()
        writeKeychain(fresh.uuidString)
        return fresh
    }

    /// Clears the persisted anonymous-mode token. Call from your app's
    /// data-deletion flow, matching `InstallInstance.reset()`'s contract.
    /// Has no effect in account-linked mode — nothing is persisted there,
    /// the token is re-derived from `backendUserId` every call.
    public static func reset() {
        deleteKeychain()
    }

    // MARK: - Deterministic UUID from an arbitrary backend id

    /// SHA-256 of `string`, truncated to 16 bytes and formatted as a
    /// version-5-shaped UUID (RFC 4122 version/variant bits set). Same
    /// input always produces the same output; the input itself never
    /// appears in or is recoverable from the result.
    static func deterministicUUID(from string: String) -> UUID {
        let digest = SHA256.hash(data: Data(string.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let groups = [
            hex.prefix(8),
            hex.dropFirst(8).prefix(4),
            hex.dropFirst(12).prefix(4),
            hex.dropFirst(16).prefix(4),
            hex.dropFirst(20).prefix(12),
        ]
        // Force-unwrap is safe: 32 lowercase hex chars grouped 8-4-4-4-12 is
        // always a syntactically valid UUID string by construction.
        return UUID(uuidString: groups.joined(separator: "-"))!
    }

    // MARK: - Keychain (a single generic-password item scoped by service+account)

    private static func baseQuery() -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
        ]
    }

    static func readKeychain() -> String? {
        var query = baseQuery()
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func writeKeychain(_ value: String) {
        deleteKeychain()
        var query = baseQuery()
        query[kSecValueData] = Data(value.utf8)
        query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    static func deleteKeychain() {
        SecItemDelete(baseQuery() as CFDictionary)
    }
}

import StoreKit
import Foundation

/// Server-verified revenue reporting.
///
/// BUG_HUNT P0-K (2026-08-07): promoted from Revisr's app-local
/// implementation into the shared SDK so every app can use the same
/// safe path. `Attribr.trackRevenue()` (see `Attribr.swift`) accepts a
/// client-supplied amount/currency and is kept only for backward
/// compatibility with apps that have not yet migrated — see its own
/// doc comment. New integrations, and all apps migrating off
/// `trackRevenue()`, should call `RevenueDiscoveryReporter.report(...)`
/// instead.
///
/// Fires a best-effort, non-blocking "device saw this purchase" ping to
/// Attribr's `/api/v1/revenue-discovery` endpoint whenever StoreKit
/// reports a transaction. This is an early-witness signal for Attribr's
/// server-side verification pipeline — it is NOT a purchase-authority
/// path. Your app's own entitlement/subscription logic (StoreKit
/// `Transaction.currentEntitlements`, receipt validation, etc.) is
/// completely unaffected by this call succeeding, failing, or being
/// slow: nothing about your app's own state should ever depend on it.
///
/// Response contract: the server always answers with
/// `{"status":"pending_verification", ...}` — callers must never treat
/// that as proof of a real purchase. It is logged (DEBUG builds only)
/// and the SDK moves on.
///
/// Sent fields are limited to what Attribr's intake route accepts — no
/// price, currency, revenue amount, raw device identifier, or raw
/// appAccountToken leaves this function (appAccountToken and the SDK
/// install-instance ID are sent already-hashed, matching
/// `InstallInstance.hashHex()`'s "raw UUID never leaves the device"
/// contract). Revenue amount is deliberately never part of this
/// payload — that is the whole point of this being the safe successor
/// to `trackRevenue()`. Actual revenue is later established server-side
/// by verifying the transaction against Apple's own StoreKit Server API,
/// never trusted from any client submission.
///
/// Requires iOS 16 / macOS 13 — the platform floor StoreKit 2's
/// `Transaction.environment` needs. The SDK package itself targets a
/// lower floor (iOS 15 / macOS 12) for its other APIs, so this type is
/// separately availability-gated rather than raising the whole package's
/// minimum.
@available(iOS 16.0, macOS 13.0, *)
public enum RevenueDiscoveryReporter {

    /// Attribr dashboard host — distinct from the SDK's default Supabase
    /// Edge Functions base URL. This talks directly to the dashboard's
    /// REST route, which is where /api/v1/revenue-discovery lives.
    private static let endpoint = URL(string: "https://attribr.dev/api/v1/revenue-discovery")!

    // Matches the SDK's established pattern for a static, effectively-
    // immutable-after-first-use formatter (see Attribr._apiKey) — ISO8601DateFormatter
    // isn't Sendable, but this instance is never mutated after creation.
    nonisolated(unsafe) private static let iso8601 = ISO8601DateFormatter()

    /// Fire-and-forget — call this from your purchase success path and
    /// from your `Transaction.updates` listener. Never throws, never
    /// blocks the caller; failures are logged and simply dropped.
    public static func report(transaction: StoreKit.Transaction, appAccountToken: UUID? = nil) {
        Task.detached(priority: .utility) {
            await Self.send(transaction: transaction, appAccountToken: appAccountToken)
        }
    }

    private static func send(transaction: StoreKit.Transaction, appAccountToken: UUID?) async {
        guard let apiKey = Attribr._apiKey else { return }

        let environment: String
        switch transaction.environment {
        case .sandbox: environment = "sandbox"
        case .production: environment = "production"
        default: environment = "production"
        }

        var payload: [String: Any] = [
            "app_id": Bundle.main.bundleIdentifier ?? "unknown",
            "platform": "ios",
            "environment": environment,
            "source": "sdk_storekit",
            "product_id": transaction.productID,
            "transaction_id": String(transaction.id),
            "original_transaction_id": String(transaction.originalID),
            // Idempotent across retries and app relaunches — same
            // transaction always produces the same event id.
            "sdk_event_id": "storekit:\(transaction.id)",
            "purchase_date": iso8601.string(from: transaction.purchaseDate),
            "device_event_time": iso8601.string(from: Date()),
            "sdk_install_instance_id_hash": InstallInstance.hashHex(),
        ]
        if let token = appAccountToken {
            payload["appAccountToken"] = token.uuidString
        }
        if let expirationDate = transaction.expirationDate {
            payload["expiration_date"] = iso8601.string(from: expirationDate)
        }
        if let revocationDate = transaction.revocationDate {
            payload["revocation_date"] = iso8601.string(from: revocationDate)
        }

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Attribr-Key")
        request.httpBody = body
        request.timeoutInterval = 10

        #if DEBUG
        print("[RevenueDiscoveryReporter] attempt tx=\(transaction.id) product=\(transaction.productID) env=\(environment)")
        #endif

        // Small bounded retry on network failure only — never retries on a
        // clean HTTP error response (4xx/5xx), since sdk_event_id already
        // makes a resend safe but there is no reason to hammer a server
        // that just answered.
        for attempt in 0..<2 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse {
                    #if DEBUG
                    var trackingStatus = "unknown"
                    var dedupe = "unknown"
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        trackingStatus = (json["tracking_status"] as? String) ?? (json["status"] as? String) ?? "unknown"
                        dedupe = (json["duplicate"] as? Bool).map { $0 ? "duplicate" : "new" } ?? "unknown"
                    }
                    print("[RevenueDiscoveryReporter] tx=\(transaction.id) http=\(http.statusCode) tracking_status=\(trackingStatus) dedupe=\(dedupe)")
                    #endif
                }
                return
            } catch {
                if attempt == 0 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                #if DEBUG
                print("[RevenueDiscoveryReporter] tx=\(transaction.id) failed after retry, dropping (non-fatal): \(error.localizedDescription)")
                #endif
            }
        }
    }
}

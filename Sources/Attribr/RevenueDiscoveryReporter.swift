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
/// price, currency, revenue amount, or raw device identifier leaves this
/// function (the SDK install-instance ID is sent already-hashed, matching
/// `InstallInstance.hashHex()`'s "raw UUID never leaves the device"
/// contract). `appAccountToken`, when supplied, is the one deliberate
/// exception: it is sent as the plain UUID string, not hashed — Attribr
/// has to be able to match it against the same plain value Apple echoes
/// back on the S2S notification for this transaction (stored as a `uuid`
/// column server-side), which a one-way hash would make impossible. This
/// is not raw PII: it's already the opaque token design
/// (`AppAccountTokenProvider`) chose specifically to be safe to share with
/// both Apple and Attribr. Revenue amount is deliberately never part of this
/// payload — that is the whole point of this being the safe successor
/// to `trackRevenue()`. Actual revenue is later established server-side
/// by verifying the transaction against Apple's own StoreKit Server API,
/// never trusted from any client submission.
///
/// SDK-internal endpoint registry. Lives outside the availability-gated
/// reporter enum below so `Attribr.flushQueue()` (which supports the SDK's
/// full iOS 15 / macOS 12 floor) can reference the absolute URL when
/// replaying queued `.revenueDiscovery` events without an availability check.
internal enum AttribrEndpoints {
    /// GDPR deletion (relative to the Edge Functions base URL). The only endpoint that may be
    /// called without granted consent.
    static let deleteUserData = "attribr-delete-user-data"

    /// Attribr dashboard host — distinct from the SDK's default Supabase
    /// Edge Functions base URL. This is where /api/v1/revenue-discovery lives.
    static let revenueDiscovery = "https://attribr.dev/api/v1/revenue-discovery"

    /// Identity Foundation Phase 36 — /api/v1/identify lives on the same
    /// dashboard host, not the Supabase Edge Functions base URL.
    static let identify = "https://attribr.dev/api/v1/identify"
}

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
    private static let endpoint = URL(string: AttribrEndpoints.revenueDiscovery)!

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

    /// StoreKit-testing (`.xcode`) transactions are NOT production commercial data — they must
    /// never be labelled "production" (the previous `default:` arm did exactly that).
    internal static func environmentString(_ env: AppStore.Environment) -> String {
        switch env {
        case .production: return "production"
        case .sandbox, .xcode: return "sandbox"
        default: return "sandbox"   // unknown future environment: fail away from production
        }
    }

    /// Deterministic, idempotent event identity — the same transaction always yields the same id.
    internal static func sdkEventID(forTransactionID id: UInt64) -> String { "storekit:\(id)" }

    private static func send(transaction: StoreKit.Transaction, appAccountToken: UUID?) async {
        guard let apiKey = Attribr._apiKey else { return }

        let environment = environmentString(transaction.environment)

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
            "sdk_event_id": sdkEventID(forTransactionID: transaction.id),
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

        // Consent gate — checking `_apiKey` alone (as this reporter originally
        // did) bypassed the SDK's GDPR gate: every other network path in
        // `Attribr` refuses to send until `setConsent(.granted)`.
        //   • `.unknown`  → the user simply hasn't been asked yet. Don't drop
        //     the witness signal: park the payload on the SDK's durable queue,
        //     which `Attribr.setConsent(.granted)` flushes. The data stays
        //     on-device until consent exists.
        //   • `.revoked` (or SDK not initialised) → the user explicitly opted
        //     out; retaining the payload for a hypothetical future opt-in
        //     would contradict "SDK stops all collection". Drop it.
        switch await Attribr.consentState {
        case .granted:
            break
        case .unknown:
            await Attribr.enqueueRevenueDiscovery(body, attempts: 0)
            #if DEBUG
            print("[RevenueDiscoveryReporter] tx=\(transaction.id) queued — consent not yet granted")
            #endif
            return
        case .revoked, nil:
            #if DEBUG
            print("[RevenueDiscoveryReporter] tx=\(transaction.id) dropped — consent revoked or SDK not initialised")
            #endif
            return
        }

        await dispatch(body: body, apiKey: apiKey, label: "tx=\(transaction.id) product=\(transaction.productID) env=\(environment)")
    }

    // MARK: - Direct dispatch (consent enforced per attempt)

    /// Session used for the direct intake request. Production: `.shared`. Replaceable only by tests.
    nonisolated(unsafe) internal static var urlSession: URLSession = .shared
    /// Back-off before the single transport retry. Replaceable only by tests.
    nonisolated(unsafe) internal static var retryDelayNanoseconds: UInt64 = 2_000_000_000

    /// Sends one revenue-discovery payload directly to the dashboard intake.
    ///
    /// Consent is re-checked immediately before EVERY attempt, including the retry that follows the
    /// back-off sleep (attribr-ios#1 / PR #2 review): a withdrawal while sleeping, or any state other than
    /// `.granted` at dispatch, sends nothing and queues nothing. Failure re-queueing additionally goes through
    /// `Attribr.enqueueRevenueDiscovery`, which refuses to queue unless consent still allows it.
    /// A request already on the wire when consent is withdrawn cannot be recalled.
    internal static func dispatch(body: Data, apiKey: String, label: String) async {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Attribr-Key")
        request.httpBody = body
        request.timeoutInterval = 10

        // Small bounded retry on transport failure only; transient outcomes (transport failure, 429, 5xx) are
        // parked on the SDK's durable queue. `sdk_event_id` is deterministic per transaction, so a resend is
        // deduplicated server-side. A non-429 4xx stays terminal.
        for attempt in 0..<2 {
            guard await Attribr.isConsentGranted else {
                #if DEBUG
                print("[RevenueDiscoveryReporter] \(label) not sent — consent not granted at dispatch")
                #endif
                return
            }
            do {
                let (_, response) = try await urlSession.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 429 || http.statusCode >= 500 {
                    await Attribr.enqueueRevenueDiscovery(body)
                }
                return
            } catch {
                if attempt == 0 {
                    try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
                    continue
                }
                await Attribr.enqueueRevenueDiscovery(body)
            }
        }
    }
}

import StoreKit
import Foundation

/// Lifecycle coverage for `RevenueDiscoveryReporter` (Commercial Truth Phase 2A).
///
/// One call at app start makes renewals, off-app purchases (Family Sharing / promo / Ask-to-Buy
/// approvals), restores and pre-reporter subscriptions produce discovery evidence, idempotently:
///
///   • `Transaction.updates`             → every renewal / refund / revocation / out-of-app purchase
///   • `Transaction.currentEntitlements` → once per launch (24h throttle), covers subscribers who
///                                         purchased before the reporter shipped, plus restores
///
/// ```swift
/// Attribr.initialize(apiKey: …)
/// RevenueDiscoveryLifecycle.start()   // iOS 16+ / macOS 13+
/// ```
///
/// Contract
///   • Evidence only. The server (Apple S2S / ASC reconciliation) remains the revenue authority;
///     nothing reported here is promoted to paid state.
///   • Only StoreKit-**verified** transactions are reported; unverified results are ignored.
///   • `sdk_event_id = "storekit:<transaction.id>"` — every re-report is a server-side no-op.
///   • Bounded: ≤ 50 transactions per launch reconcile, ≤ 3 reports per transaction id (on-device).
///   • Uses the existing install-instance hash and the existing consent gate (unknown → parked on the
///     durable queue, revoked / uninitialised → dropped). Nothing is sent before consent.
///   • `appAccountToken` is passed through only when StoreKit already carries one on the transaction
///     (or the host supplies one). It is never created or repurposed here.
///   • Purchase success paths should keep calling `RevenueDiscoveryReporter.report(transaction:)`;
///     the cap and the deterministic event id make the extra lifecycle report harmless.
@available(iOS 16.0, macOS 13.0, *)
public enum RevenueDiscoveryLifecycle {

    /// Pure policy, unit-tested without StoreKit.
    public struct Policy: Sendable {
        public var reconcileInterval: TimeInterval = 24 * 3600
        public var maxReportsPerTransaction = 3
        public var maxReconcilePerLaunch = 50
        public init() {}
    }

    /// Which transaction ids to send. `reported` = times each id was already reported on this device.
    /// `lastReconcile` only throttles the launch-reconcile path; the `Transaction.updates` path
    /// (`isReconcile: false`) is never throttled, only capped per transaction.
    public static func plan(candidates: [UInt64], reported: [UInt64: Int], lastReconcile: Date?,
                            now: Date = Date(), policy: Policy = Policy(), isReconcile: Bool) -> [UInt64] {
        if isReconcile, let last = lastReconcile, now.timeIntervalSince(last) < policy.reconcileInterval { return [] }
        var out: [UInt64] = []
        var seen = Set<UInt64>()
        for id in candidates where (reported[id] ?? 0) < policy.maxReportsPerTransaction && seen.insert(id).inserted {
            out.append(id)
            if isReconcile && out.count >= policy.maxReconcilePerLaunch { break }
        }
        return out
    }

    // MARK: - On-device ledger (bounded re-report accounting)

    private static let countsKey = "attribr.rdl.v1.counts"
    private static let lastKey = "attribr.rdl.v1.last"
    private static let lock = NSLock()
    /// Internal for tests (swap in an isolated suite).
    nonisolated(unsafe) internal static var defaults: UserDefaults = .standard

    private static func counts() -> [UInt64: Int] {
        let raw = defaults.dictionary(forKey: countsKey) as? [String: Int] ?? [:]
        return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in UInt64(k).map { ($0, v) } })
    }
    private static func note(_ id: UInt64) {
        var raw = defaults.dictionary(forKey: countsKey) as? [String: Int] ?? [:]
        raw[String(id), default: 0] += 1
        defaults.set(raw, forKey: countsKey)
    }

    // MARK: - Processing (internal seams used by tests and by `start`)

    internal typealias Report = @Sendable (StoreKit.Transaction, UUID?) -> Void
    internal typealias TokenProvider = @Sendable (StoreKit.Transaction) -> UUID?

    /// One `Transaction.updates` result. Returns true if a report was issued.
    @discardableResult
    internal static func process(update result: VerificationResult<StoreKit.Transaction>,
                                 token: TokenProvider, report: Report) -> Bool {
        guard case .verified(let tx) = result else { return false }
        lock.lock(); defer { lock.unlock() }
        guard plan(candidates: [tx.id], reported: counts(), lastReconcile: nil, isReconcile: false) == [tx.id] else { return false }
        note(tx.id)
        report(tx, token(tx))
        return true
    }

    /// One launch reconcile over a snapshot of `currentEntitlements`. Returns ids reported.
    @discardableResult
    internal static func process(entitlements results: [VerificationResult<StoreKit.Transaction>],
                                 now: Date = Date(), policy: Policy = Policy(),
                                 token: TokenProvider, report: Report) -> [UInt64] {
        lock.lock(); defer { lock.unlock() }
        let txs: [StoreKit.Transaction] = results.compactMap { if case .verified(let t) = $0 { return t } else { return nil } }
        let last = defaults.object(forKey: lastKey) as? Date
        if let last, now.timeIntervalSince(last) < policy.reconcileInterval { return [] }   // throttled: clock not moved
        let ids = plan(candidates: txs.map(\.id), reported: counts(), lastReconcile: nil, now: now, policy: policy, isReconcile: true)
        for tx in txs where ids.contains(tx.id) {
            note(tx.id)
            report(tx, token(tx))
        }
        defaults.set(now, forKey: lastKey)
        return ids
    }

    internal static func resetForTesting() {
        started = false
        listener?.cancel(); listener = nil
        defaults.removeObject(forKey: countsKey)
        defaults.removeObject(forKey: lastKey)
    }

    // MARK: - Public entry point

    nonisolated(unsafe) private static var started = false
    nonisolated(unsafe) private static var listener: Task<Void, Never>?

    /// Call once, after `Attribr.initialize`. Further calls are no-ops.
    /// - Parameters:
    ///   - reconcileOnLaunch: also sweep `Transaction.currentEntitlements` (throttled to once / 24h).
    ///   - appAccountToken: optional host-supplied token source. Defaults to whatever the transaction
    ///     already carries; the SDK never mints one.
    public static func start(reconcileOnLaunch: Bool = true,
                             appAccountToken: (@Sendable (StoreKit.Transaction) -> UUID?)? = nil) {
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        lock.unlock()

        let token: TokenProvider = appAccountToken ?? { $0.appAccountToken }
        let report: Report = { tx, tok in RevenueDiscoveryReporter.report(transaction: tx, appAccountToken: tok) }

        listener = Task.detached(priority: .utility) {
            for await result in Transaction.updates {
                process(update: result, token: token, report: report)
            }
        }
        guard reconcileOnLaunch else { return }
        Task.detached(priority: .utility) {
            var results: [VerificationResult<StoreKit.Transaction>] = []
            for await r in Transaction.currentEntitlements { results.append(r) }
            process(entitlements: results, token: token, report: report)
        }
    }
}

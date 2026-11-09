import Foundation

public enum RatingsEngineError: Error, Equatable {
    case invalidPolicy
    case sessionNotStarted
    case legacyStateAlreadyInitialised
}

public enum RatingsRequestResult: Equatable {
    case suppressed(RatingsReason)
    case shadowOnly
    case activeNotAuthorised
    case annualAttemptLimit
    case persistenceUnavailable
    /// The OS request API was invoked; it may show nothing.
    case nativeRequestInvoked
    /// The host's native request closure could not invoke the API.
    /// Cooldown is intentionally retained after this uncertain outcome.
    case bridgeUnavailableAfterReservation
}

/// Process-local reservation ledger, keyed to the backing state namespace.
/// This is not an arbitrary global enabled flag: it records a successful
/// persisted native-request reservation for ONE namespace in THIS process.
/// New processes start with an empty ledger; persisted cooldown/history
/// remains authoritative across processes. All accesses are @MainActor.
@MainActor
private enum RatingsLaunchReservations {
    /// A pending reservation prevents synchronous reentrancy from a custom
    /// state store's save callback; only a successful save can commit it.
    private enum Status { case pending, committed }
    private static var reservations: [String: Status] = [:]

    static func begin(_ namespace: String) -> Bool {
        guard reservations[namespace] == nil else { return false }
        reservations[namespace] = .pending
        return true
    }

    static func commit(_ namespace: String) {
        if reservations[namespace] == .pending {
            reservations[namespace] = .committed
        }
    }

    static func abandonFailedWrite(_ namespace: String) {
        if reservations[namespace] == .pending {
            reservations.removeValue(forKey: namespace)
        }
    }

    #if DEBUG
    static func resetForSimulatedProcessRestart(_ namespace: String) {
        reservations.removeValue(forKey: namespace)
    }
    #endif
}

/// Safe, product-owned local orchestration for ratings. No timers, StoreKit,
/// Attribr transport or network side effects exist in the engine.
///
/// A host MUST call from a natural post-success resting point, after it has
/// separately checked its active modal/editing state, and re-check the screen
/// immediately before asking the engine to invoke the native bridge.
///
/// This MainActor type serialises concurrent callbacks in one process. It is
/// not an inter-process lock. The future host app owns the only native request
/// bridge; in Cleanr the existing ReviewPrompter remains sole owner in T2.
@MainActor
public final class RatingsEngine {
    private let store: any RatingsStateStore
    private let coordinationKey: String
    public let policy: RatingsPolicy
    private let activeRequestsAuthorised: Bool
    private var saved: RatingsStoreSnapshot
    private var startedSession = false
    private var confirmedValueThisSession = false
    private var canImportLegacy: Bool

    /// Active requests require BOTH .active policy AND a separately approved
    /// app integration flag. Defaults are always non-requesting.
    public init(
        policy: RatingsPolicy = .cleanrLegacyParity,
        store: any RatingsStateStore,
        activeRequestsAuthorised: Bool = false
    ) throws {
        guard policy.isValid else { throw RatingsEngineError.invalidPolicy }
        self.policy = policy
        self.store = store
        self.coordinationKey = store.ratingsCoordinationKey
        self.activeRequestsAuthorised = activeRequestsAuthorised
        let existing = try store.load()
        self.saved = existing ?? RatingsStoreSnapshot(
            state: RatingsLocalState(sessionCount: 0)
        )
        self.canImportLegacy = existing == nil
        // Per-launch request and value gates are intentionally never restored.
        self.saved.state.attemptedThisLaunch = false
    }

    /// Reflect successful writes from other engine instances without
    /// throwing for this diagnostics-only accessor. Decisions and mutations
    /// NEVER use the stale fallback on storage failure.
    public var state: RatingsLocalState {
        (try? currentSnapshot().state) ?? saved.state
    }

    #if DEBUG
    /// Test-only simulation of a process restart; NEVER used by a host app.
    /// A genuine app relaunch naturally resets this process-local registry.
    internal static func resetProcessReservationForTesting(store: any RatingsStateStore) {
        RatingsLaunchReservations.resetForSimulatedProcessRestart(store.ratingsCoordinationKey)
    }
    #endif

    /// Reload before EVERY state mutation. The MainActor synchronously
    /// serialises the read/modify/write and the reservation ledger update
    /// within this app process, including across distinct store handles.
    /// An absent snapshot after our first successful write is corruption,
    /// not permission to reset wins or a prior cooldown.
    private func currentSnapshot() throws -> RatingsStoreSnapshot {
        guard var current = try store.load() else {
            guard canImportLegacy && !startedSession else {
                throw RatingsStorageError.corruptSnapshot
            }
            return saved
        }
        // The current process's in-memory one-per-launch flag is not encoded
        // into UserDefaults; keep our local flag when reading newer storage.
        current.state.attemptedThisLaunch =
            current.state.attemptedThisLaunch || saved.state.attemptedThisLaunch
        return current
    }

    private func decision(
        for current: RatingsStoreSnapshot,
        opportunity: RatingsOpportunity
    ) -> RatingsDecision {
        let safeOpportunity = RatingsOpportunity(
            now: opportunity.now,
            isForeground: opportunity.isForeground,
            isOnboarding: opportunity.isOnboarding,
            isPaywallPresented: opportunity.isPaywallPresented,
            isEditing: opportunity.isEditing,
            nativeBridgeAvailable: opportunity.nativeBridgeAvailable,
            hasConfirmedValueMoment:
                opportunity.hasConfirmedValueMoment && confirmedValueThisSession
        )
        return RatingsEligibility.evaluate(
            state: current.state, policy: policy, opportunity: safeOpportunity
        )
    }

    /// The first call in this process starts one session. Calls from repeated
    /// scene-active notifications do not inflate sessionCount.
    @discardableResult
    public func beginSession(now: Date = Date()) throws -> Bool {
        guard !startedSession else { return false }
        var next = try currentSnapshot()
        if next.state.sessionCount < Int.max { next.state.sessionCount += 1 }
        if next.state.firstSeenAt == nil { next.state.firstSeenAt = now }
        try store.save(next)
        saved = next
        canImportLegacy = false
        startedSession = true
        return true
    }

    /// Used once during an approved migration from an existing product's
    /// prompter. Never overwrite an already initialised ratings snapshot.
    /// Import must be completed BEFORE beginSession and before the first
    /// active OS request. Persist the old last-attempt date and win count;
    /// never reset the customer's previous cooldown on an SDK upgrade.
    @discardableResult
    public func importLegacyStateIfUninitialised(
        confirmedWins: Int,
        lastRequestAttemptAt: Date?,
        now: Date = Date()
    ) throws -> Bool {
        guard canImportLegacy, !startedSession, saved.state.sessionCount == 0,
              saved.state.confirmedWins == 0,
              saved.state.lastRequestAttemptAt == nil,
              saved.requestAttemptHistory.isEmpty else {
            return false
        }
        guard confirmedWins >= 0 else { throw RatingsEngineError.legacyStateAlreadyInitialised }
        // Another preconstructed engine may already have imported or
        // initialised this namespace. NEVER replace its stored snapshot.
        if let existing = try store.load() {
            saved = existing
            canImportLegacy = false
            return false
        }
        var next = saved
        next.state.confirmedWins = confirmedWins
        next.state.firstSeenAt = now
        next.state.lastRequestAttemptAt = lastRequestAttemptAt
        next.requestAttemptHistory = lastRequestAttemptAt.map { [$0] } ?? []
        try store.save(next)
        saved = next
        canImportLegacy = false
        return true
    }

    /// The host supplies the SAME receipt ID for duplicate callbacks from a
    /// single real completed operation. No photo hash/file name is accepted.
    @discardableResult
    public func recordConfirmedValueMoment(
        _ moment: RatingsValueMoment
    ) throws -> Bool {
        guard startedSession else { throw RatingsEngineError.sessionNotStarted }
        var next = try currentSnapshot()
        guard RatingsEligibility.recordConfirmedValueMoment(moment, into: &next.state) else {
            saved = next // adopt the latest authoritative receipt/win state
            return false
        }
        // Persist first. Failed storage must never advance in-memory state.
        try store.save(next)
        saved = next
        canImportLegacy = false
        confirmedValueThisSession = true
        return true
    }

    public func noteFailure(at time: Date = Date()) throws {
        try mutate { $0.state.lastFailureAt = time }
    }

    public func noteCrashEvidence(at time: Date = Date()) throws {
        try mutate { $0.state.lastCrashAt = time }
    }

    private func mutate(_ edit: (inout RatingsStoreSnapshot) -> Void) throws {
        var next = try currentSnapshot()
        edit(&next)
        try store.save(next)
        saved = next
        canImportLegacy = false
    }

    /// Returns a pure decision; never calls StoreKit. Use this for shadow
    /// comparisons and suppressed-reason diagnostics without telemetry.
    public func evaluate(_ opportunity: RatingsOpportunity) -> RatingsDecision {
        guard let current = try? currentSnapshot() else {
            // Keep the existing non-throwing API. A state read error must
            // never report eligibility; requestIfEligible returns the more
            // precise persistenceUnavailable result for the same failure.
            return RatingsDecision(reason: .invalidPolicy,
                                   configVersion: policy.version, mode: policy.mode)
        }
        return decision(for: current, opportunity: opportunity)
    }

    /// A safe, *synchronous* native handoff. In shadow mode the closure is
    /// NEVER executed. In active mode, local request state is saved BEFORE
    /// invoking it, even if the OS silently ignores its own review request.
    ///
    /// This is intentionally NOT called from an export button or on app launch.
    /// The host schedules its own cancellable post-success delay, refreshes
    /// the foreground/modal/editing context and then invokes this method.
    public func requestIfEligible(
        _ opportunity: RatingsOpportunity,
        nativeRequest: @MainActor () -> Bool
    ) -> RatingsRequestResult {
        guard startedSession else { return .suppressed(.unconfirmedValueMoment) }
        let current: RatingsStoreSnapshot
        do {
            current = try currentSnapshot()
        } catch {
            return .persistenceUnavailable
        }
        let eligibility = decision(for: current, opportunity: opportunity)
        guard eligibility.isEligible else { return .suppressed(eligibility.reason) }
        guard policy.mode == .active else { return .shadowOnly }
        guard activeRequestsAuthorised else { return .activeNotAuthorised }
        let now = opportunity.now
        // Never let a future-dated attempt bypass the annual throttle.
        if current.requestAttemptHistory.contains(where: { $0 > now }) {
            return .suppressed(.clockRollback)
        }
        let lookback = now.addingTimeInterval(-365 * 86_400)
        let recent = current.requestAttemptHistory.filter { $0 > lookback }
        guard recent.count < 3 else { return .annualAttemptLimit }

        var next = current
        RatingsEligibility.markNativeRequestAttempt(in: &next.state, at: now)
        next.requestAttemptHistory = Array((recent + [now]).sorted().suffix(8))
        // Reserve the namespace BEFORE calling a potentially reentrant store.
        // No StoreKit call occurs unless the reservation is persisted.
        guard RatingsLaunchReservations.begin(coordinationKey) else {
            return .suppressed(.alreadyAttemptedThisLaunch)
        }
        do {
            try store.save(next)
        } catch {
            RatingsLaunchReservations.abandonFailedWrite(coordinationKey)
            return .persistenceUnavailable
        }
        saved = next
        canImportLegacy = false
        RatingsLaunchReservations.commit(coordinationKey)
        // No work between the saved guard and native call may suspend.
        let invoked = nativeRequest()
        return invoked ? .nativeRequestInvoked : .bridgeUnavailableAfterReservation
    }
}

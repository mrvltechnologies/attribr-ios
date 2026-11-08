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
        self.activeRequestsAuthorised = activeRequestsAuthorised
        let existing = try store.load()
        self.saved = existing ?? RatingsStoreSnapshot(
            state: RatingsLocalState(sessionCount: 0)
        )
        self.canImportLegacy = existing == nil
        // Per-launch request and value gates are intentionally never restored.
        self.saved.state.attemptedThisLaunch = false
    }

    public var state: RatingsLocalState { saved.state }

    /// The first call in this process starts one session. Calls from repeated
    /// scene-active notifications do not inflate sessionCount.
    @discardableResult
    public func beginSession(now: Date = Date()) throws -> Bool {
        guard !startedSession else { return false }
        var next = saved
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
        var next = saved
        guard RatingsEligibility.recordConfirmedValueMoment(moment, into: &next.state) else {
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
        var next = saved
        edit(&next)
        try store.save(next)
        saved = next
        canImportLegacy = false
    }

    /// Returns a pure decision; never calls StoreKit. Use this for shadow
    /// comparisons and suppressed-reason diagnostics without telemetry.
    public func evaluate(_ opportunity: RatingsOpportunity) -> RatingsDecision {
        let safeOpportunity = RatingsOpportunity(
            now: opportunity.now,
            isForeground: opportunity.isForeground,
            isOnboarding: opportunity.isOnboarding,
            isPaywallPresented: opportunity.isPaywallPresented,
            isEditing: opportunity.isEditing,
            nativeBridgeAvailable: opportunity.nativeBridgeAvailable,
            hasConfirmedValueMoment: opportunity.hasConfirmedValueMoment && confirmedValueThisSession
        )
        return RatingsEligibility.evaluate(
            state: saved.state, policy: policy, opportunity: safeOpportunity
        )
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
        let decision = evaluate(opportunity)
        guard decision.isEligible else { return .suppressed(decision.reason) }
        guard policy.mode == .active else { return .shadowOnly }
        guard activeRequestsAuthorised else { return .activeNotAuthorised }

        let now = opportunity.now
        // Never let a future-dated attempt bypass the annual throttle.
        if saved.requestAttemptHistory.contains(where: { $0 > now }) {
            return .suppressed(.clockRollback)
        }
        let lookback = now.addingTimeInterval(-365 * 86_400)
        let recent = saved.requestAttemptHistory.filter { $0 > lookback }
        guard recent.count < 3 else { return .annualAttemptLimit }

        var next = saved
        RatingsEligibility.markNativeRequestAttempt(in: &next.state, at: now)
        next.requestAttemptHistory = Array((recent + [now]).sorted().suffix(8))
        do {
            try store.save(next)
        } catch {
            return .persistenceUnavailable
        }
        saved = next
        canImportLegacy = false
        // No work between the saved guard and native call may suspend.
        let invoked = nativeRequest()
        return invoked ? .nativeRequestInvoked : .bridgeUnavailableAfterReservation
    }
}

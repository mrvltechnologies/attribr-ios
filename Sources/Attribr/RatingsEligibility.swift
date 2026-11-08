import Foundation

/// Portable, local-only policy state for native app-rating requests.
/// This module never contacts Attribr, StoreKit or a product's photo data.
public enum RatingsMode: String, Codable, Sendable {
    case disabled
    case shadow
    case active
}

public enum RatingsStrength: String, Codable, Sendable {
    case none
    case standard
    case strong
}

public enum RatingsReason: String, Codable, Sendable {
    case eligible
    case disabled
    case invalidPolicy
    case unconfirmedValueMoment
    case onboarding
    case paywall
    case editing
    case background
    case nativeBridgeUnavailable
    case insufficientWins
    case insufficientSessions
    case insufficientAppAge
    case recentFailure
    case recentCrash
    case alreadyAttemptedThisLaunch
    case clockRollback
    case cooldown
}

/// Validatable, versioned local policy. Never parse executable remote rules.
/// cleanrLegacyParity copies Cleanr's existing numeric thresholds but does
/// not modify its legacy ReviewPrompter, which remains the only prompt owner.
public struct RatingsPolicy: Sendable, Equatable {
    public let version: String
    public let mode: RatingsMode
    public let minimumConfirmedWins: Int
    public let minimumSessions: Int
    public let minimumAppAgeDays: Int
    public let cooldownDays: Int
    public let failureSuppressionSeconds: TimeInterval
    public let crashSuppressionSeconds: TimeInterval

    public init(
        version: String,
        mode: RatingsMode,
        minimumConfirmedWins: Int,
        minimumSessions: Int = 1,
        minimumAppAgeDays: Int = 0,
        cooldownDays: Int,
        failureSuppressionSeconds: TimeInterval = 0,
        crashSuppressionSeconds: TimeInterval = 0
    ) {
        self.version = version
        self.mode = mode
        self.minimumConfirmedWins = minimumConfirmedWins
        self.minimumSessions = minimumSessions
        self.minimumAppAgeDays = minimumAppAgeDays
        self.cooldownDays = cooldownDays
        self.failureSuppressionSeconds = failureSuppressionSeconds
        self.crashSuppressionSeconds = crashSuppressionSeconds
    }

    /// A safe SHADOW comparison policy, not permission to request a review.
    /// The shipped prompter continues to enforce its own 3 wins / 90 days.
    public static let cleanrLegacyParity = RatingsPolicy(
        version: "cleanr-legacy-v1",
        mode: .shadow,
        minimumConfirmedWins: 3,
        minimumSessions: 1,
        minimumAppAgeDays: 0,
        cooldownDays: 90
    )

    public var isValid: Bool {
        !version.isEmpty && version.count <= 64
            && version.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 || $0 == 46 }
            && (1...1_000).contains(minimumConfirmedWins)
            && (1...10_000).contains(minimumSessions)
            && (0...3_650).contains(minimumAppAgeDays)
            && (0...3_650).contains(cooldownDays)
            && failureSuppressionSeconds.isFinite && (0...2_592_000).contains(failureSuppressionSeconds)
            && crashSuppressionSeconds.isFinite && (0...2_592_000).contains(crashSuppressionSeconds)
    }
}

/// Product-supplied confirmed outcome. A UUID is an ephemeral local operation
/// receipt, NOT a user ID, file name, photo hash or cross-product identifier.
public struct RatingsValueMoment: Sendable, Equatable {
    public let receiptID: UUID
    public let strength: RatingsStrength
    public let isConfirmed: Bool

    public init(receiptID: UUID, strength: RatingsStrength, isConfirmed: Bool) {
        self.receiptID = receiptID
        self.strength = strength
        self.isConfirmed = isConfirmed
    }
}

/// Domain state only. Persistence is owned by a future product adapter;
/// keeping it pure makes all decisions reproducible and testable offline.
public struct RatingsLocalState: Sendable, Equatable {
    public var confirmedWins: Int
    public var sessionCount: Int
    public var firstSeenAt: Date?
    public var lastRequestAttemptAt: Date?
    public var attemptedThisLaunch: Bool
    public var lastFailureAt: Date?
    public var lastCrashAt: Date?
    /// Bounded local operation receipts. No content or stable person IDs.
    public var recentReceiptIDs: [UUID]

    public init(
        confirmedWins: Int = 0,
        sessionCount: Int = 1,
        firstSeenAt: Date? = nil,
        lastRequestAttemptAt: Date? = nil,
        attemptedThisLaunch: Bool = false,
        lastFailureAt: Date? = nil,
        lastCrashAt: Date? = nil,
        recentReceiptIDs: [UUID] = []
    ) {
        self.confirmedWins = confirmedWins
        self.sessionCount = sessionCount
        self.firstSeenAt = firstSeenAt
        self.lastRequestAttemptAt = lastRequestAttemptAt
        self.attemptedThisLaunch = attemptedThisLaunch
        self.lastFailureAt = lastFailureAt
        self.lastCrashAt = lastCrashAt
        self.recentReceiptIDs = Array(recentReceiptIDs.suffix(64))
    }
}

/// The owning product tells the engine if its current screen is safe.
/// The engine never guesses from user sentiment or star predictions.
public struct RatingsOpportunity: Sendable {
    public let now: Date
    public let isForeground: Bool
    public let isOnboarding: Bool
    public let isPaywallPresented: Bool
    public let isEditing: Bool
    public let nativeBridgeAvailable: Bool
    public let hasConfirmedValueMoment: Bool

    public init(
        now: Date,
        isForeground: Bool,
        isOnboarding: Bool = false,
        isPaywallPresented: Bool = false,
        isEditing: Bool = false,
        nativeBridgeAvailable: Bool = true,
        hasConfirmedValueMoment: Bool
    ) {
        self.now = now
        self.isForeground = isForeground
        self.isOnboarding = isOnboarding
        self.isPaywallPresented = isPaywallPresented
        self.isEditing = isEditing
        self.nativeBridgeAvailable = nativeBridgeAvailable
        self.hasConfirmedValueMoment = hasConfirmedValueMoment
    }
}

public struct RatingsDecision: Sendable, Equatable {
    public let reason: RatingsReason
    public let configVersion: String
    public let mode: RatingsMode
    /// Eligible under local safety checks; may be true in SHADOW mode.
    public var isEligible: Bool { reason == .eligible }
    /// Only ACTIVE policy is allowed to request a native prompt.
    /// Even then, the product adapter must re-check the UI just before call.
    public var mayRequestNativeReview: Bool { isEligible && mode == .active }
}

public enum RatingsEligibility {
    /// Bounded, nonblocking, pure dedupe; never stores media or personal data.
    @discardableResult
    public static func recordConfirmedValueMoment(
        _ moment: RatingsValueMoment, into state: inout RatingsLocalState
    ) -> Bool {
        guard moment.isConfirmed && moment.strength != .none else { return false }
        guard !state.recentReceiptIDs.contains(moment.receiptID) else { return false }
        state.recentReceiptIDs.append(moment.receiptID)
        if state.recentReceiptIDs.count > 64 {
            state.recentReceiptIDs.removeFirst(state.recentReceiptIDs.count - 64)
        }
        if state.confirmedWins < Int.max { state.confirmedWins += 1 }
        return true
    }

    /// Called immediately before invoking the native adapter, after the final
    /// safety check. Persist this state BEFORE the OS call.
    public static func markNativeRequestAttempt(in state: inout RatingsLocalState, at now: Date) {
        state.lastRequestAttemptAt = now
        state.attemptedThisLaunch = true
    }

    public static func resetLaunchAttempt(in state: inout RatingsLocalState) {
        state.attemptedThisLaunch = false
    }

    public static func evaluate(
        state: RatingsLocalState,
        policy: RatingsPolicy,
        opportunity: RatingsOpportunity,
        calendar: Calendar = .current
    ) -> RatingsDecision {
        func decision(_ reason: RatingsReason) -> RatingsDecision {
            RatingsDecision(reason: reason, configVersion: policy.version, mode: policy.mode)
        }
        guard policy.isValid else { return decision(.invalidPolicy) }
        guard policy.mode != .disabled else { return decision(.disabled) }
        guard opportunity.hasConfirmedValueMoment else { return decision(.unconfirmedValueMoment) }
        guard !opportunity.isOnboarding else { return decision(.onboarding) }
        guard !opportunity.isPaywallPresented else { return decision(.paywall) }
        guard !opportunity.isEditing else { return decision(.editing) }
        guard opportunity.isForeground else { return decision(.background) }
        guard opportunity.nativeBridgeAvailable else { return decision(.nativeBridgeUnavailable) }
        guard state.confirmedWins >= policy.minimumConfirmedWins else { return decision(.insufficientWins) }
        guard state.sessionCount >= policy.minimumSessions else { return decision(.insufficientSessions) }
        if policy.minimumAppAgeDays > 0 {
            guard let first = state.firstSeenAt, first <= opportunity.now else {
                return decision(.insufficientAppAge)
            }
            let days = calendar.dateComponents([.day], from: first, to: opportunity.now).day ?? 0
            guard days >= policy.minimumAppAgeDays else { return decision(.insufficientAppAge) }
        }
        if policy.failureSuppressionSeconds > 0, let lastFailureAt = state.lastFailureAt {
            let elapsed = opportunity.now.timeIntervalSince(lastFailureAt)
            if elapsed < 0 || elapsed < policy.failureSuppressionSeconds { return decision(.recentFailure) }
        }
        if policy.crashSuppressionSeconds > 0, let lastCrashAt = state.lastCrashAt {
            let elapsed = opportunity.now.timeIntervalSince(lastCrashAt)
            if elapsed < 0 || elapsed < policy.crashSuppressionSeconds { return decision(.recentCrash) }
        }
        guard !state.attemptedThisLaunch else { return decision(.alreadyAttemptedThisLaunch) }
        if let last = state.lastRequestAttemptAt {
            guard last <= opportunity.now else { return decision(.clockRollback) }
            let days = calendar.dateComponents([.day], from: last, to: opportunity.now).day ?? 0
            guard days >= policy.cooldownDays else { return decision(.cooldown) }
        }
        return decision(.eligible)
    }
}

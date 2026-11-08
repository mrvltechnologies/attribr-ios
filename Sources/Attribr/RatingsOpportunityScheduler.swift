import Foundation

/// Schedules a review opportunity away from the Save tap and cancels it
/// when the host transitions to a modal, paywall, background or active edit.
/// Host MUST call cancel() for those transitions and provide fresh UI state
/// through currentOpportunity for a final check at invocation time.
///
/// This scheduler cannot bypass RatingsEngine's explicit active authorisation.
/// It does not create any native bridge, network call, or hidden timer at app
/// startup. The host controls its lifetime and must retain it as needed.
@MainActor
public final class RatingsOpportunityScheduler {
    private var pending: Task<Void, Never>?

    public init() {}

    public func schedule(
        engine: RatingsEngine,
        delayNanoseconds: UInt64 = 750_000_000,
        currentOpportunity: @escaping @MainActor () -> RatingsOpportunity,
        nativeRequest: @escaping @MainActor () -> Bool,
        onOutcome: (@MainActor (RatingsRequestResult) -> Void)? = nil
    ) {
        cancel()
        // Even a misconfigured host cannot synchronously request a review
        // in the same event loop turn as the Save action.
        let boundedDelay = max(700_000_000, min(delayNanoseconds, 5_000_000_000))
        pending = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: boundedDelay)
            } catch {
                return
            }
            guard self != nil, !Task.isCancelled else { return }
            let outcome = engine.requestIfEligible(
                currentOpportunity(), nativeRequest: nativeRequest
            )
            onOutcome?(outcome)
        }
    }

    public func cancel() {
        pending?.cancel()
        pending = nil
    }
}

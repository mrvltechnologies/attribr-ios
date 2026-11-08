import Foundation

/// Explicit opt-in route from the Ratings event contract to Attribr's
/// existing SDK custom-event pipeline. No new queue, tracking identity,
/// server endpoint or automatic event emission is introduced.
///
/// The owning product MUST confirm privacy disclosure and permission before
/// calling this API. Attribr.trackEvent independently enforces SDK consent.
/// A true return value means submitted to the local SDK API, not delivered.
@MainActor
public enum RatingsAnalyticsForwarder {
    @discardableResult
    public static func submitIfApproved(
        _ event: RatingsTelemetryEvent,
        productDisclosureApproved: Bool,
        analyticsConsentApproved: Bool
    ) -> Bool {
        guard productDisclosureApproved, analyticsConsentApproved,
              RatingsTelemetryContract.isApprovedShape(event) else { return false }
        Attribr.trackEvent(name: event.name, metadata: event.metadata)
        return true
    }
}

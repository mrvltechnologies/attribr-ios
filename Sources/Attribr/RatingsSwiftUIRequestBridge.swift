#if os(iOS) && canImport(StoreKit) && canImport(SwiftUI)
import StoreKit
import SwiftUI

/// A tiny iOS 16+ bridge for the system-managed review request.
/// The host view obtains its RequestReviewAction through
/// @Environment(\.requestReview) and passes it at a natural safe moment.
/// This method cannot tell whether a prompt appeared or a review occurred.
///
/// IMPORTANT: The RatingsEngine must run the local eligibility and cooldown
/// checks first. The host must not call request() directly as a substitute.
@available(iOS 16.0, *)
@MainActor
public struct RatingsSwiftUIRequestBridge {
    private let action: RequestReviewAction

    public init(action: RequestReviewAction) {
        self.action = action
    }

    /// True means the OS API was invoked, NOT that a prompt appeared.
    @discardableResult
    public func request() -> Bool {
        action()
        return true
    }
}
#endif

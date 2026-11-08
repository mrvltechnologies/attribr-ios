import Foundation

/// Closed, privacy-safe event names. A client event is not evidence that
/// a native review sheet appeared or that a user submitted a rating.
public enum RatingsEventName: String, CaseIterable, Sendable {
    case valueMoment = "ratings.value_moment"
    case eligibilityEvaluated = "ratings.eligibility_evaluated"
    case eligible = "ratings.eligible"
    case suppressed = "ratings.suppressed"
    case promptOpportunity = "ratings.prompt_opportunity"
    case promptRequested = "ratings.prompt_requested"
    case promptRequestFailed = "ratings.prompt_request_failed"
    case cooldownStarted = "ratings.cooldown_started"
}

/// Product-classified outcomes only; never filenames, photo contents,
/// account information, free-form feedback or star-rating predictions.
public enum RatingsMomentCategory: String, CaseIterable, Sendable {
    case confirmedExport = "confirmed_export"
    case confirmedBatch = "confirmed_batch"
    case persistedProject = "persisted_project"
    case otherConfirmed = "other_confirmed"
}

/// Payload suitable for explicit, consent-gated forwarding through the
/// existing Attribr custom-event route. Constructing never sends data.
public struct RatingsTelemetryEvent: Sendable, Equatable {
    public let name: String
    public let metadata: [String: String]

    public init(
        event: RatingsEventName,
        mode: RatingsMode,
        policy: RatingsPolicy,
        moment: RatingsMomentCategory? = nil,
        reason: RatingsReason? = nil
    ) {
        self.name = event.rawValue
        var fields: [String: String] = [
            "v": "1",
            "mode": mode.rawValue,
            "config_v": policy.version
        ]
        if let moment { fields["moment"] = moment.rawValue }
        if let reason { fields["reason"] = reason.rawValue }
        self.metadata = fields
    }
}

/// The product must establish consent/disclosure before explicitly calling
/// the Attribr trackEvent API with a payload accepted by this validator.
/// There is no automatic telemetry or arbitrary text metadata escape hatch.
public enum RatingsTelemetryContract {
    public static func isApprovedShape(_ event: RatingsTelemetryEvent) -> Bool {
        isApprovedShape(name: event.name, metadata: event.metadata)
    }

    /// Validates raw name/metadata against the closed contract. `RatingsTelemetryEvent` can only be built with
    /// closed fields, so this overload exists to keep the allow-list itself independently testable (defence in depth).
    static func isApprovedShape(name: String, metadata: [String: String]) -> Bool {
        guard RatingsEventName.allCases.contains(where: { $0.rawValue == name }),
              metadata.count <= 10,
              metadata["v"] == "1" else { return false }
        let allowed = Set(["v", "mode", "config_v", "moment", "reason"])
        guard Set(metadata.keys).isSubset(of: allowed),
              let mode = metadata["mode"],
              RatingsMode(rawValue: mode) != nil,
              let version = metadata["config_v"],
              !version.isEmpty && version.count <= 64
                && version.utf8.allSatisfy({
                    (48...57).contains($0) || (65...90).contains($0)
                        || (97...122).contains($0) || $0 == 45 || $0 == 95 || $0 == 46
                })
        else { return false }
        if let m = metadata["moment"],
           !RatingsMomentCategory.allCases.contains(where: { $0.rawValue == m }) {
            return false
        }
        if let r = metadata["reason"], RatingsReason(rawValue: r) == nil {
            return false
        }
        return true
    }
}

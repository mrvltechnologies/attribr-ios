import Foundation
#if os(iOS)
import StoreKit
#endif

/// Manages SKAdNetwork conversion value updates for Attribr.
/// SKAdNetwork is iOS-only; this class no-ops silently on macOS.
@MainActor
public final class SKANManager {

    private var isRegistered = false
    private let network: NetworkClient
    private let logger: AttribrLogger

    struct ConversionMapping: Codable, Sendable {
        let conversionValue: Int
        let eventName: String
        let eventCountThreshold: Int
        let revenueThreshold: Double?
        let coarseValue: String?

        enum CodingKeys: String, CodingKey {
            case conversionValue = "conversion_value"
            case eventName = "event_name"
            case eventCountThreshold = "event_count_threshold"
            case revenueThreshold = "revenue_threshold"
            case coarseValue = "coarse_value"
        }
    }

    private var conversionMappings: [ConversionMapping] = []
    private var currentConversionValue: Int = 0

    init(network: NetworkClient, logger: AttribrLogger) {
        self.network = network
        self.logger = logger
    }

    func register(apiKey: String) {
#if os(iOS)
        guard !isRegistered else { return }
        // Set optimistically so a second register() call while the async work
        // below is still in flight doesn't double-register — but RESET on
        // fetchMappings failure (see the Task below). Previously the flag
        // stayed true forever, so a failed config fetch left
        // `conversionMappings` empty and no later register() could ever
        // retry, silently disabling all conversion-value updates.
        isRegistered = true
        if #available(iOS 16.1, *) {
            SKAdNetwork.updatePostbackConversionValue(0) { error in
                Task { @MainActor in
                    if let error { self.logger.error("SKAN init: \(error.localizedDescription)") }
                    else { self.logger.info("SKAN 4.0 registered") }
                }
            }
        } else if #available(iOS 14.0, *) {
            SKAdNetwork.registerAppForAdNetworkAttribution()
            logger.info("SKAN 2.x/3.x registered")
        }
        Task {
            let fetched = await fetchMappings(apiKey: apiKey)
            if !fetched {
                // Allow a later register() call to retry the whole flow.
                // Re-invoking the SKAdNetwork registration calls above is
                // harmless (they are idempotent), and this is the only way
                // the mappings can ever be re-fetched after a failure.
                isRegistered = false
            }
        }
#endif
    }

    func updateForEvent(name: String, value: Double?) {
#if os(iOS)
        guard isRegistered else { return }
        let matching = conversionMappings.filter { $0.eventName == name }
        guard let bestMatch = matching.max(by: { $0.conversionValue < $1.conversionValue }),
              bestMatch.conversionValue > currentConversionValue else { return }
        let newValue = bestMatch.conversionValue
        currentConversionValue = newValue

        if #available(iOS 16.1, *) {
            let coarse: SKAdNetwork.CoarseConversionValue = {
                switch bestMatch.coarseValue {
                case "high":   return .high
                case "medium": return .medium
                default:       return .low
                }
            }()
            SKAdNetwork.updatePostbackConversionValue(newValue, coarseValue: coarse) { error in
                Task { @MainActor in
                    if let error { self.logger.error("SKAN update failed: \(error.localizedDescription)") }
                    else { self.logger.info("SKAN updated: CV=\(newValue)") }
                }
            }
        } else if #available(iOS 16.0, *) {
            SKAdNetwork.updateConversionValue(newValue)
            logger.info("SKAN 2.x updated: CV=\(newValue)")
        } else {
            // iOS 14.0–15.x: SKAN 2/3 API
            SKAdNetwork.updateConversionValue(newValue)
            logger.info("SKAN 2.x updated (iOS 14–15): CV=\(newValue)")
        }
#endif
    }

#if os(iOS)
    /// Returns `true` when the conversion-value mappings were fetched and
    /// decoded successfully. `register()` uses `false` to roll back the
    /// `isRegistered` flag so the fetch can be retried later.
    private func fetchMappings(apiKey: String) async -> Bool {
        let body: [String: String] = ["app_id": Bundle.main.bundleIdentifier ?? "unknown"]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return false }
        let result = await network.post(path: "attribr-skan-config", body: data)
        if case .success(let responseData, _) = result,
           let response = try? JSONDecoder().decode(MappingResponse.self, from: responseData) {
            self.conversionMappings = response.mappings
            return true
        }
        return false
    }

    private struct MappingResponse: Codable {
        let mappings: [ConversionMapping]
    }
#endif
}

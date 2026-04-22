import Foundation
import StoreKit

/// Manages SKAdNetwork conversion value updates for Attribr.
///
/// ## Usage
/// ```swift
/// // After Attribr.initialize():
/// Attribr.registerSKAN()
///
/// // When user completes a valuable action:
/// Attribr.updateConversionValue(eventName: "purchase", value: 9.99)
/// ```
@MainActor
public final class SKANManager {

    private var conversionMappings: [ConversionMapping] = []
    private var currentConversionValue: Int = 0
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

    init(network: NetworkClient, logger: AttribrLogger) {
        self.network = network
        self.logger = logger
    }

    /// Register with SKAdNetwork. Call once after SDK init.
    func register(apiKey: String) {
        guard !isRegistered else { return }
        isRegistered = true

        if #available(iOS 16.1, *) {
            // SKAN 4.0 — updatePostbackConversionValue with coarse value
            SKAdNetwork.updatePostbackConversionValue(0) { error in
                if let error {
                    Task { @MainActor in
                        self.logger.error("SKAN registration failed: \(error.localizedDescription)")
                    }
                } else {
                    Task { @MainActor in
                        self.logger.info("SKAN 4.0 registered with initial conversion value 0")
                    }
                }
            }
        } else if #available(iOS 14.0, *) {
            // SKAN 2.0/3.0 — registerAppForAdNetworkAttribution
            SKAdNetwork.registerAppForAdNetworkAttribution()
            logger.info("SKAN 2.x/3.x registered")
        }

        // Fetch conversion mappings from server
        Task { await fetchMappings(apiKey: apiKey) }
    }

    /// Update the conversion value based on an event.
    func updateForEvent(name: String, value: Double?) {
        guard isRegistered else {
            logger.debug("SKAN not registered, skipping update for event: \(name)")
            return
        }

        // Find the highest matching conversion value for this event
        let matching = conversionMappings.filter { mapping in
            mapping.eventName == name
        }

        guard let bestMatch = matching.max(by: { $0.conversionValue < $1.conversionValue }) else {
            logger.debug("No SKAN mapping for event: \(name)")
            return
        }

        // Only update if the new value is higher (SKAN values can only increase)
        guard bestMatch.conversionValue > currentConversionValue else {
            logger.debug("SKAN value \(bestMatch.conversionValue) not higher than current \(currentConversionValue)")
            return
        }

        let newValue = bestMatch.conversionValue
        currentConversionValue = newValue

        if #available(iOS 16.1, *) {
            let coarse: SKAdNetwork.CoarseConversionValue
            switch bestMatch.coarseValue {
            case "high":   coarse = .high
            case "medium": coarse = .medium
            default:       coarse = .low
            }

            SKAdNetwork.updatePostbackConversionValue(newValue, coarseValue: coarse) { error in
                Task { @MainActor in
                    if let error {
                        self.logger.error("SKAN update failed: \(error.localizedDescription)")
                    } else {
                        self.logger.info("SKAN updated: CV=\(newValue), coarse=\(bestMatch.coarseValue ?? "low")")
                    }
                }
            }
        } else if #available(iOS 16.0, *) {
            SKAdNetwork.updateConversionValue(newValue)
            logger.info("SKAN 2.x updated: CV=\(newValue)")
        }
    }

    // MARK: - Private

    private func fetchMappings(apiKey: String) async {
        let body: [String: String] = [
            "app_id": Bundle.main.bundleIdentifier ?? "unknown"
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }

        let result = await network.post(path: "attribr-skan-config", body: data)
        switch result {
        case .success(let responseData, _):
            if let response = try? JSONDecoder().decode(MappingResponse.self, from: responseData) {
                self.conversionMappings = response.mappings
                logger.info("Loaded \(response.mappings.count) SKAN conversion mappings")
            }
        case .failure(let err):
            logger.error("Failed to fetch SKAN mappings: \(err)")
        }
    }

    private struct MappingResponse: Codable {
        let mappings: [ConversionMapping]
    }
}

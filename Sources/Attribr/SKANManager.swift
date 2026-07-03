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
        Task { await fetchMappings(apiKey: apiKey) }
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
        }
#endif
    }

#if os(iOS)
    private func fetchMappings(apiKey: String) async {
        let body: [String: String] = ["app_id": Bundle.main.bundleIdentifier ?? "unknown"]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        let result = await network.post(path: "attribr-skan-config", body: data)
        if case .success(let responseData, _) = result,
           let response = try? JSONDecoder().decode(MappingResponse.self, from: responseData) {
            self.conversionMappings = response.mappings
        }
    }

    private struct MappingResponse: Codable {
        let mappings: [ConversionMapping]
    }
#endif
}

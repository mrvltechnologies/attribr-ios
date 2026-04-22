import Foundation

/// Handles deep link resolution for Attribr attribution.
///
/// ## Usage — SwiftUI (iOS 17+)
/// ```swift
/// .onOpenURL { url in
///     Attribr.handleDeepLink(url)
/// }
/// ```
///
/// ## Usage — UIKit AppDelegate
/// ```swift
/// func application(_ app: UIApplication, open url: URL, options: ...) -> Bool {
///     Attribr.handleDeepLink(url)
///     return true
/// }
///
/// func application(_ application: UIApplication, continue userActivity: NSUserActivity, ...) {
///     if let url = userActivity.webpageURL {
///         Attribr.handleDeepLink(url)
///     }
/// }
/// ```
@MainActor
public final class DeepLinkHandler {
    private let network: NetworkClient
    private let deviceId: DeviceIdentifier
    private let logger: AttribrLogger

    init(network: NetworkClient, deviceId: DeviceIdentifier, logger: AttribrLogger) {
        self.network = network
        self.deviceId = deviceId
        self.logger = logger
    }

    /// Process an incoming URL. Extracts link_code from attribr.dev/l/{code} URLs
    /// or custom scheme attribr://{code} URLs. Sends attribution to server.
    public func handle(_ url: URL) async -> DeepLinkResult {
        logger.debug("Processing deep link: \(url.absoluteString)")

        // Extract link code from URL
        guard let linkCode = extractLinkCode(from: url) else {
            logger.debug("URL is not an Attribr deep link")
            return .notAttribrLink
        }

        logger.info("Deep link code extracted: \(linkCode)")

        // Send to server for attribution
        let deviceHash = deviceId.hash()
        let appId = Bundle.main.bundleIdentifier ?? "unknown"

        let body: [String: Any] = [
            "app_id": appId,
            "device_hash": deviceHash,
            "link_code": linkCode
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            return .error("Failed to encode request")
        }

        let result = await network.post(path: "attribr-deeplink-resolve", body: data)
        switch result {
        case .success(let responseData, _):
            // Parse the response to get destination info
            if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let destination = json["destination"] as? String,
               let destinationURL = URL(string: destination) {
                // Extract string-typed metadata for Sendable compliance
                let metadata = extractStringMetadata(from: json["metadata"])
                logger.info("Deep link resolved -> \(destination)")
                return .resolved(destinationURL, metadata: metadata)
            }
            return .attributed(linkCode)
        case .failure(let err):
            logger.error("Deep link resolution failed: \(err)")
            return .attributed(linkCode) // Still mark as attributed even if server call fails
        }
    }

    // MARK: - Private

    private func extractLinkCode(from url: URL) -> String? {
        // Pattern 1: https://attribr.dev/l/{code}
        if let host = url.host,
           (host == "attribr.dev" || host == "www.attribr.dev"),
           url.pathComponents.count >= 3,
           url.pathComponents[1] == "l" {
            return url.pathComponents[2]
        }

        // Pattern 2: attribr://{code} (custom URL scheme)
        if url.scheme == "attribr" {
            return url.host
        }

        // Pattern 3: Any URL with ?attribr_link={code} query parameter
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let linkParam = components.queryItems?.first(where: { $0.name == "attribr_link" })?.value {
            return linkParam
        }

        return nil
    }

    /// Extract only String-valued entries from an arbitrary JSON value
    /// to produce a Sendable-safe dictionary.
    private func extractStringMetadata(from value: Any?) -> [String: String] {
        guard let dict = value as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, val) in dict {
            if let str = val as? String {
                result[key] = str
            } else if let num = val as? NSNumber {
                result[key] = num.stringValue
            }
        }
        return result
    }
}

/// Result of processing a deep link.
public enum DeepLinkResult: Sendable {
    /// URL was not an Attribr deep link — pass to your own URL handler.
    case notAttribrLink
    /// Link was attributed but no destination was returned.
    case attributed(String)
    /// Link resolved to a destination URL with metadata (string key-value pairs).
    case resolved(URL, metadata: [String: String])
    /// An error occurred during resolution.
    case error(String)
}

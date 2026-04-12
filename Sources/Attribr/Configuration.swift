import Foundation

/// Immutable configuration for the Attribr SDK.
/// Pass one to `Attribr.initialize(apiKey:config:)`.
public struct AttribrConfiguration: Sendable {
    /// Base URL of the Attribr Edge Functions.
    public let baseURL: URL
    /// Maximum number of events to buffer offline before dropping oldest. Default: 500.
    public let maxQueueSize: Int
    /// Request timeout in seconds. Default: 15.
    public let requestTimeout: TimeInterval
    /// Enable verbose debug logging to Console.app. Default: false.
    public let debugLogging: Bool
    /// Maximum retry attempts per network request. Default: 3.
    public let maxRetries: Int

    public init(
        baseURL: URL = URL(string: "https://pblzmoxcwpqywuyubdim.supabase.co/functions/v1")!,
        maxQueueSize: Int = 500,
        requestTimeout: TimeInterval = 15,
        debugLogging: Bool = false,
        maxRetries: Int = 3
    ) {
        self.baseURL = baseURL
        self.maxQueueSize = maxQueueSize
        self.requestTimeout = requestTimeout
        self.debugLogging = debugLogging
        self.maxRetries = maxRetries
    }
}

/// The attribution source for an install.
public enum AttributionSource: String, Sendable {
    case rippl   = "rippl"
    case utm     = "utm"
    case custom  = "custom"
}

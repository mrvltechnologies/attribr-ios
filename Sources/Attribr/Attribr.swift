import Foundation

/// **Attribr by MRVL** — Install attribution + 30-day retention tracking.
///
/// ## Quick Start
/// ```swift
/// // AppDelegate / SwiftUI App.init()
/// Attribr.initialize(apiKey: "attr_live_…")
/// Attribr.setConsent(.granted)   // call after your GDPR banner
/// Attribr.trackLaunch()
/// ```
///
/// ## Thread Safety
/// All public methods are safe to call from any thread.
/// Internally they dispatch to a single serial actor.
@MainActor
public final class Attribr {
    // MARK: - Shared instance

    private static var shared: Attribr?

    // MARK: - Internal state

    private let config: AttribrConfiguration
    private let apiKey: String
    private let consent: ConsentManager
    private let deviceId: DeviceIdentifier
    private let queue: EventQueue
    private let network: NetworkClient
    private let log: AttribrLogger

    // MARK: - Init

    private init(apiKey: String, config: AttribrConfiguration) {
        self.apiKey = apiKey
        self.config = config
        self.log = AttribrLogger(enabled: config.debugLogging)
        self.consent = ConsentManager()
        self.deviceId = DeviceIdentifier()
        self.queue = EventQueue(maxSize: config.maxQueueSize, logger: log)
        self.network = NetworkClient(apiKey: apiKey, config: config, logger: log)
        log.info("Attribr initialised — key prefix: \(String(apiKey.prefix(18)))")
    }

    // MARK: - Public API

    /// Initialise the SDK. Call once at app start, before any other method.
    /// Subsequent calls to `initialize` are ignored (SDK is a singleton).
    public static func initialize(
        apiKey: String,
        config: AttribrConfiguration = AttribrConfiguration()
    ) {
        guard shared == nil else { return }
        shared = Attribr(apiKey: apiKey, config: config)
    }

    /// Inform the SDK of the user's GDPR consent decision.
    /// The SDK will not send any data until this is set to `.granted`.
    public static func setConsent(_ state: ConsentState) {
        guard let sdk = shared else {
            preconditionFailure("Call Attribr.initialize() before setConsent()")
        }
        sdk.consent.set(state)
        sdk.log.info("Consent set to: \(state.rawValue)")
        if state == .granted {
            // Flush any events that were queued while consent was unknown
            Task { await sdk.flushQueue() }
        }
    }

    /// Record an app launch. Call this every time the app becomes active.
    /// Silently ignored until consent is `.granted`.
    public static func trackLaunch() {
        guard let sdk = shared else { return }
        guard sdk.consent.isGranted else {
            sdk.log.debug("trackLaunch skipped — consent not granted")
            return
        }
        Task { await sdk.sendTrack() }
    }

    /// Record a referral attribution.
    /// Call this when the app is opened from a referral link or promo code.
    ///
    /// - Parameters:
    ///   - code: The attribution code (e.g. "JOHN2026" or UTM campaign value).
    ///   - source: The source type (`.rippl`, `.utm`, or `.custom`).
    ///   - utmSource: Optional UTM source string (used when `source == .utm`).
    ///   - utmCampaign: Optional UTM campaign string.
    public static func attributeInstall(
        code: String,
        source: AttributionSource,
        utmSource: String? = nil,
        utmCampaign: String? = nil
    ) {
        guard let sdk = shared else { return }
        guard sdk.consent.isGranted else {
            sdk.log.debug("attributeInstall skipped — consent not granted")
            return
        }
        Task {
            await sdk.sendAttribution(
                code: code,
                source: source,
                utmSource: utmSource,
                utmCampaign: utmCampaign
            )
        }
    }

    /// Track a custom event (e.g. "purchase", "level_complete").
    ///
    /// - Parameters:
    ///   - name: Event name. Max 100 characters.
    ///   - value: Optional numeric value (e.g. purchase amount in pence).
    ///   - currency: ISO 4217 currency code (e.g. "GBP").
    ///   - metadata: Optional free-form key-value pairs (max 10 keys).
    public static func trackEvent(
        name: String,
        value: Double? = nil,
        currency: String? = nil,
        metadata: [String: String] = [:]
    ) {
        guard let sdk = shared else { return }
        guard sdk.consent.isGranted else { return }
        Task {
            await sdk.sendEvent(
                name: name,
                value: value,
                currency: currency,
                metadata: metadata
            )
        }
    }

    /// Delete all data for this device. Implements GDPR right to be forgotten.
    /// Call this when the user requests data deletion from your app's Settings.
    ///
    /// - Parameter completion: Called on the main queue when the server confirms deletion.
    public static func deleteAllData(completion: @escaping @Sendable (Bool) -> Void) {
        guard let sdk = shared else {
            completion(false)
            return
        }
        Task {
            let success = await sdk.sendDelete()
            await MainActor.run { completion(success) }
        }
    }

    // MARK: - Internal send methods

    private func sendTrack() async {
        let deviceHash = deviceId.hash()
        let appId = Bundle.main.bundleIdentifier ?? "unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

        let body: [String: Any] = [
            "app_id": appId,
            "device_hash": deviceHash,
            "os_version": osVersion,
            "app_version": appVersion
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }

        let result = await network.post(path: "attribr-track", body: data)
        switch result {
        case .success:
            log.debug("trackLaunch: success")
        case .failure(let err):
            log.error("trackLaunch failed: \(err)")
            let event = QueuedEvent(
                id: UUID().uuidString,
                kind: .track,
                payload: data,
                enqueuedAt: Date(),
                attempts: 1
            )
            queue.enqueue(event)
        }
    }

    private func sendAttribution(
        code: String,
        source: AttributionSource,
        utmSource: String?,
        utmCampaign: String?
    ) async {
        let deviceHash = deviceId.hash()
        let appId = Bundle.main.bundleIdentifier ?? "unknown"

        var body: [String: Any] = [
            "app_id": appId,
            "device_hash": deviceHash,
            "attribution_code": code,
            "source": source.rawValue
        ]
        if let utmSource { body["utm_source"] = utmSource }
        if let utmCampaign { body["utm_campaign"] = utmCampaign }

        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }

        let result = await network.post(path: "attribr-attribute", body: data)
        switch result {
        case .success:
            log.debug("attributeInstall: success")
        case .failure(let err):
            log.error("attributeInstall failed: \(err)")
            let event = QueuedEvent(
                id: UUID().uuidString,
                kind: .attribute,
                payload: data,
                enqueuedAt: Date(),
                attempts: 1
            )
            queue.enqueue(event)
        }
    }

    private func sendEvent(
        name: String,
        value: Double?,
        currency: String?,
        metadata: [String: String]
    ) async {
        let deviceHash = deviceId.hash()
        let appId = Bundle.main.bundleIdentifier ?? "unknown"

        var body: [String: Any] = [
            "app_id": appId,
            "device_hash": deviceHash,
            "event_name": name,
            "metadata": metadata
        ]
        if let value { body["value"] = value }
        if let currency { body["currency"] = currency }

        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }

        let result = await network.post(path: "attribr-track", body: data)
        switch result {
        case .success:
            log.debug("trackEvent '\(name)': success")
        case .failure(let err):
            log.error("trackEvent '\(name)' failed: \(err)")
            let event = QueuedEvent(
                id: UUID().uuidString,
                kind: .event,
                payload: data,
                enqueuedAt: Date(),
                attempts: 1
            )
            queue.enqueue(event)
        }
    }

    private func sendDelete() async -> Bool {
        let deviceHash = deviceId.hash()
        let appId = Bundle.main.bundleIdentifier ?? "unknown"
        let body = ["app_id": appId, "device_hash": deviceHash]

        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return false }

        let result = await network.delete(path: "attribr-delete-user-data", body: data)
        switch result {
        case .success:
            log.info("deleteAllData: confirmed by server")
            return true
        case .failure(let err):
            log.error("deleteAllData failed: \(err)")
            return false
        }
    }

    // MARK: - Queue flush

    private func flushQueue() async {
        let pending = queue.peek()
        guard !pending.isEmpty else { return }
        log.info("Flushing \(pending.count) queued events")

        for event in pending {
            let path: String
            let method: String
            switch event.kind {
            case .track, .event: path = "attribr-track"; method = "POST"
            case .attribute:     path = "attribr-attribute"; method = "POST"
            case .delete:        path = "attribr-delete-user-data"; method = "DELETE"
            }

            let result: NetworkResult
            if method == "DELETE" {
                result = await network.delete(path: path, body: event.payload)
            } else {
                result = await network.post(path: path, body: event.payload)
            }

            switch result {
            case .success:
                queue.remove(id: event.id)
            case .failure:
                queue.markFailed(id: event.id)
            }
        }
    }
}

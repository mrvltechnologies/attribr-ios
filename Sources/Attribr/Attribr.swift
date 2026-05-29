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

    /// Nonisolated key store — set once during `initialize()`, read by
    /// `AttribrMonetisation` from async contexts without hopping to MainActor.
    /// Safe because it is written exactly once before any reader exists.
    /// The raw API key passed to `initialize()`. Used by CrashrKit to reuse the same credential.
    nonisolated(unsafe) public static var _apiKey: String?

    // MARK: - Internal state

    private let config: AttribrConfiguration
    private let apiKey: String
    private let consent: ConsentManager
    private let deviceId: DeviceIdentifier
    private let queue: EventQueue
    private let network: NetworkClient
    private let log: AttribrLogger
    private let deepLinks: DeepLinkHandler
    private let skan: SKANManager

    // MARK: - Init

    private init(apiKey: String, config: AttribrConfiguration) {
        self.apiKey = apiKey
        self.config = config
        self.log = AttribrLogger(enabled: config.debugLogging)
        self.consent = ConsentManager()
        self.deviceId = DeviceIdentifier()
        self.queue = EventQueue(maxSize: config.maxQueueSize, logger: log)
        self.network = NetworkClient(apiKey: apiKey, config: config, logger: log)
        self.deepLinks = DeepLinkHandler(network: network, deviceId: deviceId, logger: log)
        self.skan = SKANManager(network: network, logger: log)
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
        _apiKey = apiKey
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
        Task {
            // Flush any events that failed on a previous launch before sending the
            // current one. Without this, queued events are only retried when
            // setConsent(.granted) is called again — which never happens after init.
            await sdk.flushQueue()
            await sdk.sendTrack()
        }
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

    /// Handle an incoming deep link URL.
    /// Call this from your SwiftUI `.onOpenURL` handler or UIKit URL handling methods.
    ///
    /// Returns a `DeepLinkResult` indicating whether the URL was an Attribr link
    /// and what destination it resolved to.
    @discardableResult
    public static func handleDeepLink(_ url: URL) async -> DeepLinkResult {
        guard let sdk = shared else { return .notAttribrLink }
        guard sdk.consent.isGranted else {
            sdk.log.debug("handleDeepLink skipped — consent not granted")
            return .notAttribrLink
        }
        return await sdk.deepLinks.handle(url)
    }

    /// Register with Apple's SKAdNetwork for privacy-preserving attribution.
    /// Call once after `initialize()` and `setConsent(.granted)`.
    public static func registerSKAN() {
        guard let sdk = shared else {
            preconditionFailure("Call Attribr.initialize() before registerSKAN()")
        }
        sdk.skan.register(apiKey: sdk.apiKey)
    }

    /// Update the SKAdNetwork conversion value based on an event.
    /// The SDK will look up the conversion value mapping from your dashboard config
    /// and update Apple's SKAN framework accordingly.
    ///
    /// - Parameters:
    ///   - eventName: The event name matching your SKAN config (e.g. "purchase", "signup").
    ///   - value: Optional revenue value for revenue-based conversion values.
    public static func updateConversionValue(eventName: String, value: Double? = nil) {
        guard let sdk = shared else { return }
        sdk.skan.updateForEvent(name: eventName, value: value)
    }

    /// Track an ad impression revenue event.
    /// Call from your ad network's impression-level revenue callback (AdMob, MAX, IronSource, Unity Ads, etc.)
    ///
    /// - Parameters:
    ///   - adNetwork: Ad network name (e.g. "admob", "max", "ironsource", "applovin", "unity")
    ///   - adUnitId: Optional ad unit identifier
    ///   - adFormat: Optional format: "banner", "interstitial", "rewarded", "native"
    ///   - revenue: Revenue amount (typically in USD micro-cents from ad networks)
    ///   - currency: ISO 4217 currency code, default "USD"
    public static func trackAdRevenue(
        adNetwork: String,
        adUnitId: String? = nil,
        adFormat: String? = nil,
        revenue: Double,
        currency: String = "USD"
    ) {
        guard let sdk = shared else { return }
        guard sdk.consent.isGranted else {
            sdk.log.debug("trackAdRevenue skipped — consent not granted")
            return
        }
        Task {
            await sdk.sendAdRevenue(
                adNetwork: adNetwork,
                adUnitId: adUnitId,
                adFormat: adFormat,
                revenue: revenue,
                currency: currency
            )
        }
    }

    /// Track an in-app purchase or subscription revenue event.
    ///
    /// Call this after every successful StoreKit / Play Billing transaction to power
    /// ROAS, LTV, and revenue-by-source reports in the Attribr dashboard.
    /// Idempotent — duplicate `transactionId` values are silently ignored server-side.
    ///
    /// - Parameters:
    ///   - amount: Revenue amount in `currency` (e.g. `9.99` for a £9.99 charge)
    ///   - currency: ISO 4217 code (default `"USD"`)
    ///   - productId: Product SKU, e.g. `"com.myapp.pro_monthly"`
    ///   - transactionId: Unique transaction identifier for deduplication.
    ///       Use `transaction.originalID.description` from StoreKit 2, or the
    ///       `purchaseToken` from Google Play Billing.
    ///   - store: `"apple"`, `"google"`, `"stripe"`, or `"other"` (default `"apple"`)
    ///   - eventType: `"initial_purchase"` (default), `"renewal"`, `"refund"`, etc.
    public static func trackRevenue(
        amount: Double,
        currency: String = "USD",
        productId: String? = nil,
        transactionId: String,
        store: String = "apple",
        eventType: String = "initial_purchase"
    ) {
        guard let sdk = shared else { return }
        guard sdk.consent.isGranted else {
            sdk.log.debug("trackRevenue skipped — consent not granted")
            return
        }
        Task {
            await sdk.sendRevenue(
                amount: amount,
                currency: currency,
                productId: productId,
                transactionId: transactionId,
                store: store,
                eventType: eventType
            )
        }
    }

    /// Register the device's APNs push token for uninstall detection.
    /// Call this in AppDelegate.didRegisterForRemoteNotificationsWithDeviceToken(_:deviceToken:)
    ///
    /// - Parameter tokenData: The raw token Data from APNs
    public static func registerPushToken(_ tokenData: Data) {
        guard let sdk = shared else { return }
        guard sdk.consent.isGranted else {
            sdk.log.debug("registerPushToken skipped — consent not granted")
            return
        }
        Task { await sdk.sendPushToken(tokenData) }
    }

    /// Track a subscription or in-app purchase event.
    /// Call after successful StoreKit transactions to attribute revenue to acquisition sources.
    ///
    /// - Parameters:
    ///   - productId: StoreKit product ID (e.g. "com.myapp.pro_monthly")
    ///   - eventType: "purchase", "renewal", "cancellation", "refund", "trial_start"
    ///   - revenue: Revenue in currency (nil for non-revenue events)
    ///   - currency: ISO 4217 code, default "USD"
    ///   - originalTransactionId: StoreKit original transaction ID for deduplication
    public static func trackSubscriptionEvent(
        productId: String,
        eventType: String,
        revenue: Double? = nil,
        currency: String = "USD",
        originalTransactionId: String? = nil
    ) {
        guard let sdk = shared else { return }
        guard sdk.consent.isGranted else {
            sdk.log.debug("trackSubscriptionEvent skipped — consent not granted")
            return
        }
        Task {
            await sdk.sendSubscriptionEvent(
                productId: productId,
                eventType: eventType,
                revenue: revenue,
                currency: currency,
                originalTransactionId: originalTransactionId
            )
        }
    }

    // MARK: - Internal send methods

    private func sendTrack() async {
        let deviceHash = deviceId.hash()
        let appId = Bundle.main.bundleIdentifier ?? "unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

        var body: [String: Any] = [
            "app_id": appId,
            "device_hash": deviceHash,
            "os_version": osVersion,
            "app_version": appVersion
        ]

        // Re-engagement detection: compare against last *successfully confirmed* seen timestamp.
        // IMPORTANT: install_type MUST always be present in the payload. The server-side
        // install_type column is NOT NULL — an absent field normalises to null on the server
        // which violates the constraint and causes a 500. Default to "new_install" when no
        // prior timestamp exists (genuine first launch) or when the device was last seen
        // recently (< 7 days — it is a returning user but the install record already exists
        // so the server skips the insert path entirely for this case).
        let now = Date().timeIntervalSince1970
        if let lastSeenAt = UserDefaults.standard.object(forKey: "attribr.lastSeenAt") as? Double {
            let daysSince = (now - lastSeenAt) / 86400
            if daysSince > 30 {
                body["re_engagement"] = true
                body["days_since_last_seen"] = Int(daysSince)
                body["install_type"] = "re_engagement"
                log.info("trackLaunch: re-engagement detected (\(Int(daysSince)) days since last seen)")
            } else if daysSince > 7 {
                body["install_type"] = "returning"
            } else {
                body["install_type"] = "returning"  // < 7 days — already has an install record
            }
        } else {
            body["install_type"] = "new_install"    // no prior timestamp → first ever launch
        }
        // NOTE: lastSeenAt is updated ONLY on confirmed server success below.
        // Advancing the timestamp before a successful response would corrupt
        // re-engagement detection for users with intermittent connectivity.

        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }

        let result = await network.post(path: "attribr-track", body: data)
        switch result {
        case .success:
            // Stamp the confirmed timestamp now that the server acknowledged the event
            UserDefaults.standard.set(now, forKey: "attribr.lastSeenAt")
            log.debug("trackLaunch: success")
        case .failure(let err):
            log.error("trackLaunch failed: \(err)")
            // Do NOT advance lastSeenAt — the server hasn't confirmed this launch yet.
            // The event is queued and will be retried on the next trackLaunch() call.
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

    private func sendAdRevenue(
        adNetwork: String,
        adUnitId: String?,
        adFormat: String?,
        revenue: Double,
        currency: String
    ) async {
        let deviceHash = deviceId.hash()
        let appId = Bundle.main.bundleIdentifier ?? "unknown"

        var body: [String: Any] = [
            "app_id": appId,
            "device_hash": deviceHash,
            "ad_network": adNetwork,
            "revenue_usd": revenue,
            "currency": currency
        ]
        if let adUnitId { body["ad_unit_id"] = adUnitId }
        if let adFormat { body["ad_format"] = adFormat }

        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }

        let result = await network.post(path: "attribr-ad-revenue", body: data)
        switch result {
        case .success:
            log.debug("trackAdRevenue (\(adNetwork)): success")
        case .failure(let err):
            log.error("trackAdRevenue failed: \(err)")
            let event = QueuedEvent(
                id: UUID().uuidString,
                kind: .adRevenue,
                payload: data,
                enqueuedAt: Date(),
                attempts: 1
            )
            queue.enqueue(event)
        }
    }

    private func sendPushToken(_ tokenData: Data) async {
        let deviceHash = deviceId.hash()
        let appId = Bundle.main.bundleIdentifier ?? "unknown"
        let hexToken = tokenData.map { String(format: "%02x", $0) }.joined()

        let body: [String: Any] = [
            "app_id": appId,
            "device_hash": deviceHash,
            "platform": "ios",
            "push_token": hexToken
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }

        let result = await network.post(path: "attribr-push-token", body: data)
        switch result {
        case .success:
            log.debug("registerPushToken: success")
        case .failure(let err):
            // Push token registration is best-effort — no queuing
            log.error("registerPushToken failed: \(err)")
        }
    }

    private func sendSubscriptionEvent(
        productId: String,
        eventType: String,
        revenue: Double?,
        currency: String,
        originalTransactionId: String?
    ) async {
        let deviceHash = deviceId.hash()
        let appId = Bundle.main.bundleIdentifier ?? "unknown"

        var body: [String: Any] = [
            "app_id": appId,
            "device_hash": deviceHash,
            "product_id": productId,
            "event_type": eventType,
            "currency": currency,
            "store": "apple"
        ]
        if let revenue { body["revenue_usd"] = revenue }
        if let originalTransactionId { body["original_transaction_id"] = originalTransactionId }

        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }

        let result = await network.post(path: "attribr-subscription-event", body: data)
        switch result {
        case .success:
            log.debug("trackSubscriptionEvent '\(eventType)' (\(productId)): success")
        case .failure(let err):
            log.error("trackSubscriptionEvent failed: \(err)")
            let event = QueuedEvent(
                id: UUID().uuidString,
                kind: .subscriptionEvent,
                payload: data,
                enqueuedAt: Date(),
                attempts: 1
            )
            queue.enqueue(event)
        }
    }

    private func sendRevenue(
        amount: Double,
        currency: String,
        productId: String?,
        transactionId: String,
        store: String,
        eventType: String
    ) async {
        let deviceHash = deviceId.hash()
        let appId      = Bundle.main.bundleIdentifier ?? "unknown"

        var body: [String: Any] = [
            "app_id":         appId,
            "device_hash":    deviceHash,
            "amount":         amount,
            "currency":       currency,
            "transaction_id": transactionId,
            "store":          store,
            "event_type":     eventType,
        ]
        if let productId { body["product_id"] = productId }

        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }

        let result = await network.post(path: "attribr-revenue", body: data)
        switch result {
        case .success:
            log.debug("trackRevenue '\(eventType)' (\(transactionId)): success")
        case .failure(let err):
            log.error("trackRevenue failed: \(err)")
            let event = QueuedEvent(
                id: UUID().uuidString,
                kind: .revenue,
                payload: data,
                enqueuedAt: Date(),
                attempts: 1
            )
            queue.enqueue(event)
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
            case .track, .event:   path = "attribr-track"; method = "POST"
            case .attribute:       path = "attribr-attribute"; method = "POST"
            case .delete:          path = "attribr-delete-user-data"; method = "DELETE"
            case .adRevenue:       path = "attribr-ad-revenue"; method = "POST"
            case .subscriptionEvent: path = "attribr-subscription-event"; method = "POST"
            case .revenue:         path = "attribr-revenue"; method = "POST"
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

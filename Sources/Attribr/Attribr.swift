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
/// ## Concurrency — main-actor isolated
/// The entire public API is `@MainActor`. Call it from the main actor: directly from
/// SwiftUI view bodies/lifecycle methods, `AppDelegate` callbacks, or any other
/// main-actor context — all of these already run on the main actor, so no extra work
/// is needed there. Calling from an `async` context that isn't already on the main
/// actor works too; Swift inserts an implicit hop.
///
/// The one case that needs an explicit annotation: if you wrap these calls in your
/// own type and that type is not already `@MainActor`, mark it `@MainActor` (or mark
/// the wrapping function `@MainActor`) — otherwise Swift 6 rejects the synchronous
/// call at compile time. For example:
/// ```swift
/// @MainActor
/// enum MyAttribrWrapper {
///     static func start(apiKey: String) {
///         Attribr.initialize(apiKey: apiKey)
///         Attribr.setConsent(.granted)
///         Attribr.trackLaunch()
///     }
/// }
/// ```
/// Calling `Attribr.initialize`/`setConsent`/`trackLaunch`/etc. before `initialize()`
/// has been called is a safe no-op (logged as an error), not a crash.
@MainActor
public final class Attribr {
    // MARK: - Shared instance

    private static var shared: Attribr?

    /// Test-only reset of the singleton. Internal (not public) — exists solely so
    /// `@testable import Attribr` test targets can exercise both the pre-init and
    /// post-init code paths without one test's `initialize()` call permanently
    /// poisoning the singleton for every other test in the same process. No shipping
    /// app can call this; it is not part of the public API surface.
    internal static func resetForTesting() {
        shared = nil
        _apiKey = nil
    }

    /// Test-only initializer that threads a stubbed `URLSession` through to the
    /// internal `NetworkClient`, exactly like `initialize(apiKey:config:)` but
    /// without requiring live network access. Exists solely so `@testable`
    /// tests can assert on the exact request a public API call (`trackLaunch`,
    /// etc.) produces. Not part of the public API surface — no shipping app can
    /// reach this from outside the module.
    internal static func initializeForTesting(
        apiKey: String,
        config: AttribrConfiguration = AttribrConfiguration(),
        session: URLSession
    ) {
        shared = nil
        _apiKey = apiKey
        shared = Attribr(apiKey: apiKey, config: config, session: session)
    }

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

    /// In-flight guard for `flushQueue()`. The documented integration calls
    /// `setConsent(.granted)` immediately followed by `trackLaunch()` — both
    /// spawn a flush Task, and without this guard the two flushes interleave
    /// across await suspension points and every queued event is sent twice
    /// (each flush `peek()`s the same events before either `remove()`s them).
    /// The class is `@MainActor`, so reading/writing this flag is race-free;
    /// an overlapping flush simply returns and lets the first one finish.
    private var isFlushing = false

    // MARK: - Init

    private init(apiKey: String, config: AttribrConfiguration, session: URLSession? = nil) {
        self.apiKey = apiKey
        self.config = config
        self.log = AttribrLogger(enabled: config.debugLogging)
        self.consent = ConsentManager()
        self.deviceId = DeviceIdentifier()
        self.queue = EventQueue(maxSize: config.maxQueueSize, logger: log)
        self.network = NetworkClient(apiKey: apiKey, config: config, logger: log, session: session)
        self.deepLinks = DeepLinkHandler(network: network, deviceId: deviceId, logger: log)
        self.skan = SKANManager(network: network, logger: log)
        // Log only the first 10 chars — that is the non-secret "attr_live_" /
        // "attr_test_" scheme prefix. Anything longer would leak part of the
        // key material into Console.app / sysdiagnose logs.
        log.info("Attribr initialised — key prefix: \(String(apiKey.prefix(10)))")
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
    ///
    /// Calling this before `initialize()` is a no-op (logged as an error) rather than a crash —
    /// call-order mistakes in integrating apps should not be able to take down the host app.
    public static func setConsent(_ state: ConsentState) {
        guard let sdk = shared else {
            AttribrLogger(enabled: false).error("Attribr.setConsent() called before Attribr.initialize() — ignored")
            return
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
    ///
    /// - Parameter webClickId: Optional `attribr_web_click_id` token recovered
    ///   from the app's launch URL via `DeepLinkHandler.extractWebClickId(from:)`.
    ///   Pass it when your app was opened from a Universal Link that carried the
    ///   token — the backend verifies it server-side before linking this install
    ///   to the originating web visit. Blank/empty values are treated as absent.
    public static func trackLaunch(webClickId: String? = nil) {
        guard let sdk = shared else { return }
        guard sdk.consent.isGranted else {
            sdk.log.debug("trackLaunch skipped — consent not granted")
            return
        }
        let normalizedWebClickId = (webClickId?.isEmpty == false) ? webClickId : nil
        Task {
            // Flush any events that failed on a previous launch before sending the
            // current one. Without this, queued events are only retried when
            // setConsent(.granted) is called again — which never happens after init.
            await sdk.flushQueue()
            await sdk.sendTrack(webClickId: normalizedWebClickId)
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
    ///
    /// Calling this before `initialize()` is a no-op (logged as an error) rather than a crash —
    /// call-order mistakes in integrating apps should not be able to take down the host app.
    public static func registerSKAN() {
        guard let sdk = shared else {
            AttribrLogger(enabled: false).error("Attribr.registerSKAN() called before Attribr.initialize() — ignored")
            return
        }
        guard sdk.consent.isGranted else {
            sdk.log.debug("registerSKAN skipped — consent not granted")
            return
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
        guard sdk.consent.isGranted else {
            sdk.log.debug("updateConversionValue skipped — consent not granted")
            return
        }
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
    ///   - store: Store identifier — "apple" (default), "google", "stripe", or "other"
    public static func trackSubscriptionEvent(
        productId: String,
        eventType: String,
        revenue: Double? = nil,
        currency: String = "USD",
        originalTransactionId: String? = nil,
        store: String = "apple"
    ) {
        guard let sdk = shared else { return }
        guard sdk.consent.isGranted else {
            sdk.log.debug("trackSubscriptionEvent skipped — consent not granted")
            return
        }
        if originalTransactionId == nil {
            sdk.log.debug("trackSubscriptionEvent called without originalTransactionId — duplicate events will not be deduplicated")
        }
        Task {
            await sdk.sendSubscriptionEvent(
                productId: productId,
                eventType: eventType,
                revenue: revenue,
                currency: currency,
                originalTransactionId: originalTransactionId,
                store: store
            )
        }
    }

    // MARK: - Internal SDK bridge (RevenueDiscoveryReporter)

    /// Consent state exposed to SDK-internal reporters that live outside this
    /// class (e.g. `RevenueDiscoveryReporter`, which historically only checked
    /// `_apiKey != nil` and therefore bypassed the consent gate entirely).
    /// `nil` means the SDK has not been initialised yet.
    internal static var consentState: ConsentState? {
        shared?.consent.state
    }

    /// Convenience — `true` only when the SDK is initialised AND the user has
    /// granted consent. Any pre-init or unknown/revoked state reads as `false`.
    internal static var isConsentGranted: Bool {
        shared?.consent.isGranted ?? false
    }

    /// Enqueue a revenue-discovery payload on the SDK's durable offline queue.
    /// Used by `RevenueDiscoveryReporter` both when consent is still `.unknown`
    /// (the payload is held on-device and flushed after `setConsent(.granted)`)
    /// and when a live send fails (retried by the normal flush path).
    /// No-op before `initialize()` — there is no queue to write to.
    ///
    /// - Parameter attempts: `0` when nothing has been tried yet (consent
    ///   pending), `1` when a live send already failed — mirrors how the
    ///   other send methods enqueue after their first failed attempt.
    internal static func enqueueRevenueDiscovery(_ payload: Data, attempts: Int = 1) {
        guard let sdk = shared else { return }
        let event = QueuedEvent(
            id: UUID().uuidString,
            kind: .revenueDiscovery,
            payload: payload,
            enqueuedAt: Date(),
            attempts: attempts
        )
        sdk.queue.enqueue(event)
    }

    // MARK: - Internal send methods

    private func sendTrack(webClickId: String? = nil) async {
        let deviceHash = deviceId.hash()
        let appId = Bundle.main.bundleIdentifier ?? "unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

        // Device locale → ISO 3166-1 alpha-2 country code (e.g. "US", "GB").
        // Sent explicitly so the server has a country even when the user has
        // iCloud Private Relay enabled (which masks the IP from geolocation).
        let localeCountry: String? = {
            if #available(iOS 16, macOS 13, *) {
                return Locale.current.region?.identifier
            } else {
                return Locale.current.regionCode
            }
        }()

        var body: [String: Any] = [
            "app_id": appId,
            "device_hash": deviceHash,
            "os_version": osVersion,
            "app_version": appVersion,
            "platform": "ios",
            // Sprint 13 — app-local install-instance ID hash. Enables the
            // backend's `reinstall_candidate` classification on the second
            // installation of the app on the same device (UserDefaults is
            // wiped on uninstall, so the hash changes across reinstalls).
            "sdk_install_instance_id_hash": InstallInstance.hashHex(),
        ]
        if let country = localeCountry {
            body["country"] = country
        }
        // Identity Foundation Phase 12 — optional web-to-mobile handoff token.
        // Does NOT replace attribution_code (that's a separate flow via
        // attributeInstall/sendAttribution); backend validates this value
        // server-side before linking the install to a web_visit row.
        if let webClickId {
            body["attribr_web_click_id"] = webClickId
        }

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
            // Clear every local persistence layer so this device cannot be
            // matched to the deleted server record on next launch.
            InstallInstance.reset()                                              // backup-excluded install UUID file (+ legacy UserDefaults copy)
            deviceId.clearPersistedHash()                                        // iCloud KV + in-memory device hash
            UserDefaults.standard.removeObject(forKey: "attribr.lastSeenAt")    // retention clock
            queue.clear()                                                         // pending queued events
            log.info("deleteAllData: server confirmed — all local state cleared")
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
        originalTransactionId: String?,
        store: String
    ) async {
        let deviceHash = deviceId.hash()
        let appId = Bundle.main.bundleIdentifier ?? "unknown"

        var body: [String: Any] = [
            "app_id": appId,
            "device_hash": deviceHash,
            "product_id": productId,
            "event_type": eventType,
            "currency": currency,
            "store": store
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
        // Coalesce overlapping flushes — see `isFlushing` doc comment. A skipped
        // caller loses nothing: the in-flight flush is already draining the
        // same FIFO snapshot, and anything it fails on stays queued for next time.
        guard !isFlushing else {
            log.debug("flushQueue skipped — a flush is already in flight")
            return
        }
        isFlushing = true
        defer { isFlushing = false }

        let pending = queue.peek()
        guard !pending.isEmpty else { return }
        log.info("Flushing \(pending.count) queued events")

        for event in pending {
            if event.attempts >= EventQueue.maxAttempts {
                queue.remove(id: event.id)
                log.error("Evicting undeliverable event after \(EventQueue.maxAttempts) attempts: \(event.kind.rawValue)")
                continue
            }

            let path: String
            let method: String
            switch event.kind {
            case .track, .event:   path = "attribr-track"; method = "POST"
            case .attribute:       path = "attribr-attribute"; method = "POST"
            case .delete:          path = "attribr-delete-user-data"; method = "DELETE"
            case .adRevenue:       path = "attribr-ad-revenue"; method = "POST"
            case .subscriptionEvent: path = "attribr-subscription-event"; method = "POST"
            case .revenue:         path = "attribr-revenue"; method = "POST"
            // Absolute URL — lives on the dashboard host, not config.baseURL.
            // NetworkClient detects the http(s) prefix and uses it directly.
            case .revenueDiscovery: path = AttribrEndpoints.revenueDiscovery; method = "POST"
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

# Attribr Swift SDK

Install attribution for iOS apps. Zero dependencies. Zero rejection risk. 3 lines of code.

## Installation (Swift Package Manager)

**Recommended (from v1.4.1):** In Xcode, **File > Add Package Dependencies**, enter:

```
https://github.com/mrvltechnologies/attribr-ios
```

and select **Up to Next Major Version** starting at `1.4.1`. Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/mrvltechnologies/attribr-ios", from: "1.4.1")
]
```

**Temporary fallback (pre-tag only):** if you need to integrate before a tag is available, pin to
an exact commit instead of a version — this is **not** a recommended production pattern, since it
does not track security or bug-fix updates automatically:

```swift
dependencies: [
    .package(url: "https://github.com/mrvltechnologies/attribr-ios", revision: "<commit-sha>")
]
```

## Quick Start

```swift
import Attribr

// In App.init(), before any other Attribr call:
Attribr.initialize(apiKey: "attr_live_xxx")   // from your Attribr dashboard — see "API Key" below
Attribr.setConsent(.granted)                  // call after your GDPR/consent banner resolves

// In your root view's .active scene-phase handler:
Attribr.trackLaunch()
```

No AASA file. No URL scheme. No IDFA. Ships with `PrivacyInfo.xcprivacy` included. The SDK sends
**no network requests at all** until `setConsent(.granted)` is called.

## Concurrency

Attribr's entire public API is **`@MainActor`-isolated**. Calling it directly from SwiftUI view
bodies/lifecycle methods, `AppDelegate` callbacks, or any other main-actor context works with no
extra annotation — those already run on the main actor. Calling from an `async` context that isn't
already on the main actor also works — Swift inserts an implicit hop.

**If you wrap Attribr calls in your own type**, mark that type (or the wrapping function)
`@MainActor` — otherwise Swift 6 rejects the call at compile time:

```swift
@MainActor
enum MyAttribrWrapper {
    static func start(apiKey: String) {
        Attribr.initialize(apiKey: apiKey)
        Attribr.setConsent(.granted)
        Attribr.trackLaunch()
    }
}
```

Calling any Attribr method before `initialize()` is a safe no-op (logged as an error), not a crash.

### Tracking events and revenue

```swift
Attribr.trackEvent(name: "level_complete", value: 5, currency: nil, metadata: ["level": "5"])

Attribr.trackRevenue(
    amount: 9.99,
    currency: "GBP",
    productId: "com.myapp.pro_monthly",
    transactionId: transaction.originalID.description,   // StoreKit 2 dedup key
    store: "apple",
    eventType: "initial_purchase"
)
```

### Web-to-mobile handoff (optional)

If your marketing site links into your app carrying an `attribr_web_click_id` query
parameter (minted by Attribr's own web-visit endpoint — this is not something you
generate yourself), pass it through on the next `trackLaunch()` call so the backend
can link the install back to that web visit. The backend verifies the token
server-side before making that link — the SDK does not assert anything on its own.

```swift
.onOpenURL { url in
    let clickId = DeepLinkHandler.extractWebClickId(from: url)
    Attribr.trackLaunch(webClickId: clickId)
    Attribr.handleDeepLink(url)   // unrelated — Attribr's own smart-link resolution, if you use it
}
```

`extractWebClickId(from:)` is a pure, synchronous helper — no network call, no domain
restriction (unlike `handleDeepLink`, which only resolves Attribr-owned smart-link
domains). It returns `nil` for any URL that doesn't carry a validly-shaped token, so
it's always safe to pass its result straight to `trackLaunch(webClickId:)`. Omitting
the parameter (or calling `trackLaunch()` with no arguments) behaves exactly as
before — this is purely additive.

### SKAdNetwork conversion value

```swift
// Real signature — NOT SKAdNetwork's own updateConversionValue(_:) API.
Attribr.registerSKAN()                                    // call once at launch, after consent
Attribr.updateConversionValue(eventName: "purchase", value: 4.99)
```

### Push token (uninstall detection)

```swift
// AppDelegate.application(_:didRegisterForRemoteNotificationsWithDeviceToken:)
Attribr.registerPushToken(deviceToken)
```

### GDPR erasure

```swift
Attribr.deleteAllData { success in /* ... */ }
```

## API Key Setup

Get your API key from your [attribr.dev](https://attribr.dev) dashboard. Keys are prefixed
`attr_live_` (production) or `attr_test_` (sandbox/dev) followed by a random secret — 50
characters total.

**Always generate a Client key (`sdk_ingest` scope) for `apiKey` — never a Full key.** This SDK
ships the key inside your app's compiled binary; while it isn't plaintext-extractable the way a
JS bundle is, it's still not a secure secret store, so treat it the same way. A Client key can
only submit ingest events (launch/event/revenue/attribution) — it cannot read install, revenue,
cohort, retention, or source data from your Attribr dashboard even if extracted. A Full key
embedded here would let anyone who extracts it read your entire dashboard. See `SECURITY.md`.

Treat the key as a secret regardless of scope: don't commit it to source control or paste it into
logs, crash reports, or chat. Store it in an untracked config (e.g. an `.xcconfig` file excluded
from git, or a build-time environment variable), not hardcoded in a committed source file. Free
tier: 1,000 installs/month.

## Supported Scope

**Tier 1 (this package):** `trackLaunch`, `trackEvent`, `trackRevenue`, `attributeInstall`,
`deleteAllData`, deep link handling — pure REST client behaviour, no OS-level entitlements beyond
what StoreKit/UNUserNotificationCenter already require of your app.

**Tier 2 (also in this package, native-only):** SKAdNetwork conversion values
(`registerSKAN`/`updateConversionValue`), push-token registration for uninstall detection
(`registerPushToken`), StoreKit 2 transaction reporting with `AppAccountTokenProvider` — these
have no equivalent in the RN/Expo package (`@mrvltechnologies/attribr-react-native`), which is
JS-only with no native module. If you need these capabilities, use this Swift package (or the
Kotlin equivalent for Android), not the RN wrapper.

**Not covered by this package:** Android is a separate package (`sdk/kotlin`); there is no Web
SDK equivalent to any of the above — `attribr-web.js` is a narrower page-visit/click pixel, not
a general client SDK, and does not have `trackEvent`/`trackRevenue`/`attributeInstall`.

## Privacy / Data Flow

- The SDK never reads or stores IDFA, email, name, or location.
- Device identity is a `SHA-256` hash derived from `IdentifierForVendor` — never the raw
  identifier, never sent in reversible form.
- Nothing is sent over the network until `setConsent(.granted)` is called; events queued before
  consent is granted are held locally and flushed once consent is set.
- Data is processed in the EU (Supabase `eu-west-1`).
- `PrivacyInfo.xcprivacy` is bundled and declares the SDK's data-collection categories for App
  Store submission — no extra Xcode configuration needed.

## Requirements

- iOS 15+ deployment target (some optional APIs, e.g. StoreKit 2 transaction reporting, require
  iOS 16+/macOS 13+ and degrade gracefully below that)
- **Swift 6.0 toolchain (Xcode 16+)** — the SDK uses Swift 6 language-mode concurrency features
- Zero third-party dependencies

## Docs

Full integration guide: [attribr.dev/docs](https://attribr.dev/docs)

## License

MIT License. Copyright 2026 MRVL Technologies.

# Attribr Swift SDK — Changelog

## Unreleased — Fix: consent is enforced at dispatch (attribr-ios#1)

Not tagged. Behaviour change for host apps:
- `NetworkClient` re-checks consent immediately before **every** request attempt, including retries after back-off. Only the
  GDPR deletion endpoint (`attribr-delete-user-data`) may be sent without granted consent.
- `flushQueue()` re-checks consent before **each** queued event; a consent-blocked send is not counted as a delivery failure.
- A send blocked by withdrawal is **dropped**, not re-queued.
- `setConsent(.revoked)`, or any move from `.granted` to another state (e.g. a host resetting a legacy implied grant to
  `.unknown`), **discards the undelivered queue** except pending deletion requests. Already-delivered data is unaffected.
  Events parked while `.unknown` still flush after a first explicit `.granted`.
- `RevenueDiscoveryReporter` (PR review): its direct intake request now re-checks consent before **every** attempt
  including the retry after back-off; it no longer re-queues after withdrawal (`enqueueRevenueDiscovery` refuses when
  `.revoked`, and refuses a post-failure re-queue unless `.granted`; first-time parking while `.unknown` is unchanged).
  Debug-only `tracking_status`/`duplicate` console logging of the response was dropped in the refactor.
- Residual: a request already on the wire when consent is withdrawn cannot be recalled.

## Unreleased — Commercial Truth Phase 2A: RevenueDiscoveryLifecycle

Not tagged until StoreKit lifecycle QA is accepted.

- **`RevenueDiscoveryLifecycle.start(reconcileOnLaunch:appAccountToken:)`** (iOS 16+/macOS 13+) — one call
  after `Attribr.initialize` reports verified StoreKit transactions from `Transaction.updates` (renewals,
  refunds, off-app purchases) and, once per 24h, from `Transaction.currentEntitlements` (restores and
  pre-reporter subscribers). Evidence only — never revenue authority. ≤50 transactions per launch,
  ≤3 reports per transaction id, deterministic `sdk_event_id = storekit:<id>`, existing consent gate and
  install-instance hash. Never creates or repurposes an `appAccountToken`.
- **Fix:** `RevenueDiscoveryReporter` labelled StoreKit-testing (`.xcode`) transactions `environment:
  "production"`; they are now `"sandbox"`. Unknown future environments also fail away from production.
- `QA/StoreKitHarness` — hosted-test harness (StoreKitTest needs an app host).

## Unreleased — Identity Foundation Phase 12: web-to-mobile handoff

Not tagged/published — no release created this phase.

- **`Attribr.trackLaunch(webClickId: String? = nil)`** — new optional parameter,
  default `nil`. Existing zero-argument call sites compile and behave identically.
  When supplied and non-blank, the value is sent to `attribr-track` as
  `attribr_web_click_id`; the backend validates it server-side before linking the
  install to the originating web visit. Does not replace `attribution_code` (a
  separate field/flow via `attributeInstall`); does not touch revenue payloads,
  `deleteAllData`, or SKAN/AppAccountToken behaviour.
- **`DeepLinkHandler.extractWebClickId(from: URL) -> String?`** — new pure,
  `nonisolated` static helper. Extracts and validates the `attribr_web_click_id`
  query parameter (`^awc_[0-9a-f]{24}$`) from a customer's own launch URL. Separate
  from, and does not modify, the existing `handle(_:)`/smart-link resolution
  (`attribr.dev/l/{code}`, `attribr://`, `?attribr_link=`) — those remain
  domain-restricted to `allowedLinkDomains`; this helper is not, since it reads
  the customer's own URL rather than an Attribr-owned one.
- Added `Tests/AttribrTests/WebClickIdHandoffTests.swift`: extraction-helper
  coverage (valid/missing/empty/repeated/malformed/wrong-length/wrong-case
  tokens, unrelated smart-link params) and end-to-end `trackLaunch` payload
  coverage (field included/omitted/blank, zero-arg backward compatibility).
- Added `Attribr.initializeForTesting(apiKey:config:session:)`, an `internal`
  (not public) test-only seam mirroring the existing `resetForTesting()` hook —
  lets tests inject a stubbed `URLSession` to assert on real request payloads
  without live network access. Not reachable from outside the module.
- No public API removed or renamed. No changes to revenue, ad-revenue, push-token,
  or subscription-event payloads/tests.

## 1.4.1 — 2026-08-27 — Consumer compile hardening

Prompted by an external developer's report: their own `nonisolated` Swift wrapper around Attribr
failed to compile under Swift 6 (the SDK is `@MainActor`-isolated), and they separately noted that
`setConsent()` before `initialize()` triggers a hard crash via `preconditionFailure`.

- **`setConsent()` and `registerSKAN()` no longer crash if called before `initialize()`.** Both
  previously called `preconditionFailure`, which aborts the host app. Both are now a safe no-op,
  logged as an error via the SDK's internal logger. No other method changes behavior — every other
  public method already no-op'd safely on a missing singleton. Consent semantics are unchanged: no
  network before `setConsent(.granted)`, no silent grant, no state mutation on a pre-init no-op
  call.
- **Documented (not changed) the SDK's actor isolation.** The public API is intentionally
  `@MainActor` — this was already true in v1.4.0 and earlier; it was just undocumented, and the
  doc comment's "safe to call from any thread" claim was actively misleading (true only for async
  callers; false for a synchronous call from a non-main-actor context, which is exactly what fails
  to compile under Swift 6). `Attribr.swift`'s header doc comment and `README.md` now both state
  the isolation explicitly and show the `@MainActor`-wrapper pattern consumers need. No isolation
  behavior was relaxed or changed — this is a documentation fix, not a concurrency redesign.
- Added `Examples/ConsumerCompileCheck/`, a small local-path SPM package that compiles a correct
  `@MainActor` consumer wrapper against this source tree on every `swift build` run in that
  directory — a standing regression check for the exact failure mode this release fixes.
- Added `SetConsentCrashTests.swift`: pre-init no-crash coverage for both fixed methods, a
  normal-path regression test (`initialize` → `setConsent` unchanged), and a test confirming
  tracking calls remain no-ops before consent is granted.
- No attribution semantics changed. No public API removed or renamed.

## Unreleased — Release hardening for first public GitHub tag

- Removed stale "STUB FILE" placeholder header from `Package.swift`; reconciled its
  platform-target and import-list comments with the actual source (they previously
  claimed iOS 18+ and named frameworks the SDK doesn't use).
- Corrected `README.md`'s `updateConversionValue` example to the SDK's real signature
  (`updateConversionValue(eventName: String, value: Double? = nil)`) and its Swift-tooling
  requirement (Swift 6.0+ / Xcode 16+, not 5.9+).
- Added README sections: privacy/data-flow explanation, API-key handling guidance, SKAN/push-
  token/GDPR-erasure usage examples, and a temporary commit-pin install fallback (explicitly
  marked non-production) for use ahead of the first tag being published.
- Fixed `Attribr.podspec`'s `s.source` — it pointed at an unrelated GitHub repository instead of
  this SDK's actual remote.
- No public API changes. No runtime/behavioural changes.

## 1.4.0 — 2026-07-03 (Sprint 13)

- **App-local install-instance ID.** The SDK now generates a random UUID on first launch, persists it in the app's own `UserDefaults.standard` (key `attribr.installInstanceId`), and sends its SHA-256 hex digest to Attribr on every `trackLaunch()` in the new field `sdk_install_instance_id_hash`.
- The **raw UUID never leaves the device** — only the hash is on the wire.
- Enables Attribr's `reinstall_candidate` classification on the second installation of the app on the same device. On iOS, `UserDefaults` is wiped on uninstall, so a reinstall generates a fresh UUID → a differing hash arrives at the backend.
- **Not an advertising ID, not IDFV, not IDFA, not device name, not vendor identifier, not fingerprinting.**
- **Keychain deliberately not used.** Keychain can survive uninstall on iOS in some configurations, which would defeat reinstall detection. UserDefaults gives exactly the "reset-on-uninstall" semantics Sprint 13 wants.
- `deleteAllData(completion:)` now also resets the local install-instance so the user's GDPR-style request is honoured on-device.
- Backwards-compatible: absent field means the backend falls back to the Sprint 12 `returning_launch` path via `(app_id, device_hash)` alone.
- No public API changes. `initialize`, `trackLaunch`, `setConsent`, `attributeInstall`, `trackEvent`, `trackRevenue`, `trackAdRevenue`, `trackSubscriptionEvent`, `registerPushToken`, `deleteAllData`, `handleDeepLink`, `registerSKAN`, `updateConversionValue` all unchanged in signature.

## 1.0.0 — 2026-04-11 (Sprint 3)

- Initial published SDK.
- `Attribr.initialize(apiKey:)`, `trackLaunch`, `setConsent`, `attributeInstall`, `trackEvent`, `trackRevenue`, `trackSubscriptionEvent`, `registerPushToken`, `handleDeepLink`, `registerSKAN`.
- Device-hash-based install identification via `IdentifierForVendor` → SHA-256.
- Consent-gated event queue with retry.

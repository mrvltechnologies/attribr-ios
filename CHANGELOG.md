# Attribr Swift SDK — Changelog

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

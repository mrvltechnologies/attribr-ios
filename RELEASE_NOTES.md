# Attribr Swift SDK v1.4.0

**First public GitHub release.** `CHANGELOG.md` documents the SDK's history back to its original
internal 1.0.0 (Sprint 3); this is the first version actually published as a pushed git tag on
`origin`, making SPM's `from: "1.4.0"`-style version pinning work for external integrators for the
first time. It is not the SDK's first version — it is the first one released.

### Highlights

- Install attribution via a `SHA-256(IdentifierForVendor)` device hash — no IDFA, no AASA file, no
  URL scheme required.
- GDPR-gated: zero network requests before `setConsent(.granted)`.
- App-local install-instance tracking for reinstall detection (Sprint 13).
- SKAdNetwork conversion-value reporting (`registerSKAN()` / `updateConversionValue`).
- Revenue, ad-revenue, and subscription-event tracking with server-side dedup by transaction ID.
- Push-token registration for uninstall detection.
- `PrivacyInfo.xcprivacy` included — no manual App Store privacy manifest configuration needed.
- Zero third-party dependencies.
- MIT licensed.

### Requirements

- iOS 15+ deployment target
- Swift 6.0 toolchain (Xcode 16+)

### Installation

```swift
dependencies: [
    .package(url: "https://github.com/mrvltechnologies/attribr-ios", from: "1.4.0")
]
```

### Known limitations

- No React Native wrapper yet — native Swift/Kotlin only. Minimum future scope (initialize, track
  launch/install, track event/conversion, update conversion value, track revenue, set consent, set
  push token, GDPR delete) is documented in `BACKLOG.md`. Not a blocker for this release; is a
  blocker for RN app integration.
- CocoaPods (`Attribr.podspec`) is present but not yet verified against a real `pod install` — SPM
  is the primary, tested distribution path.

### License

MIT License. Copyright 2026 MRVL Technologies.

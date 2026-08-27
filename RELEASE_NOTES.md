# Draft GitHub Release Notes

> **Not yet published.** Tag version pending user decision — see note below.

## Version note

The release-hardening brief for this session requested a `v1.0.0` tag. That number does not match
this repo's actual state: `CHANGELOG.md` and `Attribr.podspec` both already describe the current
code as **1.4.0** (Sprint 13's install-instance work, already SDK-versioned past 1.0.0 internally).
Tagging today's commit `v1.0.0` would misrepresent it as the *first* version when it is in fact the
fifth documented revision. Recommend tagging **`v1.4.0`** instead — the first tag actually *pushed*
to GitHub, matching the version already recorded everywhere else in the repo. Swap `v1.4.0` for
`v1.0.0` below if the user prefers to renumber from scratch instead.

---

## Attribr Swift SDK v1.4.0

First public GitHub release. Local development had already reached this point across several
internal sprints (see `CHANGELOG.md` for full history back to the original 1.0.0); this is simply
the first version actually published as a git tag on `origin`, making SPM's `from: "1.0.0"` /
`from: "1.4.0"`-style version pinning work for external integrators for the first time.

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

- No React Native wrapper yet — native Swift/Kotlin only. See `BACKLOG.md` for planned scope.
- CocoaPods (`Attribr.podspec`) is present but not yet verified against a real `pod install` —
  SPM is the primary, tested distribution path.

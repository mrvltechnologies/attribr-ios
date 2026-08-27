Hi — following up on the release-readiness review, here's where things stand:

- **Swift SDK v1.4.0 is released** and version-pinnable via SwiftPM:
  `.package(url: "https://github.com/mrvltechnologies/attribr-ios", from: "1.4.0")`.
  GitHub release: https://github.com/mrvltechnologies/attribr-ios/releases/tag/v1.4.0
- `Package.swift` and the README have been corrected — the stale "STUB FILE" header is gone, the
  `updateConversionValue` example now matches the SDK's real signature
  (`updateConversionValue(eventName:value:)`), and the Swift-tooling requirement is now stated
  correctly (Swift 6.0 / Xcode 16+, not 5.9+).
- **Clean SwiftPM resolution has been verified**: from a fresh directory (no local checkout), a
  sample package resolving `from: "1.4.0"` pins `Package.resolved` to the actual pushed commit and
  builds successfully.
- **CocoaPods is now verified**, not just fixed-and-assumed: `pod lib lint`, `pod spec lint` against
  the real published tag, and a full `pod install` + `xcodebuild` in a clean sample app all pass
  against `https://github.com/mrvltechnologies/attribr-ios.git`, tag `v1.4.0`. One real bug was
  found and fixed in the process — the podspec's internal tag reference didn't match the actual
  pushed git tag name (`1.4.0` vs. `v1.4.0`); that's corrected now.
- **React Native wrapper is not yet available.** There is no RN/Expo SDK today — native Swift/Kotlin
  only. A concrete implementation plan exists (repo structure, API surface, native bridge
  architecture) but nothing has been built; treat RN as unavailable until we ship it.
- **Key rotation is blocked pending information from you.** The repo itself is clean — a full git
  history scan found no live key ever committed — but if a specific `attr_live_...` key was
  visible in a chat, screenshot, or log on your end, we need the key's prefix (the first ~14
  non-secret characters, e.g. `attr_live_ab12cd34`) or the account it belongs to in order to revoke
  and reissue it. Send that over and we'll rotate it the same day.
- **Where Attribr is actually running today:** it's used across every app in MRVL Technologies'
  own portfolio, and those apps have passed Apple App Review with the SDK included — that's not
  the same as Apple having reviewed or certified Attribr itself, and we're not claiming that.
  `v1.4.0` is the SDK's *first public GitHub release*, so outside of MRVL's own apps, public/
  third-party adoption is genuinely early — you'd be among the first external integrators, not
  joining an established base of outside users.

**Update — v1.4.1, addressing your @MainActor and setConsent findings:**
- **Confirmed and fixed the compile issue.** We reproduced it exactly: a `nonisolated` wrapper
  calling `Attribr.initialize`/`setConsent`/`trackLaunch` fails to compile under Swift 6 with
  `call to main actor-isolated static method ... in a synchronous nonisolated context` — this is
  correct compiler behavior, not an SDK bug. The SDK's public API is intentionally `@MainActor`;
  we hadn't documented that clearly, and the old doc comment's "safe to call from any thread" claim
  was actively misleading for a synchronous non-main-actor caller like yours. `README.md` now says
  this explicitly and shows the fix you already found yourself: mark your wrapper `@MainActor`.
  We did not relax or remove the isolation — your workaround is the correct, intended pattern.
- **Fixed the `setConsent()` hard crash you flagged**, and found the same issue in `registerSKAN()`.
  Both previously called `preconditionFailure` if invoked before `initialize()`; both are now a
  safe no-op (logged as an error) instead. Your own `isConfigured` guard was masking this for you,
  but any consumer without an equivalent guard would have crashed — good catch.
- New: `Examples/ConsumerCompileCheck/` in the repo compiles a correct `@MainActor` wrapper against
  the SDK on every build, so this specific failure mode has a standing regression check.
- Released as `v1.4.1`: `.package(url: "https://github.com/mrvltechnologies/attribr-ios", from: "1.4.1")`.
  GitHub release: https://github.com/mrvltechnologies/attribr-ios/releases/tag/v1.4.1
- Re-verified clean SwiftPM resolution **and compile** from the real `v1.4.1` tag in a fresh
  directory (not just dependency resolution this time — an actual `swift build`).

Thanks again for the thorough review — it caught real gaps, twice now.

# Attribr Swift SDK v1.4.1

**Consumer compile hardening.** A patch release addressing two integration-friction issues an
external developer hit while evaluating v1.4.0 for production/TestFlight use. No attribution
semantics changed; no public API removed or renamed. See `CHANGELOG.md` for full history.

### What changed

- **Fixed a hard crash:** `setConsent()` and `registerSKAN()` called before `initialize()` used to
  crash the host app via `preconditionFailure`. Both are now a safe no-op (logged as an error).
  Every other public method already handled this safely — these two were the exceptions.
- **Documented the SDK's actor isolation, which was true but undocumented (and previously
  misdescribed):** Attribr's public API is `@MainActor`-isolated. Calling it from a `nonisolated`
  wrapper type fails to compile under Swift 6 strict concurrency. `README.md` and the SDK's own doc
  comments now say this explicitly and show the fix — mark your wrapper `@MainActor`:

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
- Added `Examples/ConsumerCompileCheck/` — a small local-path SPM package that compiles a correct
  `@MainActor` consumer against the SDK source on every build, as a standing regression check.
- Added regression tests for both fixes (pre-init no-crash, normal-path unchanged, no-network-
  before-consent).

### Verified before this release

- Clean SwiftPM resolution **and compile** from a fresh consumer package pointed at the real
  `v1.4.1` GitHub tag (not just the earlier `v1.4.0` resolution check) — including a build that
  reproduces the original `@MainActor` compile error against `v1.4.0`, then confirms the fix.
- Full test suite passing (64 tests, including 5 new).

### Requirements (unchanged from v1.4.0)

- iOS 15+ deployment target
- Swift 6.0 toolchain (Xcode 16+)

### Installation

```swift
dependencies: [
    .package(url: "https://github.com/mrvltechnologies/attribr-ios", from: "1.4.1")
]
```

### Known limitations (unchanged from v1.4.0)

- No React Native wrapper yet — native Swift/Kotlin only.
- CocoaPods (`Attribr.podspec`) verified via `pod lib lint`/`pod spec lint`/a real `pod install` in
  a prior session; SPM remains the primary, most-exercised distribution path.

### License

MIT License. Copyright 2026 MRVL Technologies.

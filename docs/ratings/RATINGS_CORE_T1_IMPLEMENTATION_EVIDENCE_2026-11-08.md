# MRVL Ratings Engine — T1 shared eligibility core

**Date:** 8 November 2026  
**Status:** T1 SOURCE COMMITTED; ISOLATED REGRESSION PASS; FULL iOS BUILD NOT RUN; **NO RELEASE OR CLEANR BEHAVIOUR CHANGE**.

**Repository:** mrvltechnologies/attribr-ios  
**Branch:** `feature/ratings-core-t1-20261108`  
**Baseline:** `ba5b3bb551ade2f9aa5e87bc5758eed9b42dc340`  
**Architecture:** [Attribr Ratings design](https://github.com/mrvltechnologies/attribr-dashboard/blob/86879878587a4d02aebfa50be41526d088b8bfe0/docs/architecture/MRVL_RATINGS_ENGINE_DESIGN_2026-11-08.md)

## Implementation

- `Sources/Attribr/RatingsEligibility.swift`: Foundation-only, non-network, non-StoreKit, cross-product pure eligibility reducer and local-state transition helpers.
- `Tests/AttribrTests/RatingsEligibilityTests.swift`: 13 XCTest cases covering Cleanr legacy thresholds, shadow mode, local cooldown, app/screen safety, record dedupe, clock rollback, configuration validation and stronger optional session, age, failure and crash suppression.
- The pure module has no SDK telemetry invocation, persistent UserDefaults adapter, iOS native review invocation, image processing or app-specific event emitter.
- `RatingsPolicy.cleanrLegacyParity` encodes the existing Cleanr 3-confirmed-win / 90-calendar-day / once-per-launch policy in **SHADOW** mode. A computed eligibility decision in shadow mode **cannot** invoke a native review request.
- The generic policy supports application-specific rules; it is not assumed to automatically recognise Cleanr's value. A future Cleanr adapter must supply confirmed save receipts, UI context and historical local-state fields.
- `RatingsEligibility.markNativeRequestAttempt` is a pure state transition; the future adapter must commit state before calling the native platform API. No native call exists here.
- `RatingsLocalState.recentReceiptIDs` retains only 64 ephemeral local UUIDs for bounded dedupe. This is a bounded local window, not a permanent global deduplication ledger; batch and session integration should preserve the operation IDs until consumed and must not mistake a photo filename/hash for an ID.

## Executed local evidence

The exact GitHub source/test blobs were compared with `git hash-object` on locally compiled files:

| Artifact | Verified Git blob SHA |
|---|---|
| Source | `0b9f4effdab862bc23415f8765218ef44bab6126` |
| Tests | `c41b9983a2424d984e07178d079b5c5d35038500` |

Because the full private repository cannot be cloned from this runtime (`git ls-remote` cannot resolve github.com), the two files were exercised in a **disposable minimal Swift 6.0 package** with the same `Attribr` module and XCTest imports. Swift toolchain: Swift 6.2.1, Linux x86_64. The actual iOS SDK is a zero-dependency Swift package targeting iOS 15+ and is not otherwise modified.

```bash
swift test --jobs 2 --filter RatingsEligibilityTests
# PASS — executed 13 tests, 0 failures.
```

**Mutation checks on disposable source copies:** 3/3 intentionally defective variants caused nonzero test exits, independently exposing (1) shadow incorrectly allowing native requests, (2) Cleanr threshold incorrectly reduced from 3 to 2 wins, and (3) 90-day cooldown incorrectly reduced to 89 days. Original source restored and rerun: 13/13 PASS.

**Limits:** This does NOT prove that the complete `attribr-ios` package, Cleanr iOS application, integration tests or an Apple device build pass. No Xcode/iOS simulator is available in this Linux runtime. Source equality and isolated XCTest are the only executed evidence. No hosted or paid CI triggered.

## Cleanr Customer 0 next tranche (T2), not yet implemented

1. Pin the real Cleanr release source, perform an exhaustive review-prompt call-site audit, compare saves against `PhotoSaver` confirmation callbacks and audit batch semantics.
2. Confirm lawful basis and disclosure before adding any `ratings.*` telemetry. `CleanrApp.init` currently invokes `Attribr.setConsent(.granted)`; that fact is **not** itself authorisation to collect a new telemetry category.
3. Add a local Cleanr `RatingsShadowAdapter` with configuration fixed to `RatingsPolicy.cleanrLegacyParity`. It may compute local eligibility and optionally record locally without transmitting anything at first; keep the legacy `ReviewPrompter` the **only** StoreKit invoker.
4. Migrate/copy legacy `mrvl.reviewPrompter.winCount`, `lastAsked` and `askedThisLaunch` for shadow comparison, never reset the existing cooldown. Align calendar semantics with Cleanr's old `Calendar.current` calculation.
5. Prove on-device: no additional StoreKit invocation, no extra save latency, no prompt on onboarding/paywall, and unchanged 3-win / 90-day cadence. Test cold start, rapid callbacks, reentrancy and blocked network/consent.
6. If privacy review later permits analytics, send controlled, schema-versioned `ratings.*` events through existing `FunnelAnalytics` / `Attribr.trackEvent` (max 10 metadata keys) and verify backend `attribr_raw_events.event_type = 'custom'`, not the dashboard helper's unsupported raw event taxonomy.
7. No remote configuration, dashboard migration, Cleanr App Store build or portfolio rollout without further owner/Berea release gates.

## Release constraints

Do NOT merge to SDK main, publish the package, modify Cleanr, deploy any Supabase/Vercel component, change Apple prompt cadence, collect new telemetry, or run paid CI merely from this tranche.

**Engineering verdict:** T1 is isolated-unit-test verified and ready for full iOS SDK + Berea review; T2 integration has not started. **Production release verdict: HOLD.**

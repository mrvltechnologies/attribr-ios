# MRVL Ratings Engine — SDK engineering completion / Claude macOS build handoff

**Date:** 8 November 2026
**State:** SDK SOURCE CANDIDATE PREPARED / FULL SDK BUILD AND NEW REGRESSIONS **NOT RUN** / NO PRODUCT ACTIVATION.
**Repository:** mrvltechnologies/attribr-ios
**Branch:** feature/ratings-engine-sdk-source-20261108
**Parent source:** feature/ratings-core-t1-20261108 at c3c96130366bbfbed8c85cd3a8f0fae005bd69b6
**Architecture:** https://github.com/mrvltechnologies/attribr-dashboard/blob/4cf6638a7a0b36a7efeb2cc97f3d4bccfac66546/docs/architecture/MRVL_RATINGS_ENGINE_DESIGN_2026-11-08.md
**Cleanr T2 candidate:** https://github.com/mrvltechnologies/cleanr-by-mrvl/tree/feature/ratings-shadow-cleanr-t2-20261108
**Independent gate:** https://github.com/mrvltechnologies/berea/issues/64

## 1. SDK engine source delivered

The source branch contains previous tested T1 pure Swift eligibility plus new:

- `Sources/Attribr/RatingsStateStore.swift`: app-scoped, versioned UserDefaults snapshot; local persisted wins, sessions, last native request and recent attempts, bounded receipt UUIDs, schema and corruption fail-closed checks. No new user identity or network.
- `Sources/Attribr/RatingsEngine.swift`: main-actor local session coordinator, one-time legacy import, confirmed-win dedupe, signal suppression, cooldown evaluation and a host-authorised native request handoff; per-launch and three-attempt / rolling-365-day guard. Persist request state **before** native API call. Defaults: shadow, active authorisation false. The engine cannot invoke StoreKit on its own.
- `Sources/Attribr/RatingsOpportunityScheduler.swift`: cancelable post-success delay (700ms minimum) and fresh UI safety check at the actual request moment. The product must retain the scheduler and cancel on editing, modal, paywall and background transitions.
- `Sources/Attribr/RatingsSwiftUIRequestBridge.swift`: iOS 16+ StoreKit RequestReviewAction wrapper to be passed from a SwiftUI view's requestReview environment value; returns attempted, not displayed. No native call before the product explicitly invokes its method.
- `Sources/Attribr/RatingsTelemetryContract.swift`: typed, closed event/moment/reason metadata, max 10 event fields, no raw text or PII. A payload is data only.
- `Sources/Attribr/RatingsAnalyticsForwarder.swift`: a strictly explicit product-disclosure AND analytics-consent gate, then forwards only to the existing Attribr.trackEvent path. No automatic telemetry.
- Existing `RatingsEligibility.swift`: pure reducer and Cleanr 3-win/90-day SHADOW parity policy, unchanged by this tranche.

**No SDK public APIs were removed.** The new engine is product-neutral except for an optional named Cleanr shadow-parity preset. The SDK retains zero new third-party dependencies.

## 2. Tests and evidence boundary

New source tests authored (not executed yet):
- `Tests/AttribrTests/RatingsEngineTests.swift`: 15 cases for shadow/active gating, state persistence before native request, failed storage, 3/365 cap, clock rollback, receipt dedupe, session counts, legacy import, bridge failure, background/failure suppression, JSON corruption and telemetry consent.
- `Tests/AttribrTests/RatingsOpportunitySchedulerTests.swift`: cancellation and current-foreground revalidation after delay.

Old evidence (executed in previous tranches, NOT a substitute for the new tests):
- T1 pure eligibility: 13/13 isolated Linux Swift tests, 3/3 policy mutants detected, exact T1 source/test blob identity previously verified.
- Cleanr T2 shadow: 8/8 isolated tests, 3/3 intentional defects detected, using simulated StoreKit and SDK interface.
- A new GitHub source readback/static invariant audit confirmed that only the optional iOS bridge imports StoreKit, default policy is non-requesting, active requests require separate host authorisation, annual limits and local persistence precede the OS callback, and there is no automatic telemetry transport.

**The new module/tests have NOT yet been typechecked or executed as the real complete Attribr Swift package.** Do not mark them PASS. Linux lacks the complete private repository checkout/Xcode device harness. The next reviewer MUST compile and run actual package tests on macOS.

## 3. Claude build-and-integration assignment

### Gate A — authenticate repo and source

1. Work from clean separate worktrees; verify canonical git status and branch heads.
2. Checkout feature/ratings-engine-sdk-source-20261108, preserve the original T1 commits, and read these files + design before changing any implementation.
3. Confirm that Package.swift includes Sources/Attribr and Tests/AttribrTests; confirm Swift 6 language-mode and platforms iOS 15/macOS 12 constraints.
4. Detect/correct Swift 6 isolation, actor, XCTest, SwiftUI/StoreKit availability or Foundation portability issues. Keep each fix minimal with a real regression test; never suppress diagnostics as a shortcut.
5. Verify T1's cleanrLegacyParity still makes no native request and default config remains inert.

### Gate B — real SDK build/test

On local macOS with installed Xcode:

```bash
swift package resolve
swift test --filter RatingsEligibilityTests
swift test --filter RatingsEngineTests
swift test --filter RatingsOpportunitySchedulerTests
swift test
```

Perform actual iOS simulator build with xcodebuild, selecting an available simulator, and validate the iOS 16+ RequestReviewAction bridge. On iOS 15, the bridge must remain unavailable without breaking SDK compilation. Run zero third-party dependency assertion, package privacy-manifest inclusion checks and the existing MRVL SDK build gate.

If any new test fails, fix source and tests on the isolated branch; log exact command, result, environment and commit. Run targeted mutation checks for shadow bypass, failed-store native invocation, cooldown rollback, legacy reset, annual cap, foreground stale request, analytics without consent.

### Gate C — Cleanr real SDK integration in QA-only worktree

1. Verify dependency chain: Cleanr packages/attribr symlink → local Attribr-by-MRVL sdk/swift Git submodule → canonical attribr-ios. Use a dedicated QA worktree and update *only that worktree's* submodule pointer to the validated SDK source commit.
2. Enable MRVL_RATINGS_CORE_T1 as a conditional compile flag **only for a QA variant**, not for the public build. Existing Cleanr ReviewPrompter remains the only native request owner in T2.
3. Verify all 11 legacy win sites retain their original success checks, and that batch/project saves are differentiated.
4. Run Xcode project generation if required, full Cleanr test suite and MRVL release/build gate; Simulator + connected iPhone if present. Confirm 3 wins, 90-calendar-day cooldown, one attempt/launch, forward scene, denied Photos, cancellation, project, batch, repeat Save, offline mode and no duplicate requests.
5. Verify the new SDK's local shadow eval can compute from actual Cleanr UserDefaults without writing or resetting existing prompt prefs. Telemetry remains OFF (the consent legal gate is unresolved).
6. Document current App Store live/build/QA version instead of relying on an old handoff.
7. Do not cut over to active native prompts or create a new production release simply because the QA build compiles.

### Gate D — release and assurance record

Produce a signed-off engineering evidence report with package SHA, toolchain, all executed test totals, simulator/physical-device evidence, test failures/corrections, zero additional native calls, retention of legacy keys, consent/privacy constraints, and remaining operational gates. Update Berea issue #64 for independent review.

**Safe scope:** local test builds, source patches, isolated branch commits and approved branch pushes without paid CI.
**Not authorised:** main merge, SDK tag/publication, TestFlight/App Store upload, production database/Stripe changes, secret rotation, new telemetry egress, active ratings rollout, paid GitHub CI.

## 4. Contracts and edge cases to inspect

- RatingsUserDefaultsStore uses best-effort UserDefaults persistence, not guaranteed fsync. A false-positive native call after crash could be possible if the platform delays flushing. Confirm acceptable reliability for ratings; consider a stronger atomic store only if empirical tests justify it.
- The SDK does not authenticate a product's success claim; app-specific integration is responsible for stable receipt UUID per single completed operation, especially in batch/duplicate callbacks. The local dedupe window is the last 64 receipts, not permanent lifetime deduplication.
- RatingsEngine defaults SHADOW / active requests not authorised, and the T2 Cleanr observer defaults sdkNotLinked unless the QA SDK/flag is explicitly enabled.
- Do not infer observed ratings or review identity. RequestReviewAction merely requests; Apple's OS controls presentation. Beta/TestFlight cannot be used to conclude the prompt would display.
- New telemetry is not automatically collected. Cleanr currently sets SDK consent on app init, which is NOT a new disclosure approval. Preserve no-new-egress until the product/privacy reviewer approves.
- Android / React Native are not built from this Swift SDK; they require a separate engine/adapter port using the documented portable contracts.
- The ratings dashboard/aggregate App Store ratings import and remote policy service remain later **T3/T5** work, not prerequisites for a local iOS SDK binary. Do not fabricate user-level star conversion.

## 5. Final engineering verdict (pre-Claude)

**T1 previously isolated-test PASS. T2 Cleanr source-only shadow integration previously isolated-test PASS. T3 SDK CORE SOURCE PREPARED, NEW REAL-PACKAGE TESTS NOT RUN.** No merge, production change, SDK tag, telemetry or native prompt change. Claude owns the actual Swift package/Xcode build and compatibility fixes; Berea owns independent assurance; owner controls release.

# Attribr Ratings Engine — Berea P1-001 remediation evidence and macOS handoff

**Date:** 9 November 2026  
**Issue:** Berea [#64](https://github.com/mrvltechnologies/berea/issues/64)  
**Canonical branch:** `feature/ratings-engine-sdk-source-20261108`  
**Initial implementation reviewed:** `69f41c2bc48ced6beb11241c6012888186c4b160`  
**Previous engineering evidence:** `151476c8245331739a694a9b3001e2bd5ee350f5`  
**Status:** P1-001 **source fix implemented and targeted reduced Swift reproduction passed**; full real-SDK regression, mutation and Xcode gates **NOT RUN** for the new commits. Do not independently certify this implementation yet.

## 1. Root cause (independently found by Berea)

Two RatingsEngine objects instantiated before either attempted a review could each cache a stale snapshot. Each later saved that snapshot directly and invoked the native bridge. Berea reproduced `a=true b=true nativeCalls=2 history=1 persistedWins=1`. The earlier test wrongly constructed engine B only after A had persisted.

## 2. Code correction

- `RatingsStateStore` now has a stable `ratingsCoordinationKey` with a default for existing reference-type conformers, using weak per-object identities that avoid recycled pointer collisions. `RatingsUserDefaultsStore` overrides it with a consistent key derived from its validated namespace. Distinct store handles for one namespace therefore coordinate.
- `RatingsEngine` reloads the authoritative store synchronously on the MainActor before beginning a session, recording a success, recording failure/crash evidence, evaluating eligibility and reserving a review. It no longer writes its constructor-time cached state over later writes by another engine.
- The engine refuses an unexpectedly missing/corrupt snapshot after its first successful write, instead of creating an empty history or losing cooldown. Both read and write failures are fail-closed for request invocation.
- A process-local namespace ledger has `pending` and `committed` states. `begin(namespace)` runs immediately before the synchronous save to prevent nested/reentrant callbacks from making a second reservation, even at `cooldownDays = 0`. A failed save abandons the pending reservation; successful persistence commits it **before** calling the native closure. No additional application-global enable switch was introduced.
- Legacy import reloads storage and refuses to overwrite a snapshot populated by another preconstructed engine. Original entitlement/identity/attribution code and the existing Attribr telemetry gate are unchanged.
- This establishes the within-one-app-process contract. It does NOT claim atomicity across separate iOS processes/extensions, nor physical crash/power-loss durability of UserDefaults; those remain explicit scope boundaries.

## 3. New tests authored (not yet executed against the real SDK)

`Tests/AttribrTests/RatingsCrossEngineCoordinationTests.swift`: 10 tests including:
1. Two preconstructed engines, same store, two wins and one native invocation.
2. Two separate UserDefaultsStore objects with the same namespace and zero-day cooldown.
3. No loss of win counters, receipts, last failure/crash timestamps, first seen, sessions, or attempt history.
4. Zero-day cooldown does not bypass one-per-process-launch.
5. Two schedulers on two independently constructed engines.
6. Persistence failure leads to zero native calls, and a subsequent valid retry can succeed.
7. Store read failure returns persistenceUnavailable and does not overwrite state.
8. Synchronous reentrancy from a store save callback is blocked by the pending reservation.
9. Preconstructed legacy import cannot erase an existing cooldown.
10. Reconstruction and simulated process restart correctly apply persisted cooldown/history.

A previously invalid failing-store test double was repaired to actually reload its successful writes, rather than return nil permanently.

The existing 50 Ratings tests remain in the branch. Two earlier baseline SDK Simulator failures remain separate; `DeviceIdentifierTests.testHashUsesKnownAlgorithm` now tests `computeHash(idfv: knownIDFV)` with an explicit platform-independent input. The AppAccountTokenProvider Keychain/unentitled Simulator issue has now received a narrowly scoped source hardening and test correction; it is **NOT YET MACOS/iOS-EXECUTED** and must not be misreported as green.

## 4. Mutation protection

`scripts/mutation-check-ratings.py` contains **35 specified mutants** (the original 25 plus 10 targeted additions). Cross-engine mutations cover bypassed namespace reservation, loss of pending/committed state, stale request/receipt/failure writes, lost session state, unstable UserDefaults namespace coordination, failed persistence, incorrect legacy import and failed storage reads.

Mutation patterns were inspected against the current source. **The mutation suite itself has NOT been executed for this SHA**. Non-compiling mutants must remain INVALID rather than being counted as killed.

## 5. Independently executed reduced Swift check (NOT a full SDK test)

A locally compiled Swift 6.2.1 **source-faithful reduced model** of fresh-state read/modify/write plus pending/committed namespace reservation was executed on Linux. It is a design-level regression check and NOT a substitute for running the committed production XCTest code.

~~~text
BEREA_P1_FIXED a=true b=false nativeCalls=1 history=1 persistedWins=2
ZERO_COOLDOWN nativeCalls=1
PERSIST_FAIL_CLOSED nativeCalls=1
SYNCHRONOUS_STORE_REENTRANCY nativeCalls=1
~~~

The new real-SDK tests were authored on GitHub. Linux in this chat does not have a checkout of the full private SDK or Xcode, and GitHub's network host is not resolvable from the isolated test container.

## 6. Mandatory macOS verification before Berea re-review

1. Checkout the exact latest source branch HEAD in a clean macOS worktree. Verify working tree clean and branch ancestry.
2. Run `swift package resolve`, `swift build`, `swift test --filter RatingsCrossEngineCoordinationTests`, `swift test --filter Ratings`, `swift test`, and repeated timezone tests (UTC, Europe/London, America/Los_Angeles, Pacific/Auckland, Asia/Kolkata).
3. Execute `python3 scripts/mutation-check-ratings.py` locally with no paid CI; confirm **all 35** mutants are actually caught, no invalid/pattern-missing/surviving mutants, and source files restored byte-for-byte. Fix any genuine failures and rerun.
4. Run `swift package diagnose-api-breaking-changes origin/main`. This must remain an additive release; do not change public SDK behavior silently.
5. Run actual iOS Simulator SDK build+tests and generic iOS device compile; check iOS 15 availability, iOS 16+ native bridge, privacy manifest, zero third-party dependencies. The full suite MUST honestly report the remaining Keychain test status.
6. Independently rerun Berea's P1 repro, this time using the real production engine, two preconstructed engines and both shared/in-same-namespace store variants. Include exact before/after call count and all persisted fields in evidence.
7. Preserve the existing Ratings shadow/consent/annual cap/clock rollback/persist-before-native protections; do not change Cleanr or activate Ratings telemetry.

## 7. Supply chain plan (P1-002, NOT performed)

- Previous canonical `Attribr-by-MRVL/main` `sdk/swift` pin: `cd21747024ac0fb2c7c1a46a1cc86081afe4d367` (rollback).
- Canonical parent main examined: `01b2c0fe2056da872af288d4003a5414f17c2fb6` at the time of this work.
- Proposed Ratings SDK SHA: **the eventual verified source commit on this branch**, to be fixed precisely after successful macOS repair/test and Berea signoff. Do not publish the draft/unverified SHA.
- Once independently verified, prepare an isolated draft release PR in `attribr-by-mrvl` updating ONLY the `sdk/swift` gitlink and documenting exact before/after SHAs, no production pin mutation.
- Clean-clone package resolution and Cleanr QA flag-ON build from committed immutable pins are **NOT VERIFIED**; do not claim reproducible release provenance yet.
- Sign/version/tag only through an approved SDK release process **after** P1-001 re-verification.

## 8. Explicit holds

- No main merge, SDK tag, publication, prod submodule change, Cleanr edit/deploy, TestFlight/App Store upload or paid CI.
- No ratings telemetry; Cleanr's unconditional `Attribr.setConsent(.granted)` is NOT a valid app-level approval for new Ratings analytics.
- Cleanr Customer 0 shadow integration remains Berea's CONDITIONAL PASS; no active StoreKit cutover.
- Keychain persistence and the two historical Simulator failures (both now have source/test corrections, neither re-executed), iOS physical device, UserDefaults crash durability and release-provenance clean-clone proof remain unverified.

**Final gate: NOT READY FOR BEREA RE-VERIFICATION — full real-SDK macOS/iOS tests and all 35 mutation runs have not yet been executed against the new source SHA.**

## 9. Additional source-level reliability hardening before Claude handoff

The P2-004 anonymous StoreKit account-token issue was also inspected and received a **small, separate SDK source correction**, not a change to the Ratings Engine contract:

- `Sources/Attribr/AppAccountTokenProvider.swift` now checks Security framework write status; updates an existing Keychain token in place rather than deleting it before a potentially failing insertion; reads back the actual stored UUID; serialises anonymous token acquisition with `NSLock`; and preserves one **in-memory-only** anonymous token for repeated calls if Keychain is unavailable. No UserDefaults fallback was added. A token returned in this exceptional path is **not guaranteed to survive an app relaunch or reinstall**, so a host must not treat this path as proof of refund-identity durability.
- `Tests/AttribrTests/AppAccountTokenProviderTests.swift` now separately checks repeated-call stability, actual persisted Keychain readback across a simulated new-process cache reset, and an observable `OSStatus` from the write helper. Only recognised Simulator-specific Security errors permit an explicit SKIP; unexpected write failures remain failures.
- This is **source authored, not compiled or executed** in this Linux environment. The previously red Simulator test must be independently run on a suitable entitled test host. A passing/appropriately skipped test must state whether Keychain durability is actually proved.
- The `DeviceIdentifierTests.testHashUsesKnownAlgorithm` test fix (known IDFV input) is also not yet executed under iOS.

These P2 changes should be reviewed independently of the P1 multi-engine fix, and must not be misreported as a green baseline before macOS/iOS testing.

## 10. Latest source checkpoint

Use **the latest branch HEAD**, not the original Ratings source SHA, for Claude's macOS verification. As of this document, no complete SDK package checkout, full new Ratings XCTest run, iOS Simulator execution, full mutation sweep or GitHub Actions verification has been performed in the present session. The branch is **NOT READY FOR BEREA RE-VERIFICATION** until those gates pass.

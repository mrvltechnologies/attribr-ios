# Ratings Engine SDK — macOS build, test and Cleanr integration evidence

**Date:** 8 November 2026 · **Role:** macOS SDK build engineer / independent integration tester
**Berea gate:** mrvltechnologies/berea issue #64 · **Handoff followed:** `RATINGS_ENGINE_SDK_BUILD_HANDOFF_2026-11-08.md`

Labels: **VERIFIED** (executed, evidence below) · **NOT TESTED** · **BLOCKED** · **NOT PERFORMED**.

## 0. Verdicts (kept deliberately separate)
| Gate | Verdict |
|---|---|
| **SDK BUILD PASS** | **PASS** — real Swift 6.3.2 build on macOS, iOS Simulator and generic iOS device; no API breakage; all new tests pass. |
| **CLEANR INTEGRATION PASS** | **PASS (Simulator, QA-only variant, real SDK)** — physical iPhone QA **NOT PERFORMED** (§7). Not a release build. |
| **PRODUCTION RELEASE APPROVAL** | **NOT GRANTED and NOT REQUESTED.** No merge, tag, publication, TestFlight/App Store upload, telemetry enablement, or active prompt rollout. |

## 1. Commits
* **SDK** `mrvltechnologies/attribr-ios`, branch `feature/ratings-engine-sdk-source-20261108`: start `599043e` → code commit **`69f41c2bc48ced6beb11241c6012888186c4b160`** (this evidence document is committed on top; its SHA is stated in the Berea submission).
* **Cleanr QA** `mrvltechnologies/cleanr-by-mrvl`, branch `qa/ratings-sdk-integration-20261108`, based on T2 `06978fe` → **`374040ae8572f6bf582f2110ad2d09c39a24cf14`** (+ `e28aa5a` Xcode project fix). The QA-only repointing of `packages/attribr` at the SDK worktree is **intentionally not committed**.
* Environment: Xcode 26.5 (17F42), Apple Swift 6.3.2, Intel (x86_64) macOS host, Simulator iPhone 16 Pro / iOS 26.5. No iOS 15/16 simulator runtime is installed on this Mac.

## 2. SDK — build and compatibility (VERIFIED)
| Check | Result |
|---|---|
| `swift package resolve` / `swift build` (Swift 6 language mode) | clean, no new warnings |
| `xcodebuild build -scheme Attribr` iOS Simulator | BUILD SUCCEEDED |
| `xcodebuild build -scheme Attribr -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED |
| API breakage: `swift package diagnose-api-breaking-changes origin/main` | **"No breaking changes detected in Attribr"** |
| Diff vs `origin/main` | 7 source files, all **added**; `Package.swift`, `Attribr.swift`, `Configuration.swift`, `Consent.swift` untouched |
| Third-party dependencies | none (`.package(` absent — also asserted by a test) |
| Privacy manifest | `PrivacyInfo.xcprivacy` present in the built `Attribr_Attribr.bundle` for simulator and device |
| iOS-16 `RequestReviewAction` bridge | compiled under `#if os(iOS) && canImport(StoreKit) && canImport(SwiftUI)` + `@available(iOS 16.0, *)` on a package with an iOS 15 floor. **iOS 15/16 runtime behaviour: NOT TESTED** (no runtime installed). |

## 3. SDK — tests (VERIFIED)
* **macOS `swift test`: 139 tests, 0 failures** (baseline `origin/main` + 50 Ratings tests).
* **Ratings suites: 50/50 under TZ = UTC, Europe/London, America/Los_Angeles, Pacific/Auckland, Asia/Kolkata**: Eligibility 15, Engine 15, Scheduler 2, Telemetry egress 7, Duplicate-prompt 7, Static invariants 4 (= 50).
* **iOS Simulator `xcodebuild test`: 139 executed, 2 failures — both PRE-EXISTING and unrelated**: `AppAccountTokenProviderTests.test_anonymousMode_generatesAndPersistsAcrossCalls` and `DeviceIdentifierTests.testHashUsesKnownAlgorithm`. The identical two fail on a pristine `origin/main` worktree on the same simulator (verified) and pass on macOS. All Ratings tests pass on iOS. Not fixed here (outside the Ratings change; reported).
* Pre-existing iOS warnings at `DeviceIdentifier.swift:104` (main-actor property from a nonisolated context): file untouched by this branch.

## 4. Defects found and corrected
| # | Defect | Resolution |
|---|---|---|
| 1 | **New tests did not compile**: `RatingsEngineTests.swift:261` plus a systemic Swift 6 `SendingRisksDataRace` — tests captured the non-Sendable `XCTestCase` inside `MainActor.run` closures. | Test classes are `@MainActor`; closures removed. No diagnostics suppressed. |
| 2 | **`testCooldownBoundary` failed on real macOS** (passed in the earlier Linux/UTC run): `now − 90×86 400 s` is only 89 *calendar* days when a DST change lies inside the window (reproduced under Europe/London). Cleanr's legacy requester uses `Calendar.current.dateComponents([.day])`, which the engine mirrors, so **the engine is right and the test was wrong**. | Tests pin the calendar; added a **parity oracle** comparing the engine with the exact legacy formula across 5 timezones every 3 h over 200 days, plus an explicit DST test. |
| 3 | **Mutation testing exposed 4 test gaps** (telemetry allow-list untestable; no zero-delay scheduler test; cancel path; stacked scheduling). | Internal `RatingsTelemetryContract.isApprovedShape(name:metadata:)` overload (validator now directly testable; the public API is unchanged) and 4 new tests; one *equivalent* mutant replaced. |
| 4 | **Cleanr T2 did not build from its own commit**: `ReviewPrompter` references `RatingsShadowObserver`, which was absent from the committed `project.pbxproj`. | Regenerated with XcodeGen (+8 lines, Ratings files only), committed as `e28aa5a`. |
| 5 | A Cleanr mutant survived (observer persisting its own state): my persistence check was order-dependent. | Per-test baseline + final-state check on every test; mutant now killed. |

**Reported, NOT fixed (needs a decision / belongs elsewhere):**
* **T2 is based on a stale `main`** (2.0.9 build 6). **The live App Store version is 2.0.10** (released 2026-11-03, public iTunes lookup); `release/2.0.10-1` is 38 commits ahead of `main`. `ReviewPrompter.swift` is byte-identical on those lineages and each has the same number of `recordWinMoment` matches (12 = 11 call sites + the definition), so the legacy policy verified here applies to the live build — **but T2 conflicts in 3 view files** (`CleanrScanReviewView`, `MemoryRescueView`, `ScreenshotCleanerView`) when merged onto `release/2.0.10-1` and `release/2.0.11-2`. The eleven-site audit must be redone on the release lineage before any T2 release.
* Handoff §4: `UserDefaults` persistence is best-effort (no fsync); crash-before-flush false positives are **NOT TESTED empirically**.
* The two pre-existing iOS-Simulator SDK test failures above.

## 5. Mutation evidence (VERIFIED — every mutant must fail the tests)
* **SDK: 25/25 mutants killed** (`python3 scripts/mutation-check-ratings.py`, also reproducible by Berea): shadow bypass; active without host authorisation; failed storage still invoking native; native call before the reservation is saved; annual cap removed; clock-rollback guards removed; legacy import resetting the cooldown or overwriting state; background/editing/paywall no longer suppressing; once-per-launch removed; cooldown removed; Cleanr parity preset changed (3→2 wins, 90→30 days, shadow→active); analytics without consent or without product disclosure; telemetry validation removed or allow-list widened; scheduler minimum delay removed; cancellation ignored; stacked scheduling; session inflation. A runner bug was fixed so that a **non-compiling mutant can never count as a kill**.
* **Cleanr: 9/9 mutants killed** (`scripts/mutation-check-ratings-cleanr.py`): win threshold 3→2; cooldown 90→30; boundary off-by-one; launch guard removed; launch flag not recorded; observer overwriting `lastAsked`; observer persisting state; reducer policy disagreeing (30-day cooldown / 2 wins). Eight were killed on the first test revision; the ninth required strengthening the test (defect 5); the added assertions only tighten the earlier ones.

## 6. Cleanr integration on the Simulator (VERIFIED, QA-only variant)
Dependency chain: `packages/attribr` → SDK worktree at `69f41c2` (confirmed via the resolved package path in the build logs). The compile flag **`MRVL_RATINGS_CORE_T1` is enabled only by a command-line override** (`SWIFT_ACTIVE_COMPILATION_CONDITIONS`), never in `project.yml`; the public build configuration is unchanged.

| Run | Result |
|---|---|
| Flag OFF (public configuration), `build-for-testing` with the real SDK | TEST BUILD SUCCEEDED |
| Flag OFF, Cleanr unit suite | 0 XCTest failures. Two slow image-processing tests (`ObjectRemovalWindowTests`) hit the 120 s allowance **I** imposed; rerun with an adequate allowance **both passed (285 s / 297 s)**. First run reported 305 tests, 7 skipped (the cause of the difference from the later 660 was not investigated). |
| Flag ON (QA variant), `build-for-testing` | TEST BUILD SUCCEEDED (real `RatingsLocalState` / `RatingsOpportunity` / `RatingsEligibility.evaluate` API compiled) |
| **Flag ON, complete Cleanr unit suite** | **660 executed, 20 skipped, 0 failures, `** TEST SUCCEEDED **`** |
| Skips | all device-QA / diagnostic harnesses (`DeviceQAAutomationTests` ×9, `NoiseCalibration`, `PatchMatchMemoryMeasurement`, `QualityCorpus`, `RemovalEval`, …). None are Ratings tests. |
| Ratings contract + shadow tests, flag ON **and** OFF | 13/13 each, **none skipped** (the test host does have a foreground scene) |

**Behaviour preserved (VERIFIED by `RatingsLegacyBehaviourContractTests`, real `ReviewPrompter` + real `UserDefaults`, native requests counted via a `#if DEBUG`-only seam):**
* 3-win threshold: no request at 1–2 wins, exactly one on the third.
* 90-calendar-day cooldown: 89 days blocked, 90 allowed.
* At most **one** request per launch across 50 wins and every win source; not repeated on the next launch within cooldown.
* Batch, single-photo and project sources follow the same legacy policy.
* **84-combination differential grid** (7 cooldown ages × 6 win counts × launch flag): real requester == legacy formula, observer reports 0 native requests, and — with the real SDK linked — the shadow reducer **agrees with the legacy requester on every combination**.
* The shadow adds **no persisted state**: no new `UserDefaults` key beyond the three legacy keys (checked after every test) and none containing "ratings".
* Cleanr sources do not use `RatingsAnalyticsForwarder`, `RatingsEngine`, `RatingsSwiftUIRequestBridge` or `RatingsOpportunityScheduler`; the legacy `ReviewPrompter` is the only native-request owner.
* The `#if DEBUG` seam is compiled out of Release and defaults to the unchanged `SKStoreReviewController` call.

## 7. No duplicate prompts / no unapproved telemetry (VERIFIED against the real SDK pipeline)
* Duplicate prompts: second request in a launch blocked; a second engine on the same persisted state blocked by cooldown; 8 concurrently scheduled opportunities invoke the native bridge exactly once; re-scheduling replaces rather than stacks (counted by outcome callbacks); a zero delay is clamped (no request in the Save moment); cancel prevents the request; failed persistence never invokes the native bridge.
* Telemetry: with `Attribr.initializeForTesting` and a capturing `URLProtocol`, **zero requests** when SDK consent is unknown or revoked, when product disclosure or analytics consent is missing, and for any payload outside the closed contract; **exactly one** request with only the closed fields when everything is approved (the positive case proves the capture works). The engine and scheduler produce **zero** requests on their own, even with SDK consent granted. Static checks: no `URLSession`/`URLRequest`/timers/`UIApplication` in `Ratings*.swift`; only the optional bridge imports StoreKit; only the forwarder calls `Attribr.track…`.
* Cleanr telemetry stays **OFF**; the legal/privacy gate remains unresolved.

## 8. Physical-device QA — NOT PERFORMED
Two paired iPhones show as `available` over CoreDevice, but they are the owner's personal phones. Installing the QA build would (a) **replace the installed app** because the QA variant shares Cleanr's bundle ID, with its data and prompter state, or (b) require registering a new App ID/provisioning in the developer account. The repository's own protocol (`CLAUDE_PHYSICAL_IPHONE_QA_SETUP.md`) also requires owner-local WebDriverAgent/tunnel setup and says not to install or sign tooling without local authorisation. This needs the owner's decision and ideally a dedicated QA device.

**Manual device checklist (for the owner):** install the QA build on a dedicated device with clean app data → record the build/version proof → confirm `UserDefaults` keys are absent → perform 2 saves (no prompt) → third save (a system prompt may appear; Apple controls display) → force a relaunch and save again (no prompt) → set the device date +89 / +90 days and repeat → also run denied-Photos, cancel, project save, batch save, repeat Save, forward scene (backgrounded: no request), offline and airplane mode; confirm no Attribr ratings events leave the device (proxy/Charles) with consent on and off.

## 9. Gates (MRVL build gate)
The scripted `scripts/pre-archive-gate.sh --dry-run` (`PRE_BUILD` slug/manifest gate) **PASSED** (0 errors, 0 warnings). That is **not** the full archive checklist (Attribr identity gate, CrashrKit, Shpd, PPP, Growth Engine, App Store state, etc.), which applies to a release archive and was **NOT RUN** because no release build is being cut. **The QA variant links an uncommitted/unreleased SDK tree (gate item "symlink points at a dirty tree") and must never be archived or uploaded.**

## 10. Reproduce
```bash
cd attribr-ios && swift test --filter Ratings && swift test
xcodebuild test -scheme Attribr -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
python3 scripts/mutation-check-ratings.py            # 25 mutants
# Cleanr QA worktree: packages/attribr -> the SDK worktree (uncommitted)
xcodebuild test -project Cleanr.xcodeproj -scheme Cleanr -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:CleanrTests 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) MRVL_RATINGS_CORE_T1'
python3 scripts/mutation-check-ratings-cleanr.py     # 9 mutants
```
Note: allow ≥900 s per test (`-default-test-execution-time-allowance 900`) — Object Removal tests take ~5 min on this Intel host.

## 11. Remaining gates (all outside this authorisation)
Owner decision on physical-device QA and a dedicated device · rebase/re-audit T2 onto the 2.0.10/2.0.11 release lineage · privacy/legal review before any telemetry · decision on `UserDefaults` durability · the two pre-existing SDK iOS test failures · SDK tag/publication, merge, TestFlight/App Store, active ratings rollout (all require separate approval).

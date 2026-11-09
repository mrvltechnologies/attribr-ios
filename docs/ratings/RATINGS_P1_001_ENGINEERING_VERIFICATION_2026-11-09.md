# Attribr Ratings Engine — P1-001 Engineering Verification (2026-11-09)

Status: **engineering verification complete; Berea independent re-verification PENDING.** Nothing here is independent assurance and nothing here approves production use.

## 1. Provenance
- Repo / branch: `mrvltechnologies/attribr-ios` @ `feature/ratings-engine-sdk-source-20261108`
- Required starting HEAD: `fe5a834495cd27679966d25050acea243d43b4a3` (fast-forwarded from `151476c`; clean start, no local work)
- This commit adds three corrections on top (see §3). Its SHA is the single authoritative verified SHA and is recorded in the Berea comment (a commit cannot embed its own hash).
- Toolchain: Swift 6.3.2, Xcode 26.5 (17F42), macOS 26 (Darwin 25.6, x86_64). Simulator: iPhone 16 Pro, iOS 26.5, `34391BF2-AEBD-48C3-8FE3-82676819FAB1`.
- `Package.swift` unchanged vs `origin/main`; zero third-party dependencies. No GitHub Actions / paid CI triggered (`[skip ci]`, `gh run list` empty for the branch).

## 2. Berea P1-001 — independent reproduction
Identical scenario (two engines on one store, both constructed before either requests, policy 1 win / 90-day cooldown, production-faithful store that does not persist `attemptedThisLaunch`):

| SHA | Result |
|---|---|
| `151476c` (old) | `a=nativeRequestInvoked b=nativeRequestInvoked nativeCalls=2 history=1 persistedWins=1` — Berea's failure reproduced exactly |
| `fe5a834` + corrections | `a=nativeRequestInvoked b=suppressed(cooldown) nativeCalls=1 history=1 persistedWins=2` |

`RatingsCrossEngineCoordinationTests`: 11/11 (10 delivered + 1 added), covering all ten required scenarios. Both engines are constructed before either reserves. Zero-cooldown test now genuinely exercises the reservation ledger (see §3 defect 2).

## 3. Defects found and fixed (all confirmed, all in scope)
1. **Test file did not compile** (`RatingsCrossEngineCoordinationTests.swift:202`, implicit `self` in closure). Fixed (`self.opportunity()`).
2. **Test double diverged from the production store.** The fake persisted `attemptedThisLaunch`; `RatingsUserDefaultsStore` never does. Four tests failed or passed for the wrong reason, and the zero-cooldown test was being satisfied by the stored flag rather than the reservation ledger. Fake now normalises like production (with an opt-in `persistLaunchFlag` for defect 3).
3. **Engine defect: stored launch flag trusted.** `currentSnapshot()` OR-ed the *stored* `attemptedThisLaunch` into state. With any custom `RatingsStateStore` that persists the whole snapshot, the flag carried into the next launch and suppressed prompting permanently (fail-closed but wrong; it also broke 3 previously-passing tests: `testSecondEngineOnTheSamePersistedStateIsBlockedByCooldown`, `testSessionIncrementsOnlyOnceAndRelaunchRetainsCooldown`). Now the flag is process-local (`saved.state.attemptedThisLaunch`); same-launch cross-engine duplicates are blocked by `RatingsLaunchReservations`. Regression test `testStoreThatPersistsLaunchFlagDoesNotSuppressNextLaunch` + mutant 36 added.

Reservation review (reentrancy / partial write): `begin` happens before `store.save`, so a reentrant save callback sees `pending` and is refused; a failed save calls `abandonFailedWrite` (no StoreKit call, retry works); `commit` only after a successful save; native closure runs only after commit. No gap found. `state` is diagnostics-only and falls back to cached state on read failure, while decisions and mutations fail closed.

## 4. Build and regression
| Check | Result |
|---|---|
| `swift package resolve`, `swift build` | OK |
| `swift test --filter RatingsCrossEngineCoordinationTests` | 11/11 |
| `swift test --filter Ratings` | 61/61 |
| `swift test` (full SDK, macOS) | **152/152, 0 failures** |
| Ratings under UTC, Europe/London, America/Los_Angeles, Pacific/Auckland, Asia/Kolkata | 61/61 each |
| `xcodebuild test -scheme Attribr` iOS Simulator (iPhone 16 Pro, iOS 26.5) | **TEST SUCCEEDED: 152 run, 0 failures, 2 skipped** (the two Keychain persistence tests, see §6) |
| `diagnose-api-breaking-changes origin/main` | No breaking changes detected |

The first full run (before defect 3 was fixed) was 151/3 failures; those are the failures described above and are not hidden.

## 5. Mutation testing (`scripts/mutation-check-ratings.py`)
36 scenarios (35 delivered + 1 added). **36 KILLED, 0 SURVIVED, 0 INVALID.** Runner treats non-compiling runs as INVALID (never a kill). All source files verified restored afterwards (`git status` shows only the three intended modifications). Initial 35-mutant run also 35/35 before the extra mutant.

## 6. Keychain and DeviceIdentifier
- Keychain: write status is returned and observable; update-then-insert (no delete-before-write); anonymous token stable within process even when Keychain fails; restart simulated by `clearTransientCacheForTesting`; no UserDefaults fallback in `AppAccountTokenProvider`; account-linked tokens deterministic; `reset()` clears both transient and Keychain state. **All 14 tests pass on macOS with the real Keychain, including readback persistence.** On the iOS Simulator the two persistence tests skip on OSStatus **-34018** (the recognised unsigned test host / missing Keychain entitlement limitation); no other skips, no unexpected Keychain failure. Real-device / signed-host Keychain persistence across reinstall is **not proven here** → ENVIRONMENT BLOCKED for that sub-claim only.
- DeviceIdentifier: `testHashUsesKnownAlgorithm` now injects a known IDFV; passes on macOS and on the iOS Simulator (the previously failing case). Production `computeHash()` unchanged.

## 7. Safety and compatibility
Ratings remains shadow-only by default; active mode additionally requires explicit host authorisation; importing Attribr cannot trigger a native request (static-invariant tests: only the optional iOS bridge imports StoreKit, no networking/timers in Ratings sources); no ratings analytics are transmitted without product disclosure + analytics consent + SDK consent (egress tests); telemetry fields allowlisted; Ratings creates no identifier; existing event pipeline, purchase, attribution and consent APIs unchanged (no API break).

## 8. Cleanr compatibility (read-only; Cleanr not modified)
QA worktree of `integration/ratings-shadow-release-2.0.11-20261109` with the uncommitted symlink repointed to this SDK, `MRVL_RATINGS_CORE_T1` ON, Debug simulator: app compiles; `RatingsShadowObserverTests` + `RatingsLegacyBehaviourContractTests` + `RatingsReleaseLineageAuditTests` **16/16**, including 84-combination legacy/real-SDK-reducer parity. Legacy `ReviewPrompter` remains sole native request owner; no ratings telemetry, no engine activation. Note: a first run failed 8/16 because my earlier Cleanr mutation run had left `mrvl.ratings.shadow.state` in the simulator app's defaults (mutant 7's write); uninstalling Cleanr from the simulator cleared it and the re-run is clean. Test-hygiene observation only; not a product defect.

## 9. Release provenance
- Validated SDK commit: the SHA of this commit on the branch (see Berea comment).
- Rollback pin: `cd21747024ac0fb2c7c1a46a1cc86081afe4d367` ("Add Attribr.identify(userId:)"). **Discrepancy to note:** the local `Attribr-by-MRVL/sdk/swift` checkout is at `4f3cae0`, which is 4 commits *after* `cd21747` (it is an ancestor) and has no Ratings code; `sdk/swift` is an untracked nested clone, not a registered submodule, in this checkout. The owner should confirm which pin is the true production rollback.
- Intended release candidate: `0.x` Ratings-additive SDK (version number to be chosen by owner); **no tag, no pin change, no merge performed.**
- Clean-clone reproduction: `git clone https://github.com/mrvltechnologies/attribr-ios && git checkout <SHA> && swift package resolve && swift build && swift test` (expect 152/152), then `python3 scripts/mutation-check-ratings.py` (expect 36 KILLED), then simulator: `xcodebuild test -scheme Attribr -destination 'platform=iOS Simulator,name=iPhone 16 Pro'` (expect 152 run, 2 skipped on -34018).
- Provenance not yet established: commits are unsigned/unattested; no independent clean-machine build.

## 10. Remaining limitations / blockers
- Berea independent re-verification of P1-001 (required; pending).
- Keychain reinstall persistence on a signed host/device unproven.
- StoreKit bridge compiles under iOS availability and is covered by static tests, but a real review dialog is only observable on device (manual QA).
- Multi-process (app + extension) coordination is not provided: the ledger is process-local; cross-process is bounded by persisted cooldown/history only.
- Release tag/pin decision and rollback-pin confirmation (§9) belong to the owner.

## 11. Verdicts
A P1-001 remediation: PASS · B Full SDK regression: PASS · C iOS Simulator: PASS · D Mutation: PASS · E Keychain: ENVIRONMENT BLOCKED (persistence on signed host only; all else PASS) · F Cleanr compatibility: PASS · G Release-candidate readiness: CONDITIONAL · H Berea approval: PENDING

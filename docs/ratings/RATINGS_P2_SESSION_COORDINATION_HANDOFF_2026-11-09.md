# Ratings P2 Process-Session Coordination — Claude Execution Handoff

**Date:** 2026-11-09  
**Repository:** `mrvltechnologies/attribr-ios`  
**Branch:** `fix/ratings-process-session-coordination`  
**Base:** `359ee41d4fbfcb10235123925e4271720f6391ed`  
**Code SHA:** `e6cb2969371bae2e03ebc9513749dd8ae4bc2fe8`

## Scope

This is a bounded follow-up to Berea's independent re-verification of P1-001.

P1-001 remains closed.

The new P2 was:

> Two `RatingsEngine` instances sharing one namespace in the same process can
> each call `beginSession()` and increment persisted `sessionCount`, allowing
> a policy with `minimumSessions > 1` to become eligible earlier than intended.

Cleanr legacy parity uses `minimumSessions = 1`, so this was not a Cleanr parity regression.

## Source fix

`RatingsEngine.beginSession()` now coordinates session start by the same stable
store namespace used by the native-request reservation ledger.

Semantics:

- first engine for a namespace/process acquires a pending session reservation;
- only that engine increments and persists `sessionCount`;
- after successful persistence the session reservation is committed;
- later engine instances in the same process join the already-started session,
  adopt current persisted state, become usable, and do not increment;
- a failed first write abandons the pending session reservation so another
  engine can retry;
- the internal simulated-process-restart seam now resets both request and
  session launch coordination;
- no telemetry, network, StoreKit, package dependency, public API or Cleanr
  activation behavior changed.

## Regression coverage added

`RatingsCrossEngineCoordinationTests.swift` now covers:

1. two preconstructed engines count one session per process namespace;
2. two independent `RatingsUserDefaultsStore` objects for one namespace count one session;
3. `minimumSessions = 2` is not satisfied by two engines in one process;
4. a failed first session persistence releases the namespace for retry;
5. a simulated process restart adds exactly one new persisted session.

The existing relaunch test was corrected to use the process-restart seam before
expecting `sessionCount` to advance.

## Mutation coverage added

Two new mutants:

- bypass cross-engine session coordination;
- retain/commit the session reservation after a failed session write.

Expected mutation total after this tranche: **38**.

## Independent source-level check performed here

Environment:

`Swift 6.2.1 (swift-6.2.1-RELEASE), x86_64-unknown-linux-gnu`

Reduced source-faithful execution observed:

```
same process true false 1
wins 1
next process true false 2
failed first false nil
retry true 1
```

Interpretation:

- first engine begins the process session;
- second engine joins without incrementing;
- next simulated process increments once;
- failed first persistence does not poison the process namespace.

This is source-level evidence only, not a substitute for the full private package
test/Xcode execution.

## GitHub state

- branch head after code: `e6cb2969371bae2e03ebc9513749dd8ae4bc2fe8`
- relative to `359ee41`: 5 commits ahead, 0 behind
- changed files: 4
  - `Sources/Attribr/RatingsEngine.swift`
  - `Tests/AttribrTests/RatingsCrossEngineCoordinationTests.swift`
  - `Tests/AttribrTests/RatingsEngineTests.swift`
  - `scripts/mutation-check-ratings.py`
- `Package.swift` unchanged
- no GitHub Actions run triggered
- no tag, merge, SDK publication, production pin update, Cleanr modification,
  telemetry activation or App Store action performed

## Claude execution gate

Claude should run on the exact branch/head and verify:

1. `swift package resolve`
2. `swift build`
3. full `swift test`
4. Ratings suite
5. five-timezone Ratings suite
6. mutation runner — expected 38/38 killed, zero survived/invalid
7. iOS Simulator suite
8. API-breaking-change diagnostics against current `origin/main`
9. package dependency diff — must remain zero new dependencies
10. Cleanr flag-ON compatibility tests without modifying Cleanr source
11. exact two-engine/minimumSessions regression
12. failed-session-write retry
13. simulated process restart session count

Do not merge, tag, publish, update the canonical SDK pin, enable telemetry or
activate Cleanr prompting during this verification.

## Required Claude verdict

Return exactly one:

**CLAUDE PASS — RATINGS P2 SESSION COORDINATION VERIFIED**

or

**CLAUDE FAIL — <precise blocker>**

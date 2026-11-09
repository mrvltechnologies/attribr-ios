#!/usr/bin/env python3
"""Mutation checks for the Ratings Engine safety properties. Each deliberately defective variant of the SDK source MUST make
`swift test --filter Ratings` fail; the file is restored afterwards. A mutant that is NOT caught is reported SURVIVED and
fails the script.  Usage: python3 scripts/mutation-check-ratings.py"""
import subprocess, shutil, os, re, sys
ROOT=os.path.dirname(os.path.dirname(os.path.abspath(__file__))); os.chdir(ROOT)
E='Sources/Attribr/RatingsEngine.swift'; L='Sources/Attribr/RatingsEligibility.swift'
F='Sources/Attribr/RatingsAnalyticsForwarder.swift'; S='Sources/Attribr/RatingsOpportunityScheduler.swift'
T='Sources/Attribr/RatingsTelemetryContract.swift'; ST='Sources/Attribr/RatingsStateStore.swift'
MUTS=[
 ('shadow bypass: shadow mode may invoke the native bridge', E, "guard policy.mode == .active else { return .shadowOnly }", ""),
 ('active request without separate host authorisation', E, "guard activeRequestsAuthorised else { return .activeNotAuthorised }", ""),
 ('failed storage still invokes the native bridge', E, "} catch {\n            return .persistenceUnavailable\n        }", "} catch {\n        }"),
 ('native bridge invoked BEFORE the reservation is saved', E, "        var next = current\n        RatingsEligibility.markNativeRequestAttempt(in: &next.state, at: now)", "        _ = nativeRequest()\n        var next = current\n        RatingsEligibility.markNativeRequestAttempt(in: &next.state, at: now)"),
 ('annual cap removed (3 attempts / 365 days)', E, "guard recent.count < 3 else { return .annualAttemptLimit }", ""),
 ('clock rollback guard in engine removed', E, "if current.requestAttemptHistory.contains(where: { $0 > now }) {", "if false {"),
 ('clock rollback no longer blocks (eligibility)', L, "guard last <= opportunity.now else { return decision(.clockRollback) }", ""),
 ('legacy import resets the previous cooldown', E, "next.state.lastRequestAttemptAt = lastRequestAttemptAt\n        next.requestAttemptHistory", "next.state.lastRequestAttemptAt = nil\n        next.requestAttemptHistory"),
 ('legacy import may overwrite an initialised snapshot', E, "guard canImportLegacy, !startedSession, saved.state.sessionCount == 0,\n              saved.state.confirmedWins == 0,\n              saved.state.lastRequestAttemptAt == nil,\n              saved.requestAttemptHistory.isEmpty else {", "guard !startedSession else {"),
 ('background no longer suppresses the prompt', L, "guard opportunity.isForeground else { return decision(.background) }", ""),
 ('editing no longer suppresses the prompt', L, "guard !opportunity.isEditing else { return decision(.editing) }", ""),
 ('paywall no longer suppresses the prompt', L, "guard !opportunity.isPaywallPresented else { return decision(.paywall) }", ""),
 ('once-per-launch guard removed', L, "guard !state.attemptedThisLaunch else { return decision(.alreadyAttemptedThisLaunch) }", ""),
 ('cooldown removed', L, "guard days >= policy.cooldownDays else { return decision(.cooldown) }", ""),
 ('three-win threshold lowered to two (Cleanr parity)', L, "minimumConfirmedWins: 3,\n        minimumSessions: 1,", "minimumConfirmedWins: 2,\n        minimumSessions: 1,"),
 ('cooldown shortened from 90 to 30 days (Cleanr parity)', L, "minimumAppAgeDays: 0,\n        cooldownDays: 90\n    )", "minimumAppAgeDays: 0,\n        cooldownDays: 30\n    )"),
 ('cleanr parity preset becomes active', L, 'version: "cleanr-legacy-v1",\n        mode: .shadow,', 'version: "cleanr-legacy-v1",\n        mode: .active,'),
 ('analytics forwarded without analytics consent', F, "guard productDisclosureApproved, analyticsConsentApproved,", "guard productDisclosureApproved,"),
 ('analytics forwarded without product disclosure', F, "guard productDisclosureApproved, analyticsConsentApproved,", "guard analyticsConsentApproved,"),
 ('telemetry shape validation removed', F, "RatingsTelemetryContract.isApprovedShape(event) else { return false }", "true else { return false }"),
 ('telemetry allows arbitrary metadata keys', T, 'let allowed = Set(["v", "mode", "config_v", "moment", "reason"])', 'let allowed = Set(metadata.keys)'),
 ('scheduler allows an immediate (undelayed) request', S, "let boundedDelay = max(700_000_000, min(delayNanoseconds, 5_000_000_000))", "let boundedDelay = delayNanoseconds"),
 ('cancellation ignored: cancelled scheduled opportunity still fires', S, [("guard self != nil, !Task.isCancelled else { return }", "guard self != nil else { return }"), ("} catch {\n                return\n            }", "} catch {\n            }")]),
 ('repeated scheduling stacks instead of replacing', S, "        cancel()\n        // Even a misconfigured", "        // Even a misconfigured"),
 ('session counted on every call (inflated sessions)', E, "guard !startedSession else { return false }", ""),
 ('P1 cross-engine reservation guard removed', E, "guard !RatingsLaunchReservations.contains(coordinationKey) else {\n            return .suppressed(.alreadyAttemptedThisLaunch)\n        }", ""),
 ('P1 read stale cached snapshot before request', E, "            current = try currentSnapshot()\n        } catch {\n            return .persistenceUnavailable", "            current = saved\n        } catch {\n            return .persistenceUnavailable"),
 ('P1 request reservation overwrites newer wins', E, "        var next = current\n        RatingsEligibility.markNativeRequestAttempt(in: &next.state, at: now)", "        var next = saved\n        RatingsEligibility.markNativeRequestAttempt(in: &next.state, at: now)"),
 ('P1 stale confirmed win overwrites receipts', E, "        var next = try currentSnapshot()\n        guard RatingsEligibility.recordConfirmedValueMoment", "        var next = saved\n        guard RatingsEligibility.recordConfirmedValueMoment"),
 ('P1 stale failure or crash write overwrites state', E, "    private func mutate(_ edit: (inout RatingsStoreSnapshot) -> Void) throws {\n        var next = try currentSnapshot()", "    private func mutate(_ edit: (inout RatingsStoreSnapshot) -> Void) throws {\n        var next = saved"),
 ('P1 ignore stable userdefaults namespace key', ST, 'public var ratingsCoordinationKey: String { "userdefaults:" + key }', 'public var ratingsCoordinationKey: String { "userdefaults:" + UUID().uuidString }'),
 ('P1 failed read uses stale snapshot anyway', E, "            current = try currentSnapshot()\n        } catch {\n            return .persistenceUnavailable", "            current = try currentSnapshot()\n        } catch {\n            current = saved"),

]
def run():
    r=subprocess.run(['swift','test','--filter','Ratings'],capture_output=True,text=True)
    out=r.stdout+r.stderr
    m=re.findall(r'with (\d+) failures?',out)
    if not m: return -1                                              # did not compile / did not run: INVALID mutant, never a kill
    return int(m[-1])
survived=[]
ONLY=sys.argv[1] if len(sys.argv)>1 else None
for entry in MUTS:
    name,path,old,*rest = entry; new = rest[0] if rest else None
    if ONLY and ONLY not in name: continue
    src=open(path).read()
    edits = old if isinstance(old, list) else [(old, new)]
    if any(o not in src for o, _ in edits): print('?? PATTERN MISSING:',name); survived.append(name+' [pattern missing]'); continue
    shutil.copy(path,path+'.orig')
    mutated = src
    for o, n in edits: mutated = mutated.replace(o, n, 1)
    try:
        open(path,'w').write(mutated)
        failing=run()
    finally:
        shutil.move(path+'.orig',path)
    if failing<0: print(f'INVALID  (mutant did not compile) {name}'); survived.append(name+' [invalid mutant]'); continue
    print(('KILLED   ' if failing>0 else 'SURVIVED ')+f'({failing} failing) {name}')
    if failing==0: survived.append(name)
print('\nSURVIVORS:',survived or 'none'); sys.exit(1 if survived else 0)

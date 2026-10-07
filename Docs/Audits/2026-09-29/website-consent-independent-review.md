# Independent W1 website consent review — 2026-09-29

Read-only review of `/Users/alexander_markin/Documents/code/louppe/website/analytics-consent.js`
and `scripts/analytics-consent.test.mjs` after file-safety implementation, under
website/shared AGENTS.md. No edits, regeneration, deployment, commits, or changes
to existing murlexander references.

## Final result: no confirmed remaining issue in the reviewed scope

Both reproduced withdrawal cases were fixed, then the final script, tests, and
independent probes rerun. This reviewer remained read-only.

## Initial quota/reload finding — resolved

**Resolved by root: failed localStorage write caused explicit withdrawal to be undone by the ensuing reload.**

Source: `analytics-consent.js:32–36` (remember), `:94–99` (withdrawal/reload).

Trigger: saved acceptance remains valid; localStorage.getItem works but setItem
fails, e.g. quota blocks a larger rejection record. “No analytics” makes `remember` retain refusal in visitOnlyChoice,
disables, and reloads. Reload loses memory, rereads stale acceptance, and requests
analytics without new opt-in.

Reproduction used production source and the existing browser helper, extended for
write-only failure and a fresh post-reload page:

```
before rejection: scripts=1, disabled=false, stored=accepted
rejection before reload: disabled=true, reloads=1, stored=accepted
after actual reload: scripts=1, disabled=false, bannerHidden=true, stored=accepted
```

Probe: `/private/tmp/louppe-fixes-2026-09-29/website-consent-write-blocked-probe.mjs`.

Failed rejection now removes stale acceptance where possible, keeps visit-only
refusal, and suppresses automatic reload. Final quota probe:
disabled=true/reloads=0/staleAcceptancePresent=false; fresh page scripts=0/disabled=true.
The coordinator was notified; the reviewer made no edits.

The original test blocked getItem and setItem together and counted reload without
recreating a page. New write-only coverage creates the fresh page after stale-choice
removal; fully unpersistable coverage delivers a storage event during local refusal.

## Queued storage event race — resolved

The intermediate handler always cleared `visitOnlyChoice`. If reads work while
writes/removal fail, a queued pre-rejection acceptance event can clear refusal and
reenable the unchanged older saved choice.

Production-source repro: other tab accepts at t1, failed local rejection at t2,
then the older event arrives. disable=true/reloads=0 becomes disable=false with a
download recorded, without navigation/reload. This exceeds the visit-persistence limit.

Probe `/private/tmp/louppe-fixes-2026-09-29/website-consent-final-quota-probe.mjs`; log `/private/tmp/louppe-fixes-2026-09-29/website-consent-final-quota-probe.log`. Root fixed the storage handler to preserve `visitOnlyChoice === "rejected"` until this visitor explicitly chooses again. Final probe after delivering the older queued event: disabled=true, downloads=0, reloads=0. Explicit fresh local choice can still update or replace the fallback normally.

The same probe confirms root's first fix: quota failure removes stale acceptance, reloads=0, and a fresh write-blocked page requests no analytics script.

## Checked branches without another confirmed issue

- Cross-tab accepted → rejected, saved-key removal, storage.clear (`key=null`), and unrelated storage events: current storage state is reread, not trusted from a possibly stale event payload. Explicit rejection disables, queues denied consent, and reloads. Download interception also rechecks storage even if the storage event was missed.
- Missing, invalid value, corrupt JSON, nonfinite/invalid timestamps, future choice, and exact lifetime boundary: no initial tag script or download event; disable property starts true. Newly unavailable storage also fails closed.
- Expiry timer: maximum browser timeout is clamped, subsequent chunks recheck current acceptance, and expiry disables an otherwise continuously active accepted page. Reconciliation clears the previous timer; even an already queued stale callback reads the newest saved choice rather than expiring a renewed choice.
- Fully blocked read/write storage: no initial tag. Explicit acceptance is limited to in-memory visit choice, subsequent rejection disables, and a freshly created blocked-storage page requests no tag.
- Withdrawal while Google script is loading: disable is set before consent denial/reload. Reacceptance is explicit, grants consent again, and does not append a second script in the still-current page. The implementation contains no onload closure able to resurrect a stale accepted local choice.
- No opt-in request: initial undecided/rejected/expired branches do not construct or append the external tag. Repository HTML/JS search found no other GA tag, Google Analytics preconnect, or tagmanager preload bypass.
- Production host gate: exactly HTTPS `louppe.eu`. localhost, alternate copied hosts, `www.louppe.eu`, `louppe.eu.evil.test`, and HTTP production hostname never append the tag or emit download analytics.
- Download path preserves `/murlexander/louppe-media-culler/releases/latest/download/Louppe.zip` and GitHub hostname matching. Existing murlexander changes were preserved.

## Evidence and limits

`node --test scripts/analytics-consent.test.mjs`: **11 tests passed, 0 failures**. Log `/private/tmp/louppe-fixes-2026-09-29/website-consent-review-tests.log`.

Additional independent probes for initial choice values, host variants, stale callbacks, timer chunking, and fully blocked post-reload pages all passed. Source `/private/tmp/louppe-fixes-2026-09-29/website-consent-extra-probes.mjs`; log `/private/tmp/louppe-fixes-2026-09-29/website-consent-extra-probes.log`.

This was source/state-machine review with bounded Node VM execution, without
Google code, real beacons/cookie jars, or deployment. Both findings are resolved.
Final assertions cover fresh-page refusal after stale-choice removal and
disabled=true/downloads=0/reloads=0 after an older event when writes/removal fail.
Fully unpersistable refusal ends on manual navigation/reload; the script cannot
store what the browser refuses. It avoids automatic memory loss and preserves
refusal through focus, visibility, clicks, timers, and storage events during the visit.
As of 29 September, publication was pending. The fix is now live; remaining browser
acceptance is in [WEB-AUD-01](../../../../website/BACKLOG.md#browser-acceptance).
# Security

## What this SDK does with your keys

- `apiKey` (`attr_live_...`/`attr_test_...`) is sent as the `X-Attribr-Key` header on every
  request. It is never logged, printed, or included in crash reports.
- **Always generate a Client key (`sdk_ingest` scope) in Settings → API Keys for `apiKey` — never
  a Full key.** A Client key can only submit ingest events (launch/event/revenue/attribution); it
  cannot read install, revenue, cohort, retention, or source data from your Attribr dashboard even
  if extracted from a shipped app binary. A Full key embedded here would let anyone who extracts it
  read your entire dashboard.
- Neither key type is ever committed by this SDK itself. How you store it in your own app
  (`.xcconfig`, build-time environment variable, etc.) is your app's responsibility — never
  hardcode it in a committed source file.

## What this SDK sends about the device

- A SHA-256 hash of `IdentifierForVendor` — never the raw identifier, never IDFA.
- No IP address, email, name, location, contacts, or photos are collected or sent by this SDK at
  any point.
- Nothing is sent over the network until `Attribr.setConsent(.granted)` is called — see
  README.md "Privacy / Data Flow".

## Supported SDK scope

See README.md "Supported Scope" for the current Tier 1 / Tier 2 capability breakdown (what this
package covers natively — SKAdNetwork, push-token uninstall detection, StoreKit 2 transaction
reporting — versus what it does not cover, such as Android or Web).

## Reporting a vulnerability

Please report security issues privately via GitHub Security Advisories: open the **Security** tab
on this repository → **Report a vulnerability**. Do not open a public GitHub issue for a security
report. We'll acknowledge reports as soon as possible and coordinate disclosure with you.

# StoreKit lifecycle QA harness

`swift test` skips the StoreKit-dependent cases (StoreKitTest needs an app host).
Run from Xcode: `xcodegen generate`, open the project, attach `Lifecycle.storekit` to the scheme's Run/Test
StoreKit configuration, set env `ATTRIBR_STOREKIT_QA=1`, run `HarnessTests`.

Status 2026-10-12: headless `xcodebuild test` on an iOS 26.5 simulator loads the host and runs the pure
cases (7 pass) but `Product.products(for:)` returns 0 products for the in-process `SKTestSession`, so the 7
StoreKit-dependent cases (purchase / updates / currentEntitlements / consent / cap) are UNPROVEN. They must
be run in the Xcode GUI or on a sandbox device before the SDK is tagged.

# Attribr Swift SDK

Install attribution for iOS apps. Zero dependencies. Zero rejection risk. 3 lines of code.

## Installation (Swift Package Manager)

In Xcode: **File > Add Package Dependencies** and enter:

```
https://github.com/mrvltechnologies/attribr-ios
```

Or add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/mrvltechnologies/attribr-ios", from: "1.0.0")
]
```

## Quick Start

```swift
import Attribr

// In App.init():
Attribr.initialize(apiKey: "attr_live_...")
Attribr.setConsent(.granted)

// In .active scene phase:
Attribr.trackLaunch()
```

That's it. No AASA file. No URL scheme. No IDFA. Ships with `PrivacyInfo.xcprivacy` included.

## Requirements

- iOS 15+
- Swift 5.9+
- Zero third-party dependencies

## API Key

Get your API key at [attribr.dev](https://attribr.dev). Free up to 1,000 installs/month.

## Docs

Full integration guide: [attribr.dev/docs](https://attribr.dev/docs)

## License

MIT License. Copyright 2026 Marvel Technologies.

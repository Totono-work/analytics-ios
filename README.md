# Totono Analytics for iOS

In Xcode, add `https://github.com/totono-work/analytics-ios` as a Swift Package dependency, select version `0.2.0` or later, and link the `TotonoAnalytics` product. Supports iOS 15 and later.

For Package.swift:

```swift
.package(url: "https://github.com/totono-work/analytics-ios.git", from: "0.2.0")
```

```swift
import TotonoAnalytics
let analytics = TotonoAnalytics(
    endpoint: URL(string: "https://totono.work/api/public/analytics/v1/events")!,
    key: "YOUR_INGESTION_KEY", appVersion: "1.0", environment: .test,
    namespace: "YOUR_PROJECT_ID"
)
await analytics.track("app.opened", properties: ["source": .string("ios")])
await analytics.identify("opaque-customer-id")
await analytics.track("checkout.started", properties: ["amount": .number(12)])
await analytics.flush()
```

Retain one actor instance per project. It persists a random installation ID and a bounded queue in UserDefaults. Use a stable project-specific namespace through key rotations. Sessions last for the actor's lifetime. Customer identity affects future events only and remains in memory. Event properties support `.string`, `.number`, `.bool`, and `.null`.

Tracking starts the ten-second flush timer. Flush on launch to retry restored queued events, and when the app enters the background using the host application's permitted background execution time. Background delivery is best effort; events remain queued if a request cannot finish.

`reset()` clears customer identity and generates a new installation/session. `setOptOut(true)` clears queued events and identity and persists the preference; `setOptOut(false)` resumes anonymously. `getInstallationId()` supports installation deletion requests. Already transmitted requests cannot be withdrawn. Do not send personal information in properties. Production data is the default; use `.test` during integration.

Run `swift test` to compile and test the client.

The GitHub CI workflow compiles and tests the package on macOS. Live endpoint testing is optional; set `TOTONO_ANALYTICS_TEST_ENDPOINT` and `TOTONO_ANALYTICS_TEST_KEY` to use a disposable local project. Do not put keys in the repository.

## Device and environment context (0.2.0)

The 0.2.0 source requires the compatible collector to be deployed first: the 0.1.0 server rejects unknown metadata fields.

Each explicit `track()` snapshots native device class, available hardware identifier (for example `iPhone17,3`, or the simulator's model identifier), OS name/version, bundled SDK version, preferred BCP 47 language, and available system light/dark appearance. Full screen width/height use **points**, and `screenScale` reports physical pixels per point. UIKit sampling runs on the main actor; unavailable values are omitted. The package retains its non-UIKit compilation path, where screen/appearance/model data may be unavailable.

Omitting `appVersion` now uses the app bundle's `CFBundleShortVersionString`. Supplying a string (including an explicit empty string) takes precedence. Active app language/theme can override device defaults:

```swift
let analytics = TotonoAnalytics(
    endpoint: URL(string: "https://totono.work/api/public/analytics/v1/events")!,
    key: "YOUR_INGESTION_KEY",
    context: AnalyticsContext(language: "cs-CZ", colorScheme: .dark)
)
await analytics.setContext(AnalyticsContext(language: "en-US", colorScheme: .light))
await analytics.setContext(AnalyticsContext()) // Restore device defaults.
```

`setContext` replaces all overrides for future events. Invalid language overrides fall back to the device preference. Queue restoration accepts legacy events with absent metadata; retries preserve captured values. No automatic events, location permission prompts, or extra device identifiers are introduced. Country is supplied only by the collector's trusted upload-time IP country estimate when enabled, can reflect a VPN/proxy, and remains unknown otherwise. Locale region is never used as country.

The release version lives in `Sources/TotonoAnalytics/Resources/VERSION` and is bundled by SwiftPM; update it to match the release tag. Run both macOS `swift test` and an iOS Simulator build to verify the Foundation-only and UIKit paths.

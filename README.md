# Totono Analytics for iOS

In Xcode, add `https://github.com/totono-work/analytics-ios` as a Swift Package dependency, select version `0.1.0` or later, and link the `TotonoAnalytics` product. Supports iOS 15 and later.

For Package.swift:

```swift
.package(url: "https://github.com/totono-work/analytics-ios.git", from: "0.1.0")
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

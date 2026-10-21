import XCTest
@testable import TotonoAnalytics
actor Recorder {
    var bodies: [Data] = []
    func send(_ request: URLRequest) -> (Data, URLResponse) {
        bodies.append(request.httpBody!)
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!)
    }
    func events() throws -> [[String: Any]] { (try JSONSerialization.jsonObject(with: bodies.last!) as! [String: Any])["events"] as! [[String: Any]] }
    func count() -> Int { bodies.count }
}
final class TotonoAnalyticsTests: XCTestCase {
    func testWireContractAndFutureOnlyIdentity() async throws {
        let recorder = Recorder()
        let defaults = UserDefaults(suiteName: "analytics.test.\(UUID())")!
        let client = TotonoAnalytics(endpoint: URL(string: "https://example.com/events")!, key: "test", environment: .test, defaults: defaults, transport: { await recorder.send($0) })
        await client.track("before")
        await client.identify("customer")
        await client.track("after", properties: ["amount": .number(2), "empty": .null])
        await client.flush()
        let events = try await recorder.events()
        XCTAssertNil(events[0]["customerId"])
        XCTAssertEqual(events[1]["customerId"] as? String, "customer")
        XCTAssertEqual(events[1]["platform"] as? String, "ios")
        XCTAssertEqual(events[1]["environment"] as? String, "test")
        XCTAssertEqual(events[0]["appVersion"] as? String, Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
        XCTAssertNotNil(UUID(uuidString: events[0]["id"] as! String))
        await client.setOptOut(true)
    }
    func testResetAndOptOut() async throws {
        let recorder = Recorder()
        let client = TotonoAnalytics(endpoint: URL(string: "https://example.com/events")!, key: "test", defaults: UserDefaults(suiteName: "analytics.test.\(UUID())")!, transport: { await recorder.send($0) })
        let original = await client.getInstallationId()
        await client.track("discard")
        await client.setOptOut(true)
        await client.track("ignored")
        await client.flush()
        let count = await recorder.count()
        XCTAssertEqual(count, 0)
        let optedOut = await client.getInstallationId()
        XCTAssertNil(optedOut)
        await client.setOptOut(false)
        let replacement = await client.getInstallationId()
        XCTAssertNotEqual(replacement, original)
        await client.identify("customer")
        await client.reset()
        await client.track("reset")
        await client.flush()
        let events = try await recorder.events()
        XCTAssertNil(events[0]["customerId"])
        await client.setOptOut(true)
    }
}

actor LiveRecorder {
    var status: Int?
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let result = try await URLSession.shared.data(for: request)
        status = (result.1 as? HTTPURLResponse)?.statusCode
        return result
    }
    func responseStatus() -> Int? { status }
}
extension TotonoAnalyticsTests {
    func testLiveIngestionWhenConfigured() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["TOTONO_ANALYTICS_TEST_ENDPOINT"],
              let key = ProcessInfo.processInfo.environment["TOTONO_ANALYTICS_TEST_KEY"] else { throw XCTSkip("Local collection endpoint not configured") }
        let recorder = LiveRecorder()
        let client = TotonoAnalytics(endpoint: URL(string: endpoint)!, key: key, environment: .test,
                                     defaults: UserDefaults(suiteName: "analytics.live.\(UUID())")!, transport: { try await recorder.send($0) })
        await client.track("ios.contract", properties: ["source": .string("swift")])
        await client.flush()
        let status = await recorder.responseStatus()
        XCTAssertEqual(status, 202)
        await client.setOptOut(true)
    }
}

actor RetryRecorder {
    var bodies: [Data] = []
    func send(_ request: URLRequest) -> (Data, URLResponse) {
        bodies.append(request.httpBody!)
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: bodies.count == 1 ? 429 : 202, httpVersion: nil, headerFields: ["Retry-After": "0"])!)
    }
    func requests() -> [Data] { bodies }
}
extension TotonoAnalyticsTests {
    func testRetriesPreserveEventIdentityAndBackOff() async throws {
        let recorder = RetryRecorder()
        let client = TotonoAnalytics(endpoint: URL(string: "https://example.com/events")!, key: "retry", defaults: UserDefaults(suiteName: "analytics.retry.\(UUID())")!, transport: { await recorder.send($0) })
        await client.track("retry")
        await client.flush()
        await client.setContext(AnalyticsContext(language: "cs-CZ", colorScheme: .dark))
        await client.flush()
        let first = await recorder.requests()
        XCTAssertEqual(first.count, 1)
        try await Task.sleep(nanoseconds: 2_100_000_000)
        await client.flush()
        let requests = await recorder.requests()
        XCTAssertEqual(requests.count, 2)
        let before = try JSONDecoder().decode([String:[TotonoAnalytics.Event]].self, from: requests[0])["events"]![0]
        let after = try JSONDecoder().decode([String:[TotonoAnalytics.Event]].self, from: requests[1])["events"]![0]
        XCTAssertEqual(before.id, after.id)
        XCTAssertEqual(before.timestamp, after.timestamp)
        XCTAssertEqual(before.sdkVersion, after.sdkVersion)
        XCTAssertEqual(before.osVersion, after.osVersion)
        XCTAssertEqual(before.language, after.language)
        XCTAssertEqual(before.screenWidth, after.screenWidth)
        let beforeJSON = try JSONSerialization.jsonObject(with: requests[0]) as! NSDictionary
        let afterJSON = try JSONSerialization.jsonObject(with: requests[1]) as! NSDictionary
        XCTAssertEqual(beforeJSON, afterJSON)
        await client.setOptOut(true)
    }
}

extension TotonoAnalyticsTests {
    func testContextSnapshotsAndLegacyQueueUpgrade() async throws {
        let recorder = Recorder()
        let defaults = UserDefaults(suiteName: "analytics.upgrade.\(UUID())")!
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let legacy: [String: Any] = ["id": UUID().uuidString, "timestamp": f.string(from: Date()), "name": "legacy",
            "installationId": "i", "sessionId": "s", "environment": "production", "platform": "ios", "appVersion": "1", "properties": [:]]
        defaults.set(try JSONSerialization.data(withJSONObject: [legacy]), forKey: "totono.analytics.upgrade.queue")
        let client = TotonoAnalytics(endpoint: URL(string: "https://example.com/events")!, key: "upgrade", appVersion: "2.1",
                                     context: AnalyticsContext(language: "cs-CZ", colorScheme: .dark),
                                     defaults: defaults, transport: { await recorder.send($0) })
        await client.track("first")
        await client.setContext(AnalyticsContext(language: "en-US", colorScheme: .light))
        await client.track("second")
        await client.setContext(AnalyticsContext())
        await client.track("default")
        await client.flush()
        let events = try await recorder.events()
        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(events[0] as NSDictionary, legacy as NSDictionary)
        XCTAssertNil(events[0]["sdkVersion"])
        XCTAssertEqual(events[1]["language"] as? String, "cs-CZ")
        XCTAssertEqual(events[1]["colorScheme"] as? String, "dark")
        XCTAssertEqual(events[2]["language"] as? String, "en-US")
        XCTAssertEqual(events[2]["colorScheme"] as? String, "light")
        XCTAssertEqual(events[1]["appVersion"] as? String, "2.1")
        XCTAssertEqual(events[1]["sdkVersion"] as? String, "0.2.0")
        XCTAssertNotNil(events[1]["osVersion"])
        XCTAssertEqual(events[3]["language"] as? String, DeviceContext.validLanguage(Locale.preferredLanguages.first))
        #if canImport(UIKit)
        XCTAssertGreaterThan(events[1]["screenWidth"] as? Double ?? 0, 0)
        XCTAssertGreaterThan(events[1]["screenHeight"] as? Double ?? 0, 0)
        XCTAssertGreaterThan(events[1]["screenScale"] as? Double ?? 0, 0)
        #endif
        await client.setOptOut(true)
    }
    func testLanguageValidation() {
        for value in ["cs-CZ", "en", "zh-Hant-TW", "en-US-u-ca-gregory", "de-CH-1901", "en-x-app"] {
            XCTAssertEqual(DeviceContext.validLanguage(value), value)
        }
        for value in ["", "en_US", "en-u-ca-gregory-u-nu-latn", "sl-rozaj-rozaj", String(repeating: "a", count: 81)] {
            XCTAssertNil(DeviceContext.validLanguage(value))
        }
    }
}

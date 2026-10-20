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
        await client.setOptOut(true)
    }
}

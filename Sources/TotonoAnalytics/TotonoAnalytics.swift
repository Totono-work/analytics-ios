import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AnalyticsValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else { self = .string(try c.decode(String.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .string(let v): try c.encode(v); case .number(let v): try c.encode(v); case .bool(let v): try c.encode(v); case .null: try c.encodeNil() }
    }
    var valid: Bool {
        switch self { case .string(let v): return v.utf16.count <= 1024; case .number(let v): return v.isFinite; default: return true }
    }
}

public actor TotonoAnalytics {
    public enum Environment: String, Codable, Sendable { case production, test }
    struct Event: Codable, Sendable {
        let id: String, timestamp: String, name: String, installationId: String, sessionId: String
        let customerId: String?
        let environment: Environment
        let platform: String, appVersion: String
        let properties: [String: AnalyticsValue]
    }
    private let endpoint: URL, key: String, appVersion: String, environment: Environment, defaults: UserDefaults, prefix: String
    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private var installationId = "", sessionId = "", customerId: String?, optedOut: Bool
    private var queue: [Event] = [], sending = false, failures = 0, retryAt = Date.distantPast
    private var timer: Task<Void, Never>?
    public init(endpoint: URL, key: String, appVersion: String = "", environment: Environment = .production,
                namespace: String? = nil, defaults: UserDefaults = .standard,
                transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) {
        precondition(endpoint.scheme == "https" || (endpoint.scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(endpoint.host ?? "")), "invalid_endpoint")
        self.endpoint = endpoint; self.key = key; self.appVersion = appVersion; self.environment = environment
        self.defaults = defaults; self.prefix = "totono.analytics.\(namespace ?? key)"; self.transport = transport
        self.optedOut = defaults.bool(forKey: prefix + ".optout")
        if !optedOut {
            installationId = defaults.string(forKey: prefix + ".installation") ?? UUID().uuidString
            sessionId = UUID().uuidString
            defaults.set(installationId, forKey: prefix + ".installation")
            if let data = defaults.data(forKey: prefix + ".queue"), let events = try? JSONDecoder().decode([Event].self, from: data) {
                queue = Array(events.filter { Self.date($0.timestamp)?.timeIntervalSinceNow ?? -.infinity > -7 * 86400 }.suffix(1000))
            }
        }
    }
    deinit { timer?.cancel() }
    private static func date(_ value: String) -> Date? { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.date(from: value) }
    private func startTimer() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                await self?.flush()
            }
        }
    }
    public func track(_ name: String, properties: [String: AnalyticsValue] = [:]) {
        guard !optedOut else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf16.count <= 120, appVersion.utf16.count <= 80, properties.count <= 32,
              properties.allSatisfy({ !$0.key.isEmpty && $0.key.utf16.count <= 80 && $0.value.valid }) else { return }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        queue.append(Event(id: UUID().uuidString, timestamp: f.string(from: Date()), name: name,
                           installationId: installationId, sessionId: sessionId, customerId: customerId,
                           environment: environment, platform: "ios", appVersion: appVersion, properties: properties))
        if queue.count > 1000 { queue.removeFirst() }
        persist(); startTimer()
        if queue.count >= 100 { Task { await self.flush() } }
    }
    public func identify(_ customerId: String) { guard !optedOut, !customerId.isEmpty, customerId.utf16.count <= 200 else { return }; self.customerId = customerId }
    public func reset() {
        customerId = nil; guard !optedOut else { return }
        installationId = UUID().uuidString; sessionId = UUID().uuidString
        defaults.set(installationId, forKey: prefix + ".installation")
    }
    public func setOptOut(_ value: Bool) {
        optedOut = value; customerId = nil; defaults.set(value, forKey: prefix + ".optout")
        if value {
            queue = []; installationId = ""; sessionId = ""; timer?.cancel(); timer = nil
            defaults.removeObject(forKey: prefix + ".installation"); defaults.removeObject(forKey: prefix + ".queue")
        } else if installationId.isEmpty { reset() }
    }
    public func getInstallationId() -> String? { optedOut ? nil : installationId }
    public func flush() async {
        guard !optedOut, !sending, Date() >= retryAt else { return }
        queue = queue.filter { Self.date($0.timestamp)?.timeIntervalSinceNow ?? -.infinity > -7 * 86400 }
        var batch: [Event] = []
        for event in queue.prefix(100) {
            guard let body = try? JSONEncoder().encode(["events": batch + [event]]), body.count <= 200 * 1024 else { break }
            batch.append(event)
        }
        guard !batch.isEmpty, let body = try? JSONEncoder().encode(["events": batch]) else { return }
        sending = true; defer { sending = false }
        var request = URLRequest(url: endpoint); request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 15; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue(key, forHTTPHeaderField: "X-Totono-Analytics-Key")
        do {
            let (_, response) = try await transport(request)
            guard let response = response as? HTTPURLResponse else { backoff(nil); return }
            if (200..<300).contains(response.statusCode) || [400, 413, 415].contains(response.statusCode) {
                let ids = Set(batch.map(\.id)); queue.removeAll { ids.contains($0.id) }; failures = 0; retryAt = .distantPast; persist()
            } else { backoff(response.value(forHTTPHeaderField: "Retry-After")) }
        } catch { backoff(nil) }
    }
    private func backoff(_ header: String?) {
        failures += 1; let seconds = max(Double(header ?? "") ?? 0, min(300, pow(2, Double(min(failures, 8)))))
        retryAt = Date().addingTimeInterval(seconds)
    }
    private func persist() { if !optedOut, let data = try? JSONEncoder().encode(queue) { defaults.set(data, forKey: prefix + ".queue") } }
}

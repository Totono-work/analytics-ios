import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Darwin)
import Darwin
#endif

public struct AnalyticsContext: Sendable {
    public enum ColorScheme: String, Codable, Sendable { case light, dark }
    public var language: String?
    public var colorScheme: ColorScheme?
    public init(language: String? = nil, colorScheme: ColorScheme? = nil) {
        self.language = language; self.colorScheme = colorScheme
    }
}

struct DeviceContext: Sendable {
    var deviceType: String?, deviceModel: String?, osName: String?, osVersion: String?
    var screenWidth: Double?, screenHeight: Double?, screenScale: Double?
    var language: String?
    var colorScheme: AnalyticsContext.ColorScheme?

    static let sdkVersion: String? = Bundle.module.url(forResource: "VERSION", withExtension: nil)
        .flatMap { try? String(contentsOf: $0, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) }

    static func validLanguage(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf16.count <= 80 else { return nil }
        // Conservative BCP 47 subset: language, script, region, variants, extensions, private use.
        let pattern = "^[A-Za-z]{2,8}(?:-[A-Za-z]{4})?(?:-(?:[A-Za-z]{2}|[0-9]{3}))?(?:-(?:[A-Za-z0-9]{5,8}|[0-9][A-Za-z0-9]{3}))*(?:-[0-9A-WY-Za-wy-z](?:-[A-Za-z0-9]{2,8})+)*(?:-[xX](?:-[A-Za-z0-9]{1,8})+)?$"
        guard value.range(of: pattern, options: .regularExpression) != nil else { return nil }
        // Duplicate variants and extension singletons are not valid language tags.
        let parts = value.lowercased().split(separator: "-")
        var variants = Set<Substring>(), singletons = Set<Substring>()
        for part in parts.dropFirst() {
            if part == "x" { break }
            if part.count == 1 {
                guard singletons.insert(part).inserted else { return nil }
            } else if singletons.isEmpty && (part.count >= 5 || (part.count == 4 && part.first?.isNumber == true)) {
                guard variants.insert(part).inserted else { return nil }
            }
        }
        return value
    }

    static func sample() async -> DeviceContext {
        var result = DeviceContext()
        result.language = validLanguage(Locale.preferredLanguages.first)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        result.osVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        #if canImport(UIKit)
        let ui = await MainActor.run { () -> DeviceContext in
            var ui = DeviceContext()
            let device = UIDevice.current
            switch device.userInterfaceIdiom {
            case .phone: ui.deviceType = "phone"
            case .pad: ui.deviceType = "tablet"
            case .mac: ui.deviceType = "desktop"
            default: ui.deviceType = "unknown"
            }
            ui.osName = device.systemName
            ui.osVersion = device.systemVersion
            let screen = UIScreen.main
            ui.screenWidth = Double(screen.bounds.width)
            ui.screenHeight = Double(screen.bounds.height)
            ui.screenScale = Double(screen.scale)
            switch screen.traitCollection.userInterfaceStyle {
            case .light: ui.colorScheme = .light
            case .dark: ui.colorScheme = .dark
            default: break
            }
            return ui
        }
        result.deviceType = ui.deviceType; result.osName = ui.osName; result.osVersion = ui.osVersion
        result.screenWidth = ui.screenWidth; result.screenHeight = ui.screenHeight; result.screenScale = ui.screenScale
        result.colorScheme = ui.colorScheme
        #elseif os(macOS)
        result.deviceType = "desktop"; result.osName = "macOS"
        #else
        result.deviceType = "unknown"
        #endif
        #if canImport(Darwin)
        var system = utsname()
        if uname(&system) == 0 {
            let machine = withUnsafeBytes(of: &system.machine) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            #if targetEnvironment(simulator)
            result.deviceModel = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
            #elseif os(iOS)
            result.deviceModel = machine
            #endif
        }
        #endif
        if let width = result.screenWidth, !width.isFinite || width <= 0 || width > 100_000 { result.screenWidth = nil }
        if let height = result.screenHeight, !height.isFinite || height <= 0 || height > 100_000 { result.screenHeight = nil }
        if let scale = result.screenScale, !scale.isFinite || scale <= 0 || scale > 100 { result.screenScale = nil }
        return result
    }
}

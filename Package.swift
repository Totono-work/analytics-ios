// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "TotonoAnalytics",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "TotonoAnalytics", targets: ["TotonoAnalytics"])],
    targets: [.target(name: "TotonoAnalytics", resources: [.process("Resources")]), .testTarget(name: "TotonoAnalyticsTests", dependencies: ["TotonoAnalytics"])])

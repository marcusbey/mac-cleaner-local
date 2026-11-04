// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "AppCleaner", platforms: [.macOS(.v14)],
  products: [
    .executable(name: "AppCleaner", targets: ["AppCleaner"]),
    .library(name: "CleanerCore", targets: ["CleanerCore"]),
  ],
  targets: [
    .target(name: "CleanerCore"),
    .executableTarget(name: "AppCleaner", dependencies: ["CleanerCore"]),
    .testTarget(name: "CleanerCoreTests", dependencies: ["CleanerCore"]),
  ], swiftLanguageModes: [.v5])

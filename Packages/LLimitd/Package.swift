// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "LLimitd",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "llimit", targets: ["llimit"])
  ],
  dependencies: [
    .package(path: "../QuotaCore")
  ],
  targets: [
    .target(
      name: "LLimitdCore",
      dependencies: [
        .product(name: "QuotaCore", package: "QuotaCore")
      ]
    ),
    .executableTarget(
      name: "llimit",
      dependencies: ["LLimitdCore", .product(name: "QuotaCore", package: "QuotaCore")]
    ),
    .testTarget(
      name: "LLimitdCoreTests",
      dependencies: ["LLimitdCore"]
    )
  ]
)

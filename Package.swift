// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "logicctl",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .executable(
      name: "logicctl",
      targets: ["logicctl"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2")
  ],
  targets: [
    .target(name: "LogicctlCore"),
    .target(
      name: "LogicctlJournal",
      dependencies: ["LogicctlCore"]),
    .target(
      name: "LogicctlMac",
      dependencies: ["LogicctlCore"]),
    .target(
      name: "LogicctlTesting",
      dependencies: ["LogicctlCore"]),
    .executableTarget(
      name: "logicctl",
      dependencies: [
        "LogicctlCore",
        "LogicctlJournal",
        "LogicctlMac",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]),
    .testTarget(
      name: "LogicctlCoreTests",
      dependencies: [
        "LogicctlCore",
        "LogicctlJournal",
        "LogicctlMac",
        "LogicctlTesting",
        "logicctl",
      ]),
    .testTarget(
      name: "LogicctlJournalTests",
      dependencies: ["LogicctlJournal"]),
    .testTarget(
      name: "LogicctlMacTests",
      dependencies: ["LogicctlMac"]),
    .testTarget(
      name: "LogicctlTestingTests",
      dependencies: ["LogicctlCore", "LogicctlTesting"]),
    .testTarget(
      name: "logicctlTests",
      dependencies: [
        "LogicctlCore",
        "LogicctlJournal",
        "LogicctlMac",
        "LogicctlTesting",
        "logicctl",
      ]),
  ]
)

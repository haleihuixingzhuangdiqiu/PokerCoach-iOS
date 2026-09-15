// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PokerCoach",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PokerCoachCore", targets: ["PokerCoachCore"]),
        .library(name: "PokerCoachUI", targets: ["PokerCoachUI"]),
        .library(name: "PokerCoachCapture", targets: ["PokerCoachCapture"]),
        .executable(name: "poker-coach", targets: ["PokerCoachCLI"]),
        .executable(name: "poker-video", targets: ["PokerCoachVideoCLI"]),
        .executable(name: "poker-cards", targets: ["PokerCoachCardsCLI"]),
        .executable(name: "poker-screen", targets: ["PokerCoachScreenCLI"])
    ],
    targets: [
        .target(name: "PokerCoachCore"),
        .target(name: "PokerCoachUI", dependencies: ["PokerCoachCore"]),
        .target(name: "PokerCoachCapture", resources: [.process("Resources")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "PokerCoachCLI", dependencies: ["PokerCoachCore"]),
        .executableTarget(name: "PokerCoachVideoCLI", dependencies: ["PokerCoachCore", "PokerCoachCapture"]),
        .executableTarget(name: "PokerCoachCardsCLI", dependencies: ["PokerCoachCapture"]),
        .executableTarget(name: "PokerCoachScreenCLI", dependencies: ["PokerCoachCore", "PokerCoachCapture"]),
        .testTarget(name: "PokerCoachCoreTests", dependencies: ["PokerCoachCore", "PokerCoachCapture"])
    ]
)

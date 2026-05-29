// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "TrackerBud",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TrackerBud", targets: ["TrackerBud"]),
        .library(name: "TrackerBudCore", targets: ["TrackerBudCore"]),
        .library(name: "AppTracker", targets: ["AppTracker"]),
        .library(name: "BrowserTracker", targets: ["BrowserTracker"]),
        .library(name: "FileTracker", targets: ["FileTracker"]),
        .library(name: "InputTracker", targets: ["InputTracker"]),
        .library(name: "ClipboardTracker", targets: ["ClipboardTracker"]),
        .library(name: "ScreenTracker", targets: ["ScreenTracker"]),
        .library(name: "Analysis", targets: ["Analysis"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
    ],
    targets: [
        .executableTarget(
            name: "TrackerBud",
            dependencies: [
                "TrackerBudCore",
                "AppTracker",
                "BrowserTracker",
                "FileTracker",
                "InputTracker",
                "ClipboardTracker",
                "ScreenTracker",
                "Analysis",
            ],
            path: "Sources/TrackerBud",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ])
            ]
        ),
        .target(
            name: "TrackerBudCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/TrackerBudCore"
        ),
        .target(name: "AppTracker", dependencies: ["TrackerBudCore"], path: "Sources/AppTracker"),
        .target(name: "BrowserTracker", dependencies: ["TrackerBudCore"], path: "Sources/BrowserTracker"),
        .target(name: "FileTracker", dependencies: ["TrackerBudCore"], path: "Sources/FileTracker"),
        .target(name: "InputTracker", dependencies: ["TrackerBudCore"], path: "Sources/InputTracker"),
        .target(name: "ClipboardTracker", dependencies: ["TrackerBudCore"], path: "Sources/ClipboardTracker"),
        .target(name: "ScreenTracker", dependencies: ["TrackerBudCore"], path: "Sources/ScreenTracker"),
        .target(name: "Analysis", dependencies: ["TrackerBudCore"], path: "Sources/Analysis"),
        .testTarget(
            name: "TrackerBudCoreTests",
            dependencies: ["TrackerBudCore"],
            path: "Tests/TrackerBudCoreTests"
        ),
    ]
)

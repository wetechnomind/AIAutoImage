// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AIAutoImage",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
        .tvOS(.v14),
        .watchOS(.v7)
    ],
    products: [
        // Public API
        .library(
            name: "AIAutoImage",
            targets: ["AIAutoImage"]
        ),

        // Core Engine (Advanced usage)
        .library(
            name: "AIAutoImageCore",
            targets: ["AIAutoImageCore"]
        )
    ],
    targets: [

        // ============================================================
        // MARK: - Public API Layer
        // ============================================================
        .target(
            name: "AIAutoImage",
            dependencies: ["AIAutoImageCore"],
            path: "Sources/AIAutoImage",
            exclude: [],
            sources: [
                ".",              // AIAutoImage.swift
                "Extensions"      // SwiftUI + UIKit helpers
            ],
            swiftSettings: [
                .define("ENABLE_AIAUTOIMAGE_LOGGING", .when(configuration: .debug))
            ]
        ),

        // ============================================================
        // MARK: - Core Engine Layer
        // ============================================================
        .target(
            name: "AIAutoImageCore",
            dependencies: [],
            path: "Sources/AIAutoImageCore",
            exclude: [],
            sources: [
                "Core",
                "Loader",
                "Decoder",
                "Transformer",
                "Renderer",
                "Cache",
                "Predictor",
                "Network",
                "Accessibility",
                "Analytics",
                "Models",
                "Utils",
                "Config",
                "CacheQualityPredictor",
                "Animated",
                "Plugin",
                "Prefetch",
                "Pipelines"
            ],
            swiftSettings: [
                .define("AIAI_DEBUG", .when(configuration: .debug))
            ]
        ),

        // ============================================================
        // MARK: - Unit Tests
        // ============================================================
        .testTarget(
            name: "AIAutoImageTests",
            dependencies: ["AIAutoImage", "AIAutoImageCore"],
            path: "Tests/AIAutoImageTests",
            exclude: [],
            resources: []
        )
    ]
)

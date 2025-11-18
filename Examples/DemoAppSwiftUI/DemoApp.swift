//
//  DemoApp.swift
//  AIAutoImageDemo
//

import SwiftUI
import AIAutoImage

/// The main entry point for the SwiftUI-based AIAutoImage demo application.
///
/// This struct configures global AIAutoImage preferences at launch and
/// initializes the primary window for the app. It uses SwiftUI’s `@main`
/// entrypoint to bootstrap the application lifecycle.
@main
struct DemoApp: App {

    /// Initializes the application and sets up the global AIAutoImage configuration.
    ///
    /// This configuration applies app-wide and affects all image loading,
    /// ML transformations, caching, and optimization behaviors within AIAutoImage.
    init() {

        /// Access the shared global configuration object.
        let cfg = AIImageConfig.shared

        /// High-quality preset:
        /// - HEIC output
        /// - AI transformations enabled
        /// - Best visual fidelity
        cfg.preset = .highQuality

        /// Enables AI-powered enhancements such as:
        /// - Background removal
        /// - Super resolution
        /// - Content-aware cropping
        /// - Auto enhancement
        cfg.enableAIFeatures = true

        /// Enables accessibility features including:
        /// - Auto captions
        /// - Alt text
        /// - AI semantic metadata
        cfg.enableAIAccessibility = true

        /// High performance mode:
        /// - GPU acceleration
        /// - Multi-threaded ML execution
        /// - Faster processing for previews & full-res images
        cfg.performanceMode = .highPerformance

        /// Disable debug logs for cleaner output in demo builds.
        cfg.enableDebugLogs = false
    }

    /// The entry point of the app’s SwiftUI scene hierarchy.
    ///
    /// Defines the window group and the initial `GalleryView` displayed
    /// when the app launches.
    var body: some Scene {
        WindowGroup {
            /// Launch the main gallery screen.
            GalleryView()
        }
    }
}

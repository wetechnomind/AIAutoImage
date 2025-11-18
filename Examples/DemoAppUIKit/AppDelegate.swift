//
//  AppDelegate.swift
//  AIAutoImageDemo
//

import UIKit
import AIAutoImage

/// The main application delegate responsible for configuring global
/// AIAutoImage settings and responding to key application lifecycle events.
///
/// This class bootstraps the UIKit app and initializes global AI-related
/// configurations before any UI is displayed.
@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    /// Called when the application has finished launching.
    ///
    /// This is where we configure global AIAutoImage settings that affect
    /// all image loading and processing throughout the app.
    ///
    /// - Parameters:
    ///   - application: The shared application instance.
    ///   - launchOptions: Optional launch parameters containing system context.
    /// - Returns: A Boolean value indicating whether the launch was successful.
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {

        /// The shared global configuration instance for AIAutoImage.
        let cfg = AIImageConfig.shared

        /// Performance mode:
        /// `.balanced` = best mix of speed + battery efficiency.
        cfg.performanceMode = .balanced

        /// Enables machine-learning powered features such as:
        /// - Auto enhancement
        /// - Super-resolution
        /// - Background removal
        cfg.enableAIFeatures = true

        /// Enables accessibility-focused AI features such as automatic
        /// captioning, alt-text generation, and semantic tagging.
        cfg.enableAIAccessibility = true

        /// Enables built-in debug logs for developers.
        ///
        /// Uses `AILog` actor internally for thread-safe logging.
        cfg.enableDebugLogs = true

        /// High-quality image output preset.
        /// Generates HEIC images with all AI transformations active.
        cfg.preset = .highQuality

        /// Enables smart CDN routing to deliver images faster by automatically
        /// selecting the best regional edge server.
        cfg.enableSmartCDNRouting = true

        return true
    }
}

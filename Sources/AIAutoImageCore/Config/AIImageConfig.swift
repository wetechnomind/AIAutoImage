//
//  AIImageConfig.swift
//  AIAutoImage
//
//  Global configuration for the AIAutoImage framework.
//  This file controls performance, quality presets, CDN rules,
//  caching limits, AI features, telemetry, accessibility, and more.
//

import Foundation
import CoreGraphics
import UIKit

// MARK: - CDN Provider Protocol
// ----------------------------------------------------------------------

/// A protocol defining a pluggable CDN provider.
///
/// Implement this to dynamically rewrite image URLs at runtime,
/// enabling:
/// - Smart multi-CDN routing
/// - Geo-optimized delivery
/// - Model-driven URL selection
///
/// Returning `nil` indicates no override.
public protocol AICDNProvider: Sendable {
    /// Returns an alternative URL for the given original URL.
    /// - Parameter original: The initial requested image URL.
    /// - Returns: A rewritten CDN URL, or `nil` if no override should occur.
    func bestAlternative(for original: URL) async -> URL?
}

/// Default provider that performs **no CDN routing**.
public struct DefaultCDNProvider: AICDNProvider {
    public init() {}
    public func bestAlternative(for original: URL) async -> URL? { nil }
}


// MARK: - Performance Mode
// ----------------------------------------------------------------------

/// Controls the engine’s performance vs. battery tradeoffs.
///
/// Affects decoder behavior, ML usage, threading, and power optimizations.
public enum AIPerformanceMode: Sendable {
    /// Use fewer AI features and background resources.
    case batterySaving

    /// Balanced performance (default).
    case balanced

    /// Maximum performance mode — more threads, more AI.
    case highPerformance
}


// MARK: - Quality Presets
// ----------------------------------------------------------------------

/// Friendly global presets that auto-adjust multiple quality parameters.
public enum AIQualityPreset: Sendable {
    /// Fastest decode path, minimal AI, JPEG preferred.
    case ultraFast

    /// Balanced quality/performance (default).
    case balanced

    /// High-quality images, advanced formats (HEIC), full AI.
    case highQuality
}


// MARK: - Preferred Output Format
// ----------------------------------------------------------------------

/// Preferred storage format for encoded images on disk.
public enum AIPreferredFormat: Sendable {
    case auto
    case jpeg
    case png
    case heic
    case webp
    case avif
}


// MARK: - Global Configuration
// ----------------------------------------------------------------------

/// Global configuration object controlling all AIAutoImage behavior.
///
/// Accessed via:
/// ```swift
/// AIImageConfig.shared
/// ```
///
/// You can customize decoding, caching, AI usage, progressive loading,
/// networking rules, and more.
///
/// The configuration is **not thread-safe by design** — it is intended
/// to be mutated at app startup on the main thread.
public final class AIImageConfig: @unchecked Sendable {

    // MARK: - Singleton
    /// Shared global instance of configuration.
    public static let shared = AIImageConfig()

    private init() {
        applyPreset(.balanced)
    }


    // MARK: - Performance Settings
    // ------------------------------------------------------------------

    /// Controls global performance policy for the engine.
    public var performanceMode: AIPerformanceMode = .balanced


    // MARK: - Quality Settings
    // ------------------------------------------------------------------

    /// High-level preset that automatically adjusts multiple parameters.
    public var preset: AIQualityPreset = .balanced {
        didSet { applyPreset(preset) }
    }

    /// Preferred output format for disk-encoded images.
    public var preferredFormat: AIPreferredFormat = .auto

    /// Optional target decode size (downscales at decode time)
    /// — Useful for performance presets.
    public var targetDecodeSize: CGSize? = nil


    // MARK: - Networking
    // ------------------------------------------------------------------

    /// Allows modifying URL requests globally (headers, tokens, etc).
    /// Called before every network request.
    public var requestModifier: ((inout URLRequest) -> Void)? = nil

    /// Timeout for network image fetch requests.
    public var networkTimeout: TimeInterval = 20.0

    /// Enables intelligent CDN routing via AI/ML-based selection.
    public var enableSmartCDNRouting: Bool = false

    /// The active CDN provider being used for URL rewriting.
    public var cdnProvider: AICDNProvider? = DefaultCDNProvider()


    // MARK: - Caching
    // ------------------------------------------------------------------

    /// Total memory allocated for the main image cache.
    public var memoryCacheTotalCost: Int = 64 * 1024 * 1024  // 64 MB

    /// Maximum disk storage for the AIAutoImage disk cache.
    public var diskCacheLimit: Int = 300 * 1024 * 1024        // 300 MB

    /// Maximum RAM used by CoreML models.
    public var modelMemoryLimit: Int = 200 * 1024 * 1024       // 200 MB


    // MARK: - AI / CoreML
    // ------------------------------------------------------------------

    /// Enables all AI-powered enhancements (sharpness, ML filters, etc).
    public var enableAIFeatures: Bool = true

    /// Restricts ML to **on-device-only** models (no remote ML).
    public var restrictModelsToOnDevice: Bool = true


    // MARK: - Accessibility
    // ------------------------------------------------------------------

    /// Enables AI auto-captioning and object-based accessibility labels.
    public var enableAIAccessibility: Bool = false


    // MARK: - Telemetry / Analytics
    // ------------------------------------------------------------------

    /// Enables anonymous telemetry events for performance tuning.
    public var telemetryEnabled: Bool = false

    /// Server endpoint for telemetry uploads.
    public var telemetryEndpoint: URL? = nil


    // MARK: - Debugging
    // ------------------------------------------------------------------

    /// Enables verbose internal logging.
    public var enableDebugLogs: Bool = false

    /// Enables performance metrics for decoder + pipeline stages.
    public var enablePerformanceMetrics: Bool = false


    // MARK: - Progressive Loading
    // ------------------------------------------------------------------

    /// Enables progressive (partial) decoding + rendering.
    ///
    /// When enabled:
    /// - The loader streams partial JPEG chunks
    /// - Decoder reconstructs intermediate images
    /// - UI gets incremental previews
    public var enableProgressiveLoading: Bool = false


    // MARK: - Preset Logic
    // ------------------------------------------------------------------

    /// Applies preset rules to multiple related settings.
    private func applyPreset(_ preset: AIQualityPreset) {
        switch preset {

        case .ultraFast:
            // Downscale aggressively for speed
            targetDecodeSize = CGSize(width: 800, height: 800)
            preferredFormat = .jpeg
            enableAIFeatures = false

        case .balanced:
            targetDecodeSize = nil
            preferredFormat = .auto
            enableAIFeatures = true

        case .highQuality:
            targetDecodeSize = nil
            preferredFormat = .heic
            enableAIFeatures = true
        }
    }
}

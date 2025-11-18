//
//  AIImageConfig.swift
//  AIAutoImage
//
//  Global configuration for the AIAutoImage framework.
//  Controls performance, quality, caching, networking, CDN rules,
//  AI features, telemetry, accessibility, and more.
//

import Foundation
import CoreGraphics

#if canImport(UIKit)
import UIKit
#endif

// MARK: - CDN Provider Protocol
// ----------------------------------------------------------------------

/// A protocol defining a modular CDN provider.
///
/// Implement this to dynamically rewrite image URLs at runtime.
///
/// Useful for:
/// - Smart multi-CDN routing
/// - Regional edge server selection
/// - AB testing between CDNs
/// - AI-driven URL rewriting
public protocol AICDNProvider: Sendable {
    func bestAlternative(for original: URL) async -> URL?
}

/// Default provider that performs **no CDN rewriting**.
public struct DefaultCDNProvider: AICDNProvider {
    public init() {}
    public func bestAlternative(for original: URL) async -> URL? { nil }
}


// MARK: - Performance Mode
// ----------------------------------------------------------------------

/// Controls decoder performance, threading, and ML cost.
public enum AIPerformanceMode: Sendable {
    case batterySaving      // Low power usage
    case balanced           // Best mix of speed + battery
    case highPerformance    // Max threads, full AI
}


// MARK: - Quality Presets
// ----------------------------------------------------------------------

/// High-level presets that configure internal parameters.
public enum AIQualityPreset: Sendable {
    case ultraFast   // Minimal AI, downscaled decoding
    case balanced    // Default
    case highQuality // Full AI, HEIC preferred
}


// MARK: - Preferred Output File Format
// ----------------------------------------------------------------------

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

/// The global configuration for AIAutoImage.
///
/// Access via:
/// ```swift
/// let cfg = AIImageConfig.shared
/// cfg.performanceMode = .balanced
/// ```
///
/// ⚠️ This object is **not thread-safe**.
/// Modify only at app startup (usually AppDelegate/SceneDelegate).
///
@MainActor
public final class AIImageConfig {

    // MARK: Singleton

    public static let shared = AIImageConfig()

    private init() {
        applyPreset(.balanced)
    }


    // MARK: - Performance
    // ------------------------------------------------------------------

    /// Controls overall processing speed and thread usage.
    public var performanceMode: AIPerformanceMode = .balanced


    // MARK: - Quality
    // ------------------------------------------------------------------

    /// Easy preset that adjusts multiple parameters together.
    public var preset: AIQualityPreset = .balanced {
        didSet { applyPreset(preset) }
    }

    /// Preferred format for **encoded disk output**.
    public var preferredFormat: AIPreferredFormat = .auto

    /// Optional downscale target to speed up decoding and reduce memory.
    public var targetDecodeSize: CGSize? = nil


    // MARK: - Networking
    // ------------------------------------------------------------------

    /// Called before every network request.
    ///
    /// Useful for API keys, tokens, headers, AB testing, etc.
    public var requestModifier: ((inout URLRequest) -> Void)? = nil

    /// Fetch timeout for all image downloads.
    public var networkTimeout: TimeInterval = 20.0

    /// Enables global CDN routing.
    public var enableSmartCDNRouting: Bool = false

    /// Custom CDN provider.
    public var cdnProvider: AICDNProvider? = DefaultCDNProvider()


    // MARK: - Caching (Memory + Disk)
    // ------------------------------------------------------------------

    /// Maximum memory used by image cache.
    public var memoryCacheTotalCost: Int = 64 * 1024 * 1024 // 64 MB

    /// Maximum disk cache size.
    public var diskCacheLimit: Int = 300 * 1024 * 1024 // 300 MB

    /// Maximum RAM allowed for ML models.
    public var modelMemoryLimit: Int = 200 * 1024 * 1024 // 200 MB


    // MARK: - AI / CoreML
    // ------------------------------------------------------------------

    /// Enables ML filters, enhancement, scoring, etc.
    public var enableAIFeatures: Bool = true

    /// Restricts ML to on-device only.
    public var restrictModelsToOnDevice: Bool = true


    // MARK: - Accessibility
    // ------------------------------------------------------------------

    /// Enables auto-captioning + semantic labeling.
    public var enableAIAccessibility: Bool = false


    // MARK: - Telemetry
    // ------------------------------------------------------------------

    /// Enables anonymous performance telemetry.
    public var telemetryEnabled: Bool = false

    /// Endpoint for telemetry submission.
    public var telemetryEndpoint: URL? = nil


    // MARK: - Debugging
    // ------------------------------------------------------------------

    /// Verbose internal logging.
    public var enableDebugLogs: Bool = false

    /// Enables detailed performance profiling.
    public var enablePerformanceMetrics: Bool = false


    // MARK: - Progressive Decoding
    // ------------------------------------------------------------------

    /// Enables incremental decode & render (JPEG progressive streaming).
    public var enableProgressiveLoading: Bool = false


    // MARK: - Preset Logic
    // ------------------------------------------------------------------

    /// Internal preset rules.
    private func applyPreset(_ preset: AIQualityPreset) {
        switch preset {

        case .ultraFast:
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

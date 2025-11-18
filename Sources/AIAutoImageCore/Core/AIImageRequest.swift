//
//  AIImageRequest.swift
//  AIAutoImageCore
//
//  Primary request model representing a single image load operation.
//  This struct defines everything the pipeline needs:
//  • URL + network configuration
//  • Progressive decode toggles
//  • Expected format hints
//  • Transformations
//  • AI scoring metadata
//  • Cache policy
//

import Foundation
import CoreGraphics
import UIKit

/// Represents a single image loading operation handled by the AIAutoImage pipeline.
///
/// `AIImageRequest` is the primary configuration object for every image fetch,
/// decode, transform, and render step.
///
/// It supports:
/// - URL + network configuration
/// - AI-aware category & usage metadata
/// - Format hints to accelerate decoding
/// - Progressive loading for streaming-friendly formats
/// - Per-request HTTP customization
/// - Full transformation pipeline customization
/// - Fine-grained memory/disk cache control
///
/// Example:
/// ```swift
/// var req = AIImageRequest(url: url)
/// req.targetPixelSize = CGSize(width: 600, height: 600)
/// req.transformations = [AIResize(width: 300)]
/// req.isProgressiveEnabled = true
/// req.preferredFormat = .auto
/// ```
public struct AIImageRequest: Sendable {

    // MARK: - Required

    /// The source `URL` of the image to load.
    /// This may represent remote HTTP(S) images or local file URLs.
    public let url: URL


    // MARK: - Predictive Metadata

    /// High-level category used by AI predictors and prefetch schedulers.
    ///
    /// Helps the system determine:
    /// - LOD (Level-of-Detail) strategy
    /// - Smart cache priority
    /// - Network prefetch ordering
    public var contentCategory: AIImageCategory = .unknown

    /// Context describing *how* the image will be used.
    ///
    /// Examples:
    /// - `.gallery` — smaller, quicker
    /// - `.detail` — high clarity
    /// - `.background` — low priority
    public var usageContext: AIRequestContext = .normal

    /// Global quality preference affecting the entire pipeline.
    ///
    /// - `.adaptive` allows the system to pick the best tradeoff
    /// - `.high` increases CPU/GPU workload
    public var quality: AIQuality = .adaptive


    // MARK: - Format / Decode Options

    /// Preferred output format.
    /// The pipeline may override internally for faster decoding.
    public var preferredFormat: AIImageFormat = .auto

    /// Optional hint used to speed up decoder decisions.
    /// Example: If you know the image is WebP, set `.webp`.
    public var expectedFormatHint: AIImageFormat? = nil

    /// Optional downsampling target used **before** decoding.
    ///
    /// Significantly improves memory usage for large images.
    /// Setting this is strongly recommended for lists & thumbnails.
    public var targetPixelSize: CGSize? = nil

    /// Enables or disables AI enhancements for this specific request.
    ///
    /// Overrides the global configuration (`AIImageConfig.shared.enableAIFeatures`).
    public var enableAIFeatures: Bool? = nil


    // MARK: - Transformations

    /// Ordered list of transformations applied after decoding.
    ///
    /// Example:
    /// ```swift
    /// req.transformations = [
    ///     AIResize(width: 300),
    ///     AIContrastBoost(),
    ///     AICrop(rect: ...)
    /// ]
    /// ```
    public var transformations: [AITransformation] = []

    /// Optional pre-decoded thumbnail for UI placeholders.
    public var thumbnailImage: UIImage? = nil


    // MARK: - Cache Policy

    /// If `true`, memory cache is skipped entirely for this request.
    public var bypassMemoryCache: Bool = false

    /// If `true`, disk cache is skipped entirely.
    public var bypassDiskCache: Bool = false

    /// Enables progressive decoding when supported by format:
    /// - JPEG
    /// - WebP
    /// - AVIF
    public var isProgressiveEnabled: Bool = false

    /// Explicit variant selection (thumb/small/medium/large/full/custom).
    /// Overshadows AI-driven variant selection.
    public var variant: AIImageVariant? = nil

    /// Priority used internally for smart scheduling and AI-driven loading queues.
    /// Range: 0.0–1.0 (default: 0.5).
    public var priority: Float = 0.5


    // MARK: - Network Settings

    /// Optional per-request timeout override.
    public var timeoutOverride: TimeInterval? = nil

    /// Optional per-request HTTP modifier.
    ///
    /// Must be `@Sendable` due to struct conforming to `Sendable`.
    ///
    /// Example:
    /// ```swift
    /// req.requestModifier = { req in
    ///     req.addValue("Bearer token", forHTTPHeaderField: "Authorization")
    /// }
    /// ```
    public var requestModifier: (@Sendable (inout URLRequest) -> Void)? = nil


    // MARK: - Initializer

    /// Creates a new request for the specified image URL.
    public init(url: URL) {
        self.url = url
    }
}


// MARK: - URLRequest Builder
extension AIImageRequest {

    /// Builds a fully configured `URLRequest` applying:
    /// - Global modifiers (`AIImageConfig.shared.requestModifier`)
    /// - Per-request modifier (`requestModifier`)
    /// - Timeout overrides
    ///
    /// This runs inside the loader stage of the pipeline.
    func makeURLRequest() -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutOverride ?? AIImageConfig.shared.networkTimeout

        // Global modifier
        if let globalMod = AIImageConfig.shared.requestModifier {
            globalMod(&request)
        }

        // Per-request modifier
        if let overrideMod = requestModifier {
            overrideMod(&request)
        }

        return request
    }
}


// MARK: - Cache Key Construction
public extension AIImageRequest {

    /// Generates a stable cache key representing:
    /// - URL
    /// - Format preferences
    /// - Downsampling size
    /// - Enabled/disabled AI features
    /// - All transformation identifiers
    ///
    /// This ensures that:
    /// - Memory cache
    /// - Disk cache
    /// - Transform cache
    /// all remain consistent and collision-free.
    var effectiveCacheKey: String {
        var parts: [String] = []

        parts.append(url.absoluteString)
        parts.append("fmt:\(preferredFormat.rawValue)")

        if let hint = expectedFormatHint {
            parts.append("hint:\(hint.rawValue)")
        }

        if let size = targetPixelSize {
            parts.append("sz:\(Int(size.width))x\(Int(size.height))")
        }

        if enableAIFeatures == false {
            parts.append("noai")
        }

        if !transformations.isEmpty {
            let t = transformations.map { $0.cacheIdentifier }.joined(separator: "|")
            parts.append("tr:\(t)")
        }

        return parts.joined(separator: "||")
    }
}

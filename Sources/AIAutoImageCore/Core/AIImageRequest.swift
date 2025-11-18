//
//  AIImageRequest.swift
//  AIAutoImageCore
//

import Foundation
import CoreGraphics
import UIKit

public struct AIImageRequest: Sendable {

    // MARK: - Required

    public let url: URL

    // MARK: - Predictive Metadata
    public var contentCategory: AIImageCategory = .unknown
    public var usageContext: AIRequestContext = .normal
    public var quality: AIQuality = .adaptive

    // MARK: - Format / Decode Options
    public var preferredFormat: AIImageFormat = .auto
    public var expectedFormatHint: AIImageFormat? = nil
    public var targetPixelSize: CGSize? = nil
    public var enableAIFeatures: Bool? = nil

    // MARK: - Transformations
    public var transformations: [AITransformation] = []
    public var thumbnailImage: UIImage? = nil

    // MARK: - Cache Policy
    public var bypassMemoryCache: Bool = false
    public var bypassDiskCache: Bool = false
    public var isProgressiveEnabled: Bool = false
    public var variant: AIImageVariant? = nil
    public var priority: Float = 0.5

    // MARK: - Network Settings
    public var timeoutOverride: TimeInterval? = nil
    public var requestModifier: (@Sendable (inout URLRequest) -> Void)? = nil

    // MARK: - Init
    // -------------------------------------------
        // Required base initializer (DO NOT REMOVE)
        // -------------------------------------------
        public init(url: URL) {
            self.url = url
        }

        // -------------------------------------------
        // Convenience initializer (your new API)
        // -------------------------------------------
        public init(
            url: URL,
            transformations: [AITransformation],
            context: AIRequestContext
        ) {
            self.url = url
            self.transformations = transformations
            self.usageContext = context
        }
}


// MARK: - MAIN-ACTOR CONFIG SNAPSHOT (SAFE)
@MainActor
private func _resolveGlobalNetworkConfig()
-> (timeout: TimeInterval,
    globalModifier: ((inout URLRequest) -> Void)?) {

    let cfg = AIImageConfig.shared
    return (cfg.networkTimeout, cfg.requestModifier)
}


// MARK: - URLRequest Builder (NONISOLATED & SAFE)
extension AIImageRequest {

    /// Builds a fully configured `URLRequest` applying:
    /// - Global modifiers (`AIImageConfig.shared.requestModifier`)
    /// - Per-request modifier (`requestModifier`)
    /// - Timeout overrides
    ///
    /// This is concurrency-safe and does **not** force the pipeline
    /// onto the main actor.
    @MainActor func makeURLRequest() -> URLRequest {

        // 🟢 Hop to main actor ONLY to read global config (safe)
        let (globalTimeout, globalMod) = _resolveGlobalNetworkConfig()

        var request = URLRequest(url: url)

        // Timeout
        request.timeoutInterval = timeoutOverride ?? globalTimeout

        // Global modifier
        if let globalMod {
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

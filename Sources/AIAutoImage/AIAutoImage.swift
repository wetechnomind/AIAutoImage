//
//  AIAutoImage.swift
//  AIAutoImage
//
//  High-level image loading, processing, and AI-enhancement engine.
//  Provides:
//   - Progressive streaming loader
//   - Unified pipeline integration
//   - Smart AI post-processing (Vision + CoreML)
//   - Automatic caching + prefetching
//   - UIKit helpers (UIImageView integration)
//

import Foundation
import UIKit
import AIAutoImageCore
import Vision
import CoreML

// MARK: - Utility Callback Boxes

/// A Sendable-safe wrapper for non-Sendable UI callback closures.
///
/// Use this to expose progressive image chunks from background tasks
/// while ensuring thread safety when interacting with UIKit types.
///
/// This wrapper allows safely transferring a closure across actor boundaries.
public struct ProgressiveBox: @unchecked Sendable {
    /// Underlying UI callback.
    let callback: (UIImage) -> Void

    /// - Parameter callback: Executed whenever a new progressive chunk is decoded.
    public init(_ callback: @escaping (UIImage) -> Void) {
        self.callback = callback
    }
}

/// A MainActor-isolated wrapper for UI update closures.
///
/// Because UIKit requires main-thread execution, this box ensures
/// the underlying closure always executes on the main actor.
public struct MainActorUIImageCallbackBox: @unchecked Sendable {
    let call: (UIImage) -> Void

    /// - Parameter call: Closure to be executed on `@MainActor`.
    public init(_ call: @escaping (UIImage) -> Void) { self.call = call }
}

// MARK: - Core Public API

/// The main façade for all image loading and AI enhancement operations.
///
/// `AIAutoImage` unifies:
///  - Network → Decoder → Transformer → AI Enhancer → Cache
///  - Progressive image streaming for URLs
///  - AI-accelerated post-processing (Vision/CoreML)
///  - Integrates with `UIImageView` using async pipelines
///
/// All public operations are performed on `@MainActor` to ensure UIKit safety.
@MainActor
public final class AIAutoImage {

    // MARK: - Singleton

    /// Shared global instance of the image engine.
    public static let shared = AIAutoImage()
    private init() {}

    // MARK: - Core Engine Components

    /// High-performance pipeline responsible for:
    /// decoding → transforming → delivering images.
    private let pipeline = AIImagePipeline.shared

    /// Request lifecycle + task management.
    private let manager = AIAutoImageManager.shared

    /// Centralized disk+memory cache layer.
    private let cache = AICache.shared

    /// Background queue used for Vision/CoreML analytics.
    private let analysisQueue = DispatchQueue(label: "ai.autoimage.analysis")

    // =====================================================================
    // MARK: - PUBLIC LOADER (PROGRESSIVE + AI ENHANCEMENT)
    // =====================================================================

    /**
     Loads an image into a `UIImageView` with support for:

     - Progressive JPEG/HEIC decoding
     - Full async pipeline (network → decode → AI Enhance)
     - Automatic cancellation on reuse
     - Placeholder support
     - AI accessibility tagging
     - Saliency + category analytics

     - Parameters:
       - url: The image URL to load.
       - imageView: Target view where the image will be displayed.
       - placeholder: Optional placeholder image.
       - config: Optional request configuration (resizing, mode, cache policy).
       - progressHandler: Called every time a progressive chunk is decoded.
     */
    public func load(
        _ url: URL,
        into imageView: UIImageView,
        placeholder: UIImage? = nil,
        config: AIImageRequest? = nil,
        progressHandler: ((UIImage) -> Void)? = nil
    ) {
        let request = config ?? AIImageRequest(url: url)

        if let ph = placeholder { imageView.image = ph }

        // Cancel previous tasks and ensure input consistency
        imageView.ai_cancelLoad()
        imageView.ai_setCurrentURL(url)

        // Wrap progressive handler in a MainActor-safe box
        let callbackBox = MainActorUIImageCallbackBox { [weak imageView, handler = progressHandler] img in
            Task { @MainActor in
                guard let iv = imageView, iv.ai_currentURL == url else { return }
                iv.image = img   // Update UI
                handler?(img)    // Forward partial update
            }
        }

        // Convert callback to Sendable for background tasks
        let sendableProgressive: (@Sendable (UIImage?) -> Void)? = { [box = callbackBox] maybeImg in
            guard let img = maybeImg else { return }
            box.call(img)
        }

        Task {
            do {
                // Decode + process progressively
                let decodedImage = try await pipeline.process(
                    request,
                    sourceURL: url,
                    progress: nil,
                    progressive: sendableProgressive
                )

                // Ensure this image view hasn't been reused
                guard imageView.ai_currentURL == url else { return }

                // AI Post-processing
                let enhanced = await applyAIPostProcessing(decodedImage)

                // Final UI assignment
                Task { @MainActor in imageView.image = enhanced }

                // Accessibility metadata (optional)
                if AIImageConfig.shared.enableAIAccessibility {
                    AIAccessibility.shared.applyToImageView(imageView, image: enhanced)
                }

                // Background analytics
                await AIAnalytics.shared.recordImageSaliency(enhanced)
                await AIAnalytics.shared.recordImageCategory(enhanced)

            } catch {
                await AILog.shared.warning("Image load failed: \(error.localizedDescription)")
            }
        }
    }

    // =====================================================================
    // MARK: - ASYNC IMAGE API (DIRECT RETURN)
    // =====================================================================

    /// Loads and returns a fully processed image synchronously (no streaming).
    ///
    /// - Parameter request: Request describing size, URL, cache behaviour, etc.
    /// - Returns: A fully decoded + AI-enhanced image.
    public func image(for request: AIImageRequest) async throws -> UIImage {
        let img = try await pipeline.process(request, sourceURL: request.url, progress: nil, progressive: nil)
        return await applyAIPostProcessing(img)
    }

    /**
     Loads an image with progressive streaming support.

     - Parameter progressive:
       A Sendable closure receiving each partial progressive image chunk.
     */
    public func image(
        for request: AIImageRequest,
        progressive: (@Sendable (UIImage?) -> Void)?
    ) async throws -> UIImage {

        let img = try await pipeline.process(
            request,
            sourceURL: request.url,
            progress: nil,
            progressive: progressive
        )

        return await applyAIPostProcessing(img)
    }

    /// Convenience wrapper for URLs.
    public func image(for url: URL) async throws -> UIImage {
        try await image(for: AIImageRequest(url: url))
    }

    // =====================================================================
    // MARK: - Prefetching (Warm Pipelines)
    // =====================================================================

    /**
     Prefetches a list of URLs:

     - Warms decoder stages
     - Warms CoreML models (sharpness predictor)
     - Reduces first-load latency dramatically
     */
    public func prefetch(_ urls: [URL]) {
        Task.detached(priority: .background) {
            for url in urls {
                let req = AIImageRequest(url: url)
                _ = try? await self.pipeline.process(req, sourceURL: url)
                await self.preWarmMLPipelines()
            }
        }
    }

    // =====================================================================
    // MARK: - Cancel / Cache Controls
    // =====================================================================

    /// Cancels an active image load for a given URL.
    public func cancel(_ url: URL) {
        pipeline.cancel(url)
    }

    /// Removes a specific image from cache.
    public func removeFromCache(for url: URL) {
        Task { await cache.remove(forKey: url.absoluteString) }
    }

    /// Clears only in-memory cached images.
    public func clearMemoryCache() {
        Task { await cache.clearMemory() }
    }

    /// Clears on-disk cached images.
    public func clearDiskCache() {
        Task { await cache.clearDisk() }
    }

    /// Clears all memory + disk caches.
    public func clearAllCaches() {
        Task {
            await cache.clearMemory()
            await cache.clearDisk()
        }
    }
}


// ====================================================================
// MARK: - AI Post-Processing (Vision + CoreML Enhancements)
// ====================================================================

@MainActor
extension AIAutoImage {

    /**
     Runs all enabled AI enhancement passes in parallel:

     - Sharpness correction (CoreML)
     - Contrast enhancement (Vision, iOS 15+)
     - ML-based denoising

     `withTaskGroup` returns the first successfully enhanced output.
     If all enhancements fail, the original image is returned.

     - Parameter image: The original decoded image.
     */
    internal func applyAIPostProcessing(_ image: UIImage) async -> UIImage {
        guard AIImageConfig.shared.enableAIFeatures else { return image }

        return await withTaskGroup(of: UIImage?.self) { group in

            // Sharpness Enhancer
            group.addTask {
                let val = await AICacheQualityPredictor.shared.predictSharpness(for: image)
                return image.ai_sharpen(amount: CGFloat(val))
            }

            // Contrast Boost (Vision) — available on iOS 15+
            group.addTask {
                if #available(iOS 15.0, *) {
                    return await image.ai_contrastBoostedUsingVision()
                } else {
                    return nil
                }
            }

            // ML Denoiser
            group.addTask {
                await image.ai_denoisedByML()
            }

            // Return first valid enhanced image
            for await result in group {
                if let img = result { return img }
            }

            return image
        }
    }

    /// Warms CoreML sharpness model — dramatically reduces latency on first use.
    func preWarmMLPipelines() async {
        _ = await AICacheQualityPredictor.shared.predictSharpness(for: UIImage())
    }
}

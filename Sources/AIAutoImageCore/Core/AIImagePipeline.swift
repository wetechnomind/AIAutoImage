//
//  AIImagePipeline.swift
//  AIAutoImageCore
//
//  Unified AI-powered image processing pipeline.
//
//  Responsibilities:
//   • Network fetch (with streaming support)
//   • Progressive decoding using AIProgressiveDecoder
//   • Full decode (static / animated)
//   • Transform pipeline (resize, crop, ML transforms, filters)
//   • Plugin transforms (custom user-defined pipeline)
//   • Rendering + output processing
//   • Analytics + metadata extraction
//
//  Stages:
//    fetch → decode → transform → render
//

import Foundation
import UIKit

/// Represents major stages in the image pipeline.
///
/// Used for progress reporting through:
/// ```swift
/// (AIImagePipelineStage, Double) -> Void
/// ```
public enum AIImagePipelineStage: String, Sendable {
    case fetch
    case decode
    case transform
    case render
}

/// Central orchestrator of all image processing stages.
///
/// This class wires together:
///  - Loader (networking + streaming)
///  - Decoder (JPEG/PNG/HEIC/WebP + animated GIF/APNG/HEIC)
///  - Transformer (resize, crop, ML effects, LOD tuning)
///  - Renderer (final UI-ready output)
///  - Model Manager (CoreML model loading)
///
/// The pipeline supports:
///  • Progressive decoding
///  • Async/await concurrency
///  • Transformation caching
///  • Plugin-based extension
///  • Full AI metadata extraction
public final class AIImagePipeline: @unchecked Sendable {

    // MARK: - Components
    // ------------------------------------------------------------------

    /// Network + data loader.
    public let loader: AILoader

    /// Image format decoder (static or animated).
    public let decoder: AIDecoder

    /// Transformation engine (resize, crop, filters, ML transforms).
    public let transformer: AITransformer

    /// Final renderer (colorspace fix, PNG->RGB, orientation fixes).
    public let renderer: AIRenderer

    /// Dedicated networking engine for advanced control.
    public let network: AINetwork

    /// Global CoreML model manager.
    public let modelManager: AIModelManager


    // MARK: - Init
    // ------------------------------------------------------------------

    /// Creates a new pipeline with injected components.
    ///
    /// You can override individual components for:
    /// - Custom networking
    /// - Custom decoders
    /// - Custom transforms
    /// - Unit testing
    ///
    /// - Parameters:
    ///   - loader: Fetches remote/local image data.
    ///   - decoder: Handles JPEG/PNG/HEIC/WebP + animated formats.
    ///   - transformer: Applies resize + ML transforms.
    ///   - renderer: Fixes orientation + colorspace.
    ///   - network: Low-level networking layer.
    ///   - modelManager: CoreML model provider.
    public init(
        loader: AILoader = AILoader(),
        decoder: AIDecoder = AIDecoder(),
        transformer: AITransformer = AITransformer(),
        renderer: AIRenderer = AIRenderer(),
        network: AINetwork = AINetwork(),
        modelManager: AIModelManager = AIModelManager.shared
    ) {
        self.loader = loader
        self.decoder = decoder
        self.transformer = transformer
        self.renderer = renderer
        self.network = network
        self.modelManager = modelManager
    }

    /// MainActor-protected analytics access.
    @MainActor
    public var analytics: AIAnalytics {
        AIAnalytics.shared
    }


    // MARK: - PROCESS
    // ------------------------------------------------------------------

    /**
     Executes the entire image processing pipeline.

     Pipeline flow:
     1. **Fetch**
        - Streaming or full fetch
        - Progressive preview generation
     2. **Decode**
        - Static images & animated formats
        - Target pixel downscaling
     3. **Metadata Extraction**
        - EXIF, IPTC, AI metadata, faces, saliency
     4. **Transformations**
        - Resize, crop, ML filters, LOD adjustments
        - Transform cache lookup for performance
     5. **Plugin Transforms**
        - User-defined custom pipeline
     6. **Render**
        - Final orientation & RGB output
     7. **Analytics**
        - Telemetry + saliency + category logging

     - Parameters:
       - request: The structured image request (URL + transforms).
       - sourceURL: The URL used for analytics + telemetry.
       - progress: Optional stage progress callback.
       - progressive: Optional callback for progressive streaming previews.
     - Returns: A fully decoded & transformed `UIImage`.
     */
    public func process(
        _ request: AIImageRequest,
        sourceURL: URL,
        progress: ((AIImagePipelineStage, Double) -> Void)? = nil,
        progressive: (@MainActor @Sendable (UIImage?) -> Void)? = nil
    ) async throws -> UIImage {

        // Safety: ensure task wasn't cancelled
        try Task.checkCancellation()

        // ------------------------------------------------------
        // PROGRESSIVE HANDLER WRAPPER
        // ------------------------------------------------------

        /// A Sendable-safe wrapper for progressive callbacks.
        final class ProgressiveBox: @unchecked Sendable {
            let call: (UIImage?) -> Void
            init(_ call: @escaping (UIImage?) -> Void) { self.call = call }
        }

        // ------------------------------------------------------
        // FETCH
        // ------------------------------------------------------
        progress?(.fetch, 0.0)

        let urlRequest = request.makeURLRequest()

        let progressiveEnabled =
            (progressive != nil &&
             (request.isProgressiveEnabled || AIImageConfig.shared.enableProgressiveLoading))

        // Compute target max pixel size only once
        let maxPixelSizeInt: Int? = {
            if let sz = request.targetPixelSize {
                return Int(max(sz.width, sz.height))
            }
            return nil
        }()

        let data: Data

        if progressiveEnabled {

            // STREAMING MODE
            data = try await loader.fetchStream(request: urlRequest) { partialData, finished in
                guard !finished else { return }

                // Decode partials asynchronously
                Task {
                    // Ask AIProgressiveDecoder for "best" partial frame
                    let aiBest = await AIProgressiveDecoder.shared.incrementalDecode(
                        accumulatedData: partialData,
                        isFinal: finished,
                        maxPixelSize: maxPixelSizeInt
                    )

                    if let best = aiBest {
                        Task { @MainActor in progressive?(best) }
                        return
                    }

                    // Fallback partial decode
                    if let ui = UIImage(data: partialData) {
                        Task { @MainActor in progressive?(ui) }
                    }
                }
            }

        } else {
            // FULL FETCH MODE
            data = try await loader.fetch(
                request: urlRequest,
                network: network,
                config: AIImageConfig.shared
            )
        }

        progress?(.fetch, 1.0)
        try Task.checkCancellation()

        // ------------------------------------------------------
        // DECODE
        // ------------------------------------------------------
        progress?(.decode, 0.0)

        let decoded = try await decoder.decode(
            data,
            request: request,
            targetPixelSize: request.targetPixelSize ?? AIImageConfig.shared.targetDecodeSize
        )

        var image = decoded.image

        progress?(.decode, 1.0)
        try Task.checkCancellation()


        // ------------------------------------------------------
        // METADATA EXTRACTION
        // ------------------------------------------------------
        let metaBox = await AIImageMetadataCenter.shared.extractAll(from: image)
        await analytics.recordMetadata(for: sourceURL, metadata: metaBox)

        let metadataKeysSummary = metaBox.value.keys.joined(separator: ",")

        // Notify plugins
        Task {
            await AIPluginManager.shared.notifyImageDecoded(
                UIImage(),
                context: ["metadata_keys": metadataKeysSummary]
            )
        }

        // ------------------------------------------------------
        // TRANSFORMATIONS + TRANSFORM CACHE
        // ------------------------------------------------------
        if !request.transformations.isEmpty {
            progress?(.transform, 0.0)

            let reqKey = request.effectiveCacheKey
            let transformID = request.transformations.map { $0.cacheIdentifier }.joined(separator: "|")
            let tKey = AITransformCache.transformCacheKey(for: reqKey, transformId: transformID)

            if let cached = await AITransformCache.shared.retrieve(forKey: tKey) {
                image = cached
                progress?(.transform, 1.0)

            } else {
                let transformed = try await transformer.applyTransformations(
                    to: image,
                    using: request.transformations,
                    modelManager: modelManager,
                    progress: { pct in progress?(.transform, pct) }
                )

                await AITransformCache.shared.store(transformed, forKey: tKey)
                image = transformed
                progress?(.transform, 1.0)
            }
        }

        try Task.checkCancellation()


        // ------------------------------------------------------
        // PLUGIN PIPELINE (after built-in transforms)
        // ------------------------------------------------------
        image = await AITransformPipeline.shared.applyAll(to: image)


        // ------------------------------------------------------
        // RENDER
        // ------------------------------------------------------
        progress?(.render, 0.0)

        let output = await renderer.render(image, request: request)

        progress?(.render, 1.0)
        try Task.checkCancellation()


        // ------------------------------------------------------
        // ANALYTICS + TELEMETRY
        // ------------------------------------------------------
        await analytics.recordPipelineCompletion(
            url: sourceURL,
            format: request.preferredFormat.rawValue,
            transformations: request.transformations
        )

        return output
    }


    // MARK: - CANCEL
    // ------------------------------------------------------------------

    /// Cancels any in-flight network operation for the specified URL.
    ///
    /// This forcibly cancels loaders, but does not affect transformed results.
    public func cancel(_ url: URL) {
        Task { await loader.cancel(url) }
    }
}

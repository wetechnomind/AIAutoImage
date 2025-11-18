//
//  AIImagePipeline.swift
//  AIAutoImageCore
//

import Foundation
import UIKit

public enum AIImagePipelineStage: String, Sendable {
    case fetch
    case decode
    case transform
    case render
}

// MARK: - MainActor Snapshots
// ---------------------------

@MainActor
private func _snapshotGlobalPipelineConfig()
-> (enableProgressive: Bool,
    targetDecodeSize: CGSize?,
    analytics: AIAnalytics)
{
    let cfg = AIImageConfig.shared
    return (cfg.enableProgressiveLoading,
            cfg.targetDecodeSize,
            AIAnalytics.shared)
}
    

// MARK: - Pipeline
// ----------------

public final class AIImagePipeline: @unchecked Sendable {

    public let loader: AILoader
    public let decoder: AIDecoder
    public let transformer: AITransformer
    public let renderer: AIRenderer
    public let network: AINetwork
    public let modelManager: AIModelManager

    @MainActor
    public var analytics: AIAnalytics {
        AIAnalytics.shared
    }

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

    
    // MARK: PROCESS
    // -------------

    public func process(
        _ request: AIImageRequest,
        sourceURL: URL,
        progress: ((AIImagePipelineStage, Double) -> Void)? = nil,
        progressive: (@MainActor @Sendable (UIImage?) -> Void)? = nil
    ) async throws -> UIImage {

        try Task.checkCancellation()

        // ------------------------------------------
        // SNAPSHOT MAIN-ACTOR CONFIG FIRST (SAFE)
        // ------------------------------------------
        let (globalProgressiveEnabled,
             globalTargetDecodeSize,
             analytics) = await _snapshotGlobalPipelineConfig()


        // ------------------------------------------------------
        // URLRequest (also main-actor safe)
        // ------------------------------------------------------
        let urlRequest = await request.makeURLRequest()


        // ------------------------------------------------------
        // PROGRESSIVE ENABLED?
        // ------------------------------------------------------
        let progressiveEnabled =
            progressive != nil &&
            (request.isProgressiveEnabled || globalProgressiveEnabled)


        // Cache target size once
        let maxPixelSizeInt: Int? = {
            let px = request.targetPixelSize ?? globalTargetDecodeSize
            if let px { return Int(max(px.width, px.height)) }
            return nil
        }()


        // ------------------------------------------------------
        // FETCH
        // ------------------------------------------------------
        progress?(.fetch, 0.0)

        let data: Data

        if progressiveEnabled {
            // STREAMING
            data = try await loader.fetchStream(request: urlRequest) { partial, finished in
                guard !finished else { return }

                Task {
                    let best = await AIProgressiveDecoder.shared.incrementalDecode(
                        accumulatedData: partial,
                        isFinal: finished,
                        maxPixelSize: maxPixelSizeInt
                    )

                    if let best {
                        Task { @MainActor in progressive?(best) }
                        return
                    }

                    if let ui = UIImage(data: partial) {
                        Task { @MainActor in progressive?(ui) }
                    }
                }
            }

        } else {
            // FULL FETCH
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
            targetPixelSize: request.targetPixelSize ?? globalTargetDecodeSize
        )

        var image = decoded.image

        progress?(.decode, 1.0)
        try Task.checkCancellation()


        // ------------------------------------------------------
        // METADATA EXTRACTION + ANALYTICS
        // ------------------------------------------------------
        let metaBox = await AIImageMetadataCenter.shared.extractAll(from: image)
        await analytics.recordMetadata(for: sourceURL, metadata: metaBox)

        let metadataKeysSummary = metaBox.value.keys.joined(separator: ",")

        let imgCopy = image   // isolate before escaping Task

        Task.detached { @Sendable in
            await AIPluginManager.shared.notifyImageDecoded(
                imgCopy,
                context: ["metadata_keys": metadataKeysSummary]
            )
        }



        // ------------------------------------------------------
        // TRANSFORMATIONS + CACHE
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
        // PLUGIN PIPELINE
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
        // ANALYTICS FINAL
        // ------------------------------------------------------
        await analytics.recordPipelineCompletion(
            url: sourceURL,
            format: request.preferredFormat.rawValue,
            transformations: request.transformations
        )

        return output
    }


    // MARK: CANCEL
    public func cancel(_ url: URL) {
        Task { await loader.cancel(url) }
    }
}

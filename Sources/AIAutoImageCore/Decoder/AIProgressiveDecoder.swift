//
//  AIProgressiveDecoder.swift
//  AIAutoImageCore
//

import Foundation
import UIKit
import ImageIO
import Vision
import CoreImage

/// A production-grade progressive decoder that intelligently evaluates partially decoded
/// JPEG/WebP/HEIC/AVIF frames using AI signals—**saliency** and **sharpness**—
/// to determine whether a new partial image is worth displaying.
///
/// This avoids:
/// - UI flicker
/// - noisy or low-quality scanline updates
/// - wasteful decode churn
///
/// Key features:
/// - AI-driven quality scoring (Vision + Laplacian sharpness)
/// - Progressive JPEG compatible through `CGImageSourceCreateIncremental`
/// - Early-stop optimization when quality reaches a configured cap
/// - Optional downsampling for memory efficiency
///
/// This decoder is used by:
/// - `AIImagePipeline` during progressive network fetch
/// - `AILoader.fetchStream()` progressive callback
public actor AIProgressiveDecoder: Sendable {

    // MARK: - Singleton

    /// Global shared instance for all progressive decoding operations.
    public static let shared = AIProgressiveDecoder()


    // MARK: - Internal State

    /// The underlying incremental CGImageSource used to feed progressive data.
    private var imageSource: CGImageSource?

    /// Last delivered AI score, used to avoid emitting worse or minimally better frames.
    private var lastAIScore: Float = 0

    /// Shared CIContext for repeated sharpness computations.
    private let ciContext = CIContext()

    /// Reusable Vision request used for saliency evaluation.
    private lazy var saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()

    /// Minimum score improvement required before emitting another frame.
    private let minimumImprovement: Float = 0.08

    /// Maximum quality threshold — once reached, decoding stops early.
    private let qualityCap: Float = 0.85


    // MARK: - Init

    /// Creates a new progressive decoder.
    /// Typically, only the shared instance is used.
    public init() {}


    // MARK: - Progressive Decode API

    /// Incrementally decodes incoming progressive JPEG bytes and returns a best-effort
    /// partial frame, **only if AI scoring determines it is worth showing**.
    ///
    /// - Parameters:
    ///   - data: Accumulated progressive byte buffer.
    ///   - isFinal: Whether the data stream is finished.
    ///   - maxPixelSize: Optional downsample constraint for memory efficiency.
    ///
    /// - Returns:
    ///   A `UIImage` representing the best current partial decode, or `nil` if the image
    ///   should not yet be displayed.
    ///
    /// The decision algorithm:
    /// 1. Decode partial frame using `CGImageSourceCreateIncremental`.
    /// 2. Compute saliency + sharpness AI score.
    /// 3. If score increased significantly OR final frame is available → emit frame.
    /// 4. If score exceeds threshold cap → freeze decoding and return immediately.
    public func incrementalDecode(
        accumulatedData data: Data,
        isFinal: Bool,
        maxPixelSize: Int?
    ) async -> UIImage? {

        guard !data.isEmpty else { return nil }

        // Initialize incremental decoder if needed.
        if imageSource == nil {
            imageSource = CGImageSourceCreateIncremental(nil)
        }
        guard let source = imageSource else { return nil }

        // Feed data chunk.
        CGImageSourceUpdateData(source, data as CFData, isFinal)

        // Ensure at least one frame exists.
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        // Create partial CGImage with optional thumbnail downsampling.
        let cgImage: CGImage?
        if let max = maxPixelSize, max > 0 {
            let opts: [NSString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: max
            ]
            cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
        } else {
            let opts: [NSString: Any] = [
                kCGImageSourceShouldCacheImmediately: true
            ]
            cgImage = CGImageSourceCreateImageAtIndex(source, 0, opts as CFDictionary)
        }

        guard let cg = cgImage else { return nil }
        let ui = UIImage(cgImage: cg)

        // Compute AI quality score.
        let score = await computeAIQuality(of: ui)

        // Early-stop: stable high quality.
        if score >= qualityCap {
            lastAIScore = score
            return ui
        }

        // Emit only if improvement is meaningful or if the stream is completed.
        if (score - lastAIScore) >= minimumImprovement || isFinal {
            lastAIScore = score
            return ui
        }

        // Otherwise: ignore low-value partial update.
        return nil
    }


    // MARK: - AI Quality Evaluation

    /// Computes a stable AI score (0–1) for a partial frame by combining:
    /// - Vision-based saliency confidence
    /// - Core Image Laplacian sharpness
    ///
    /// - Parameter image: Partial progressive frame.
    /// - Returns: Score between 0 and 1.
    private func computeAIQuality(of image: UIImage) async -> Float {
        guard let cg = image.cgImage else { return 0.1 }

        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        var saliencyScore: Float = 0

        let sharpnessScore = computeSharpness(of: image)

        do {
            try handler.perform([saliencyRequest])
            if let result = saliencyRequest.results?.first {
                saliencyScore = Float(result.confidence)
            }
        } catch {
            // Vision may fail on incomplete data — return sharpness only.
            return sharpnessScore
        }

        // Weighted combination: saliency is more stable for noisy partial JPEGs.
        return (saliencyScore * 0.7) + (sharpnessScore * 0.3)
    }


    // MARK: - Sharpness Estimation

    /// Measures image sharpness using the Laplacian operator.
    ///
    /// For partial frames:
    /// - Works even on incomplete scanlines
    /// - Very fast (CI-based)
    /// - Produces a normalized brightness value (0–1)
    ///
    /// - Parameter image: The image to evaluate.
    /// - Returns: Sharpness between 0 and 1.
    private func computeSharpness(of image: UIImage) -> Float {
        guard let cg = image.cgImage else { return 0 }

        let ci = CIImage(cgImage: cg)

        let lap = ci
            .applyingFilter("CILaplacian")
            .applyingFilter(
                "CIAreaMaximum",
                parameters: [
                    kCIInputExtentKey: CIVector(cgRect: ci.extent)
                ]
            )
            .clampedToExtent()
            .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))

        var px: [UInt8] = [0, 0, 0, 0]

        ciContext.render(
            lap,
            toBitmap: &px,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        return Float(px[0]) / 255.0
    }
}

//
//  AIAnimatedImage.swift
//  AIAutoImageCore
//
//  High-level animated image container with AI-generated metadata.
//  Stores:
//    • Frames + delays
//    • Loop count
//    • Saliency score per frame (Vision)
//    • Sharpness score per frame (Core Image – Laplacian)
//    • AI quality score (combined)
//    • Automatically computed “best frame”
//    • Optional AI-based duration smoothing
//

import Foundation
import UIKit
import ImageIO
import Vision
import CoreImage

/// A production-grade animated image container with AI-driven metadata.
///
/// `AIAnimatedImage` stores all frames of an animated image along with:
///  - Per-frame Vision saliency scores
///  - Per-frame CoreImage sharpness scores
///  - Combined AI quality score
///  - Automatically determined best representative frame
///  - Optional duration smoothing based on quality
///
/// This class is used internally by `AIAnimatedDecoder` after decoding GIF/APNG/HEIC.
/// It provides higher-level insight into animation quality and supports frame filtering.
public final class AIAnimatedImage {

    // MARK: - Stored Properties
    // ---------------------------------------------------------------------

    /// All decoded frames of the animated image (in display order).
    public let frames: [UIImage]

    /// Delay time for each frame, matching ImageIO-provided timing.
    public let delays: [TimeInterval]

    /// Playback loop count (`0` = infinite for GIFs).
    public let loopCount: Int

    /// Combined AI quality score per frame (0–1).
    ///
    /// Computed by:
    /// ```
    ///  score = saliency * 0.7 + sharpness * 0.3
    /// ```
    public private(set) var aiScores: [Float] = []

    /// Vision-based saliency score per frame (0–1).
    public private(set) var saliencyScores: [Float] = []

    /// Laplacian-derived sharpness value per frame (0–1).
    public private(set) var sharpnessScores: [Float] = []


    /// Internal setter for AI scores.
    public func setAIScores(_ scores: [Float]) { self.aiScores = scores }

    /// Internal setter for Vision saliency scores.
    public func setSaliencyScores(_ scores: [Float]) { self.saliencyScores = scores }

    /// Internal setter for CI sharpness scores.
    public func setSharpnessScores(_ scores: [Float]) { self.sharpnessScores = scores }

    /// Shared CIContext for sharpness calculations.
    private let ciContext = CIContext()

    /// Reusable Vision saliency request (iOS 15+).
    private lazy var saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()


    // MARK: - Initialization
    // ---------------------------------------------------------------------

    /**
     Creates a new animated image container.

     - Parameters:
       - frames: All decoded UIImages in correct order.
       - delays: Matching frame durations.
       - loopCount: Number of loops (`0` = infinite for GIFs).
     */
    public init(frames: [UIImage], delays: [TimeInterval], loopCount: Int = 0) {
        self.frames = frames
        self.delays = delays
        self.loopCount = loopCount
    }


    // MARK: - Duration
    // ---------------------------------------------------------------------

    /// Total playback duration for the original animation.
    public var duration: TimeInterval {
        delays.reduce(0, +)
    }


    // MARK: - AI Processing
    // ---------------------------------------------------------------------

    /**
     Computes AI metadata for all frames of the animation.

     This performs:
     - Vision saliency request per frame
     - Laplacian sharpness computation
     - Combined AI score generation

     This method is asynchronous because Vision requests are async-capable.
     Must be `await`-ed before accessing `aiScores`.
     */
    public func computeAIMetadata() async {
        aiScores = []
        saliencyScores = []
        sharpnessScores = []

        for frame in frames {
            let saliency = await computeSaliency(frame)
            let sharpness = computeSharpness(frame)

            // Weighted scoring
            let score = (saliency * 0.7) + (sharpness * 0.3)

            saliencyScores.append(saliency)
            sharpnessScores.append(sharpness)
            aiScores.append(score)
        }
    }


    // MARK: - Best Frame Selection
    // ---------------------------------------------------------------------

    /// Returns the highest-scoring frame according to AI metadata.
    ///
    /// Useful for:
    ///  - Thumbnail generation
    ///  - Stable preview frames
    ///  - Image analysis
    public var bestFrame: UIImage? {
        guard !aiScores.isEmpty else { return nil }
        guard let idx = aiScores.enumerated().max(by: { $0.element < $1.element })?.offset else {
            return nil
        }
        return frames[idx]
    }

    /// Index of the best representative frame.
    public var bestFrameIndex: Int? {
        aiScores.enumerated().max(by: { $0.element < $1.element })?.offset
    }


    // MARK: - Vision Saliency
    // ---------------------------------------------------------------------

    /**
     Computes Vision saliency score for a single frame.

     - Parameter image: Source frame.
     - Returns: A saliency score in range 0–1, or a fallback of `0.1`.
     */
    private func computeSaliency(_ image: UIImage) async -> Float {
        guard let cg = image.cgImage else { return 0.1 }

        let handler = VNImageRequestHandler(cgImage: cg, options: [:])

        do {
            try handler.perform([saliencyRequest])
            if let r = saliencyRequest.results?.first {
                return Float(r.confidence)
            }
        } catch { }

        return 0.1
    }


    // MARK: - Sharpness (Laplacian)
    // ---------------------------------------------------------------------

    /**
     Computes sharpness using Core Image's Laplacian operator.

     Steps:
      1. Apply `CILaplacian`
      2. Apply `CIAreaMaximum` over full extent
      3. Sample a 1×1 pixel representing magnitude

     - Parameter image: Source frame.
     - Returns: Sharpness normalized to 0–1.
     */
    private func computeSharpness(_ image: UIImage) -> Float {
        guard let cg = image.cgImage else { return 0 }

        let ci = CIImage(cgImage: cg)

        // Laplacian → Area maximum → sample
        let lap = ci
            .applyingFilter("CILaplacian")
            .applyingFilter(
                "CIAreaMaximum",
                parameters: [kCIInputExtentKey: CIVector(cgRect: ci.extent)]
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


    // MARK: - AI Duration Smoothing (Optional)
    // ---------------------------------------------------------------------

    /**
     Applies AI-driven adaptive smoothing to frame durations.

     This reduces flicker by:
      - Increasing duration of high-quality frames
      - Keeping lower-quality frames short
      - Maintaining overall animation feel

     - Parameter factor: Strength of duration smoothing (default 0.15).
     - Returns: A modified list of durations.
     */
    public func smoothedDurations(factor: Float = 0.15) -> [TimeInterval] {
        guard !aiScores.isEmpty else { return delays }

        let maxScore = aiScores.max() ?? 1
        let minScore = aiScores.min() ?? 0

        return delays.enumerated().map { idx, base in
            let score = aiScores[idx]

            // Normalize 0–1
            let norm = (score - minScore) / max(0.0001, (maxScore - minScore))

            // Increase duration slightly for higher-quality frames
            return base * (1 + (Double(norm) * Double(factor)))
        }
    }
}

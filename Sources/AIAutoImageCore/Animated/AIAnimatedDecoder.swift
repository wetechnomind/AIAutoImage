//
//  AIAnimatedDecoder.swift
//  AIAutoImageCore
//
//  High-performance animated image decoder with optional AI scoring,
//  frame quality filtering, and Vision-based saliency metadata.
//
//  Supports:
//   • GIF
//   • APNG
//   • Animated HEIC / HEIF
//   • ImageIO-based multi-frame formats
//

import Foundation
import UIKit
import ImageIO
import CoreImage
import Vision
import MobileCoreServices

/// A high-performance animated-image decoder with AI-assisted filtering.
///
/// `AIAnimatedDecoder` provides:
///  - Multi-frame decoding using ImageIO
///  - Per-frame delay extraction for GIF/APNG/HEIC
///  - Optional Vision-based saliency scoring for quality ranking
///  - Automatic filtering of low-quality frames
///
/// It generates an `AIAnimatedImage`, which acts similarly to an animated GIF
/// container with additional AI metadata.
public final class AIAnimatedDecoder {

    /// Core Image context used for optional CI-based operations.
    private let ciContext = CIContext()

    /// Vision saliency request reused for all frames (iOS 15+).
    private lazy var saliencyReq = VNGenerateAttentionBasedSaliencyImageRequest()

    /// Creates a new animated image decoder.
    public init() {}

    // MARK: - Public API
    // ---------------------------------------------------------------------

    /**
     Decodes an animated image and optionally enhances it using AI scoring.

     Supported formats:
       - GIF
       - APNG
       - Animated HEIC/HEIF
       - Any multi-frame ImageIO-compatible container

     When `aiFilter == true`, each frame is passed through:
       1. Vision saliency scoring
       2. AI frame ranking
       3. Median-based quality filtering

     - Parameters:
       - data: Raw image data for any animated format.
       - aiFilter: Whether to compute AI metadata + filter low-quality frames.

     - Returns: An `AIAnimatedImage` containing frames, delays, loop count,
                and optional AI metadata. Returns `nil` for static images.
     */
    public func decodeAnimatedImage(
        data: Data,
        aiFilter: Bool = true
    ) async -> AIAnimatedImage? {

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }   // Not animated → skip

        var frames: [UIImage] = []
        var delays: [TimeInterval] = []
        let loopCount = extractLoopCount(from: source)

        // ---- Frame Decoding ----

        for index in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }

            let ui = UIImage(cgImage: cg)
            let delay = extractFrameDelay(from: source, index: index)

            // Skip obviously corrupt or invalid frames
            if ui.size.width < 2 || ui.size.height < 2 { continue }

            frames.append(ui)
            delays.append(delay)
        }

        if frames.isEmpty { return nil }

        var animated = AIAnimatedImage(frames: frames, delays: delays, loopCount: loopCount)

        // ---- AI Metadata (Optional) ----

        if aiFilter {
            // Compute per-frame saliency + metadata
            await animated.computeAIMetadata()

            // Drop extremely low-quality frames
            animated = filterLowQualityFrames(animated)
        }

        return animated
    }


    // MARK: - Frame Delay Extraction
    // ---------------------------------------------------------------------

    /**
     Extracts the per-frame delay for GIF, APNG, and other animated formats.

     Uses ImageIO metadata keys, falling back to a safe default.

     - Parameters:
       - source: Image source from ImageIO
       - index: Frame index

     - Returns: Delay (seconds) with a minimum threshold of 0.02.
     */
    private func extractFrameDelay(from source: CGImageSource, index: Int) -> TimeInterval {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
            return 0.1
        }

        // GIF metadata
        if let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            if let d = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double {
                return max(d, 0.02)
            }
            if let d = gif[kCGImagePropertyGIFDelayTime] as? Double {
                return max(d, 0.02)
            }
        }

        // APNG metadata
        if let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
            if let d = png[kCGImagePropertyAPNGUnclampedDelayTime] as? Double {
                return max(d, 0.02)
            }
            if let d = png[kCGImagePropertyAPNGDelayTime] as? Double {
                return max(d, 0.02)
            }
        }

        // Default fallback
        return 0.1
    }

    /**
     Extracts loop count from GIF/APNG properties.

     - Parameter source: The animated ImageIO source.
     - Returns: A loop count (0 = infinite repeat for GIFs).
     */
    private func extractLoopCount(from source: CGImageSource) -> Int {
        if let props = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] {

            // GIF loop count
            if let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any],
               let loop = gif[kCGImagePropertyGIFLoopCount] as? Int {
                return loop
            }

            // APNG loop count
            if let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any],
               let loop = png[kCGImagePropertyAPNGLoopCount] as? Int {
                return loop
            }
        }
        return 0
    }


    // MARK: - AI Filtering Logic
    // ---------------------------------------------------------------------

    /**
     Filters out extremely low-quality frames using AI saliency scores.

     Logic:
       1. Sort scores to find the median.
       2. Keep frames scoring ≥ 65% of median.
       3. If filtering removes too many frames, original animation is preserved.

     - Parameter anim: The original animated image with AI metadata.
     - Returns: A quality-filtered version, or original if filtering is too aggressive.
     */
    private func filterLowQualityFrames(_ anim: AIAnimatedImage) -> AIAnimatedImage {

        // No metadata → return original animation
        guard !anim.aiScores.isEmpty else { return anim }

        let sorted = anim.aiScores.sorted()
        let median = sorted[sorted.count / 2]

        var frames: [UIImage] = []
        var delays: [TimeInterval] = []
        var newScores: [Float] = []

        for (i, frame) in anim.frames.enumerated() {
            if anim.aiScores[i] >= median * 0.65 {     // keep top ~65% quality frames
                frames.append(frame)
                delays.append(anim.delays[i])
                newScores.append(anim.aiScores[i])
            }
        }

        // If extremely few frames remain, revert to original set
        if frames.count < 2 { return anim }

        let filtered = AIAnimatedImage(frames: frames, delays: delays, loopCount: anim.loopCount)
        filtered.setAIScores(newScores)

        return filtered
    }
}

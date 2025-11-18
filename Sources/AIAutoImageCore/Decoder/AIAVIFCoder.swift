//
//  AIAVIFCoder.swift
//  AIAutoImageCore
//
//  Production-grade AVIF coder utilizing ImageIO and AI scoring layers.
//  Provides:
//  • Static & multi-frame AVIF decode
//  • AI frame ranking (saliency + sharpness)
//  • Optional downsampling on decode
//  • Fallback decoding when AVIF is unsupported
//  • Ready for future libavif-based encoding
//

import Foundation
import UIKit
import ImageIO
import Vision
import CoreImage

/// High-performance AVIF decoder with AI-assisted frame ranking.
///
/// `AIAVIFCoder` provides a robust AVIF decoding implementation using:
/// - **ImageIO** for native AVIF support (iOS 16+, macOS 13+)
/// - **Vision saliency scoring** to find the most visually important frame
/// - **CoreImage Laplacian sharpness scoring** for clarity measurement
/// - **Downsampling support** via `maxPixelSize`
///
/// It automatically:
/// - Handles static & animated AVIF
/// - Selects the **best-quality** frame for display
/// - Falls back to `UIImage(data:)` when ImageIO cannot decode
///
/// Designed to be used internally by the image pipeline, but can be used directly.
///
/// ## Example
/// ```swift
/// let coder = AIAVIFCoder()
/// let image = await coder.decodeAVIF(data, maxPixelSize: 1024)
/// ```
public struct AIAVIFCoder {

    /// Shared CIContext for sharpness evaluation.
    private let ciContext = CIContext()

    /// Vision request reused across frames.
    private var saliencyReq = VNGenerateAttentionBasedSaliencyImageRequest()

    /// Creates a new AVIF coder.
    public init() {}


    // MARK: - Public Decode API
    // --------------------------------------------------------------

    /// Decodes AVIF data into a `UIImage`, selecting the best-quality frame using AI ranking.
    ///
    /// - Parameters:
    ///   - data: AVIF-encoded image data.
    ///   - maxPixelSize: Optional downsampling limit. If provided, decoder reduces
    ///     resolution before decoding, saving memory & improving performance.
    ///
    /// - Returns: A `UIImage` representing the best frame, or a fallback decode if necessary.
    ///
    /// This method:
    /// 1. Uses **ImageIO** to decode all AVIF frames
    /// 2. Scores each frame using:
    ///    • Vision saliency
    ///    • CoreImage Laplacian sharpness
    /// 3. Returns the frame with the highest AI score
    public func decodeAVIF(
        data: Data,
        maxPixelSize: Int? = nil
    ) async -> UIImage? {

        // Attempt native AVIF decode
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return fallbackDecode(data)
        }

        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0 else { return fallbackDecode(data) }

        var bestImage: UIImage?
        var bestScore: Float = 0

        // Iterate all frames (multi-frame AVIF)
        for index in 0..<frameCount {
            guard let cg = createFrame(at: index, source: source, maxPixelSize: maxPixelSize) else { continue }
            let ui = UIImage(cgImage: cg)

            let score = await aiScore(of: ui)
            if score > bestScore {
                bestScore = score
                bestImage = ui
            }
        }

        return bestImage ?? fallbackDecode(data)
    }


    // MARK: - Encoding (Stub)
    // --------------------------------------------------------------

    /// Encodes a UIImage into AVIF format.
    /// Currently unimplemented — placeholder for future libavif support.
    ///
    /// - Parameters:
    ///   - image: Source image to encode.
    ///   - quality: Target quality (0–1 range).
    ///
    /// - Returns: `nil` (future API placeholder)
    public func encodeAVIF(_ image: UIImage, quality: CGFloat) -> Data? {
        return nil
    }


    // MARK: - Internal: Frame Decode
    // --------------------------------------------------------------

    /// Creates a CGImage for a specific AVIF frame, optionally downsampled.
    private func createFrame(
        at index: Int,
        source: CGImageSource,
        maxPixelSize: Int?
    ) -> CGImage? {

        // Use thumbnail decode for downsample
        if let maxPixelSize, maxPixelSize > 0 {
            let options: [NSString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
        }

        return CGImageSourceCreateImageAtIndex(source, index, nil)
    }


    // MARK: - Fallback Decode
    // --------------------------------------------------------------

    /// Fallback decode used when AVIF cannot be processed by ImageIO.
    private func fallbackDecode(_ data: Data) -> UIImage? {
        UIImage(data: data)
    }


    // MARK: - AI Scoring
    // --------------------------------------------------------------

    /// Computes combined AI score using saliency + sharpness.
    private func aiScore(of image: UIImage) async -> Float {
        let s = await computeSaliency(image)
        let sh = computeSharpness(image)
        return (s * 0.7) + (sh * 0.3)
    }


    // MARK: - Vision Saliency
    // --------------------------------------------------------------

    /// Computes Vision-based saliency score for an image.
    /// Higher values = more visually important areas.
    private func computeSaliency(_ image: UIImage) async -> Float {
        guard let cg = image.cgImage else { return 0.1 }

        let handler = VNImageRequestHandler(cgImage: cg, options: [:])

        do {
            try handler.perform([saliencyReq])
            if let result = saliencyReq.results?.first {
                return Float(result.confidence)
            }
        } catch { }

        return 0.1
    }


    // MARK: - Sharpness (CoreImage Laplacian)
    // --------------------------------------------------------------

    /// Computes sharpness using Laplacian + maximum intensity sampling.
    private func computeSharpness(_ image: UIImage) -> Float {
        guard let cg = image.cgImage else { return 0 }

        let ci = CIImage(cgImage: cg)

        let lap = ci
            .applyingFilter("CILaplacian")
            .applyingFilter(
                "CIAreaMaximum",
                parameters: [kCIInputExtentKey: CIVector(cgRect: ci.extent)]
            )
            .clampedToExtent()
            .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))

        var pixel: [UInt8] = [0, 0, 0, 0]

        ciContext.render(
            lap,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        return Float(pixel[0]) / 255.0
    }
}

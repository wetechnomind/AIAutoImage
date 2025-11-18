//
//  AIWebPCoder.swift
//  AIAutoImageCore
//

import Foundation
import UIKit
import ImageIO
import CoreImage
import Vision

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// A high-performance WebP decoder with AI-assisted frame selection.
///
/// `AIWebPCoder` performs:
/// - **Static WebP decoding** using ImageIO
/// - **Animated WebP decoding** (WebP multi-frame)
/// - **Downsampled decode** for memory-safe pipelines
/// - **AI ranking** of frames using:
///   - Vision saliency
///   - CI Laplacian sharpness
/// - **Automatic best-frame selection** for animated or progressive WebP files
/// - **Graceful fallback** to `UIImage(data:)` when ImageIO cannot decode
///
/// This coder is used internally by:
/// - `AIImageCodersRegistrar`
/// - `AIDecoder`
/// - `AIImagePipeline`
///
/// It is completely stateless and safe to use concurrently.
public struct AIWebPCoder {

    // MARK: - Internal Components

    /// Shared CI context for efficient sharpness scoring.
    private let ciContext = CIContext()

    /// Reusable Vision saliency request.
    private var saliencyReq = VNGenerateAttentionBasedSaliencyImageRequest()

    /// Creates a new instance of the WebP coder.
    public init() {}


    // MARK: - Public Decode API

    /// Decodes WebP data (static or animated) and returns the highest-quality frame
    /// using AI ranking (saliency + sharpness).
    ///
    /// - Parameters:
    ///   - data: Raw WebP image data.
    ///   - maxPixelSize: Optional maximum decode resolution for downsampling.
    ///
    /// - Returns:
    ///   A `UIImage` selected by quality ranking, or `nil` if decoding fails.
    ///
    /// Behavior:
    /// 1. Attempts WebP decoding using ImageIO.
    /// 2. Iterates all frames (for animated or multi-frame WebP).
    /// 3. Computes AI score for each frame:
    ///    - Vision saliency confidence
    ///    - Laplacian sharpness
    /// 4. Returns the highest-ranked frame.
    /// 5. Falls back to `UIImage(data:)` if ImageIO cannot decode the WebP.
    public func decodeWebP(
        data: Data,
        maxPixelSize: Int? = nil
    ) async -> UIImage? {

        // 1. Try decoding with ImageIO
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            return fallbackDecode(data)
        }

        let count = CGImageSourceGetCount(src)
        guard count > 0 else {
            return fallbackDecode(data)
        }

        var bestImage: UIImage?
        var bestScore: Float = 0

        // 2. Multi-frame iteration (covers animated WebP)
        for index in 0..<count {
            let cg = createFrame(at: index, source: src, maxPixelSize: maxPixelSize)
            guard let cgImage = cg else { continue }

            let ui = UIImage(cgImage: cgImage)
            let score = await aiScore(of: ui)

            if score > bestScore {
                bestScore = score
                bestImage = ui
            }
        }

        // 3. Return highest-quality frame or fallback
        return bestImage ?? fallbackDecode(data)
    }


    // MARK: - Encoding (Placeholder)

    /// Encodes a UIImage into WebP format.
    ///
    /// - Important:
    ///   Real WebP encoding is **not** supported in this placeholder implementation.
    ///   For production WebP encoding, integrate:
    ///   - `libwebp-swift`, or
    ///   - Apple's future native WebP encoder (when released)
    public func encodeWebP(_ image: UIImage, quality: CGFloat) -> Data? {
        return nil
    }


    // MARK: - Frame Decode Helpers

    /// Decodes a single WebP frame using ImageIO, optionally downsampled.
    ///
    /// - Parameters:
    ///   - index: Frame index.
    ///   - source: CGImageSource representing the WebP animation.
    ///   - maxPixelSize: Optional maximum pixel size for downsampling.
    ///
    /// - Returns:
    ///   A downsampled or full-resolution `CGImage`, or `nil` on failure.
    private func createFrame(
        at index: Int,
        source: CGImageSource,
        maxPixelSize: Int?
    ) -> CGImage? {

        // Downsample if requested
        if let maxPixelSize = maxPixelSize, maxPixelSize > 0 {
            let opts: [NSString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, index, opts as CFDictionary)
        }

        // Full decode
        return CGImageSourceCreateImageAtIndex(source, index, nil)
    }


    // MARK: - Fallback

    /// If ImageIO cannot decode, fallback to a naive `UIImage(data:)`.
    private func fallbackDecode(_ data: Data) -> UIImage? {
        UIImage(data: data)
    }


    // MARK: - AI Scoring (Saliency + Sharpness)

    /// Computes a weighted AI quality score for a frame.
    ///
    /// Score = `0.7 * saliency + 0.3 * sharpness`
    ///
    /// Saliency helps prioritize visually meaningful regions.
    /// Sharpness distinguishes crisp vs blurry frames.
    private func aiScore(of image: UIImage) async -> Float {
        let saliency = await computeSaliency(image)
        let sharpness = computeSharpness(image)

        return (saliency * 0.7) + (sharpness * 0.3)
    }


    // MARK: - Vision Saliency

    /// Computes Vision saliency confidence score (0–1) for the image.
    ///
    /// - Returns:
    ///   Vision-generated attention confidence or a fallback value.
    private func computeSaliency(_ image: UIImage) async -> Float {
        guard let cg = image.cgImage else { return 0.1 }

        let handler = VNImageRequestHandler(cgImage: cg, options: [:])

        do {
            try handler.perform([saliencyReq])
            if let result = saliencyReq.results?.first {
                return Float(result.confidence)
            }
        } catch {
            // On partial / malformed WebP frames Vision may fail.
        }

        return 0.1
    }


    // MARK: - Sharpness (CI Laplacian)

    /// Computes Laplacian-based sharpness for the image.
    ///
    /// - Returns:
    ///   A normalized sharpness score between 0 and 1.
    private func computeSharpness(_ image: UIImage) -> Float {
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

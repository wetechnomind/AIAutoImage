//
//  AIDecoder.swift
//  AIAutoImageCore
//
//  Central decoding engine for AIAutoImage.
//  Supports:
//  • GIF / APNG animated decoding
//  • WebP / AVIF / Plugin-based decoders
//  • Progressive incremental decoding
//  • Downsampling via ImageIO
//  • AI-driven LOD (Level-of-Detail) selection
//  • Vision-based saliency scoring
//  • CoreML-based category classification
//  • sRGB normalization
//

import Foundation
import UIKit
import ImageIO
import MobileCoreServices
import Vision
import CoreML

// MARK: - Error Types

/// Decoder-specific errors used by `AIDecoder`.
public enum AIDecoderError: Error, LocalizedError {

    /// CGImageSource could not be created from provided data.
    case cannotCreateImageSource

    /// CGImage cannot be constructed from source.
    case cannotCreateCGImage

    /// File format is unsupported or unrecognized.
    case unsupportedFormat

    /// Image data is empty or corrupt.
    case invalidData

    /// Unknown decoding error from underlying system.
    case unknown(Error)

    public var errorDescription: String? {
        switch self {
        case .cannotCreateImageSource: return "Unable to create image source from data."
        case .cannotCreateCGImage: return "Unable to create CGImage from source."
        case .unsupportedFormat: return "Image format is unsupported."
        case .invalidData: return "Invalid image data."
        case .unknown(let e): return "Unknown decoder error: \(e)"
        }
    }
}


// MARK: - Output Struct

/// The final decoded image + AI-enhanced metadata.
///
/// Contains:
/// - Normalized `UIImage`
/// - Vision saliency score (0–1)
/// - Optional CoreML category string
public struct AIDecodedImage: Sendable {
    /// Normalized output image.
    public let image: UIImage

    /// Vision-based saliency score.
    public let saliency: Double

    /// Optional CoreML category name.
    public let category: String?
}


// MARK: - Decoder

/// Production-grade image decoder used by the AIAutoImage pipeline.
///
/// Handles:
/// - Animated formats (GIF / APNG)
/// - Plugin-based codecs (WebP, AVIF, etc.)
/// - Progressive streaming decode
/// - Downsampling for memory efficiency
/// - AI LOD (Level-of-Detail analysis)
/// - sRGB normalization for consistent rendering
/// - Vision saliency & CoreML category classification
public final class AIDecoder: Sendable {

    /// Creates a new decoder.
    public init() {}

    // ==========================================================
    // MARK: - 1) CALLBACK API
    // ==========================================================

    /// Decodes image data into a normalized, AI-enhanced `AIDecodedImage`.
    ///
    /// - Parameters:
    ///   - data: Raw image data.
    ///   - request: Original `AIImageRequest`.
    ///   - targetPixelSize: Optional decode-downsample resolution.
    ///   - completion: Async completion handler.
    ///
    /// This function:
    /// - Checks plugin decoders (WebP/AVIF/custom)
    /// - Decodes GIF/APNG
    /// - Handles progressive final frames
    /// - Downsamples large images
    /// - Performs full decode fallback
    /// - Computes saliency & category
    public func decode(
        _ data: Data,
        request: AIImageRequest,
        targetPixelSize: CGSize?,
        completion: @Sendable @escaping (Result<AIDecodedImage, Error>) -> Void
    ) {

        Task.detached(priority: .userInitiated) {

            try Task.checkCancellation()

            // ----------------------------------------------------------
            // 0) CUSTOM CODECS → WebP / AVIF / Plugin-based decoders
            // ----------------------------------------------------------
            if let custom = await AIImageCodersRegistrar.shared.decode(data: data) {

                // Animated custom formats
                if let anim = custom as? AIAnimatedImage {
                    let first = anim.frames.first ?? UIImage()
                    let normalized = self.normalize(first)
                    let output = AIDecodedImage(
                        image: normalized,
                        saliency: self.computeSaliency(normalized),
                        category: await self.detectCategory(normalized)
                    )
                    await MainActor.run { completion(.success(output)) }
                    return
                }

                // Static custom formats
                if let img = custom as? UIImage {
                    let normalized = self.normalize(img)
                    let output = AIDecodedImage(
                        image: normalized,
                        saliency: self.computeSaliency(normalized),
                        category: await self.detectCategory(normalized)
                    )
                    await MainActor.run { completion(.success(output)) }
                    return
                }
            }

            // ----------------------------------------------------------
            // 1) BUILT-IN ANIMATED: GIF / APNG
            // ----------------------------------------------------------
            if let anim = await AIAnimatedDecoder().decodeAnimatedImage(data: data) {
                let frame = anim.frames.first ?? UIImage()
                let normalized = self.normalize(frame)

                let output = AIDecodedImage(
                    image: normalized,
                    saliency: self.computeSaliency(normalized),
                    category: await self.detectCategory(normalized)
                )

                await MainActor.run { completion(.success(output)) }
                return
            }

            // ----------------------------------------------------------
            // 2) PROGRESSIVE FINAL FRAME
            // ----------------------------------------------------------
            if request.isProgressiveEnabled,
               targetPixelSize == nil {

                if let partial = await AIProgressiveDecoder()
                    .incrementalDecode(accumulatedData: data,
                                       isFinal: true,
                                       maxPixelSize: nil)
                {
                    let normalized = self.normalize(partial)
                    let output = AIDecodedImage(
                        image: normalized,
                        saliency: self.computeSaliency(normalized),
                        category: await self.detectCategory(normalized)
                    )
                    await MainActor.run { completion(.success(output)) }
                    return
                }
            }

            // ----------------------------------------------------------
            // 3) NORMAL DECODE
            // ----------------------------------------------------------
            do {
                let ui = try self.performDecode(
                    data: data,
                    request: request,
                    targetPixelSize: targetPixelSize
                )

                let output = AIDecodedImage(
                    image: ui,
                    saliency: self.computeSaliency(ui),
                    category: await self.detectCategory(ui)
                )

                await MainActor.run { completion(.success(output)) }

            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

    // ==========================================================
    // MARK: - 2) ASYNC API
    // ==========================================================

    /// Async/await wrapper for decoding images with full AI metadata.
    ///
    /// Mirrors the callback logic but returns `AIDecodedImage` directly.
    public func decode(
        _ data: Data,
        request: AIImageRequest,
        targetPixelSize: CGSize?
    ) async throws -> AIDecodedImage {

        try Task.checkCancellation()

        // 0) Custom codecs
        if let custom = await AIImageCodersRegistrar.shared.decode(data: data) {

            if let anim = custom as? AIAnimatedImage {
                let ui = anim.frames.first ?? UIImage()
                let normalized = normalize(ui)
                return AIDecodedImage(
                    image: normalized,
                    saliency: computeSaliency(normalized),
                    category: await detectCategory(normalized)
                )
            }

            if let ui = custom as? UIImage {
                let normalized = normalize(ui)
                return AIDecodedImage(
                    image: normalized,
                    saliency: computeSaliency(normalized),
                    category: await detectCategory(normalized)
                )
            }
        }

        // 1) GIF/APNG
        if let anim = await AIAnimatedDecoder().decodeAnimatedImage(data: data) {
            let ui = anim.frames.first ?? UIImage()
            let normalized = normalize(ui)

            return AIDecodedImage(
                image: normalized,
                saliency: computeSaliency(normalized),
                category: await detectCategory(normalized)
            )
        }

        // 2) Progressive final frame
        if request.isProgressiveEnabled,
           targetPixelSize == nil {
            if let partial = await AIProgressiveDecoder()
                .incrementalDecode(accumulatedData: data, isFinal: true, maxPixelSize: nil) {

                let normalized = normalize(partial)

                return AIDecodedImage(
                    image: normalized,
                    saliency: computeSaliency(normalized),
                    category: await detectCategory(normalized)
                )
            }
        }

        // 3) Normal decode
        return try await withCheckedThrowingContinuation { cont in
            self.decode(data, request: request, targetPixelSize: targetPixelSize) { result in
                switch result {
                case .success(let v): cont.resume(returning: v)
                case .failure(let e): cont.resume(throwing: e)
                }
            }
        }
    }

    // ==========================================================
    // MARK: - 3) AI LOD — Level of Detail Selection
    // ==========================================================

    /// Computes ideal downsample size based on:
    /// - explicit targetPixelSize
    /// - usage context (thumbnail, detail, list, etc.)
    /// - preset quality
    /// - device RAM heuristic
    private func decideLODPixelSize(
        request: AIImageRequest,
        originalSize: CGSize
    ) -> Int? {

        // Explicit override
        if let target = request.targetPixelSize {
            return Int(max(target.width, target.height))
        }

        // Usage context rules
        switch request.usageContext {
        case .thumbnail: return 256
        case .listItem:  return 512
        case .gallery:   return 768
        case .prefetch:  return 512
        case .detail:    return nil
        default: break
        }

        // Quality presets
        switch request.quality {
        case .low:      return 512
        case .medium:   return 1024
        case .high:     return 2048
        case .lossless: return nil
        case .adaptive: break
        }

        // Device RAM heuristic (low-end)
        let isLowRAM = ProcessInfo.processInfo.physicalMemory < (2 * 1024 * 1024 * 1024)
        if isLowRAM {
            return 1024
        }

        return nil
    }

    // ==========================================================
    // MARK: - 4) Perform Decode
    // ==========================================================

    /// Full decode routine including LOD + downsample + normalization.
    private func performDecode(
        data: Data,
        request: AIImageRequest,
        targetPixelSize: CGSize?
    ) throws -> UIImage {

        try Task.checkCancellation()
        guard !data.isEmpty else { throw AIDecoderError.invalidData }

        // Detect format quickly
        let format = detectFormat(from: data)
        if format == .unknown, data.count < 20 {
            throw AIDecoderError.unsupportedFormat
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw AIDecoderError.cannotCreateImageSource
        }

        // Extract original pixel size
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0

        // AI LOD selector
        let lodMax = decideLODPixelSize(
            request: request,
            originalSize: CGSize(width: w, height: h)
        )

        // Downsample
        if let maxPx = lodMax ?? (targetPixelSize.map { Int(max($0.width, $0.height)) }) {
            if let cg = createDownsampledImage(from: source, maxPixelSize: maxPx) {
                return normalize(UIImage(cgImage: cg))
            }
        }

        // Full-resolution decode
        guard let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AIDecoderError.cannotCreateCGImage
        }

        return normalize(UIImage(cgImage: cg))
    }

    // ==========================================================
    // MARK: - 5) Downsample Helper
    // ==========================================================

    /// Creates a downsampled CGImage using ImageIO.
    private func createDownsampledImage(
        from source: CGImageSource,
        maxPixelSize: Int
    ) -> CGImage? {

        let safeMax = max(1, min(maxPixelSize, 16384))

        let options: [NSString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: safeMax
        ]

        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // ==========================================================
    // MARK: - 6) Format Detection
    // ==========================================================

    /// Lightweight header sniffing for common formats.
    private func detectFormat(from data: Data) -> AIImageFormat {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .png }

        if data.count > 12 {
            let riff = String(bytes: data[0..<4], encoding: .ascii)
            let webp = String(bytes: data[8..<12], encoding: .ascii)
            if riff == "RIFF" && webp == "WEBP" { return .webp }
        }

        if data.count > 12 {
            let header = String(bytes: data[4..<12], encoding: .ascii)
            if header?.contains("ftyp") == true { return .heic }
            if header?.contains("avif") == true { return .avif }
        }

        return .unknown
    }

    // ==========================================================
    // MARK: - 7) Normalize Colorspace
    // ==========================================================

    /// Ensures output image is in sRGB for consistent rendering.
    private func normalize(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }

        // Already sRGB
        if let cs = cg.colorSpace, cs.name == CGColorSpace.sRGB {
            return image
        }

        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return image }

        let width = cg.width
        let height = cg.height

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: cg.bitsPerComponent,
            bytesPerRow: 0,
            space: sRGB,
            bitmapInfo: cg.bitmapInfo.rawValue
        ) else { return image }

        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let outputCG = ctx.makeImage() else { return image }

        return UIImage(cgImage: outputCG, scale: image.scale, orientation: image.imageOrientation)
    }

    // ==========================================================
    // MARK: - 8) Saliency
    // ==========================================================

    /// Computes Vision-based saliency score (0–1).
    private func computeSaliency(_ image: UIImage) -> Double {
        guard let cg = image.cgImage else { return 0.5 }

        if #available(iOS 15.0, *) {
            let req = VNGenerateAttentionBasedSaliencyImageRequest()
            let handler = VNImageRequestHandler(cgImage: cg)
            try? handler.perform([req])

            guard let obs = req.results?.first as? VNSaliencyImageObservation else {
                return 0.5
            }

            let buffer = obs.pixelBuffer
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

            guard let basePtr = CVPixelBufferGetBaseAddress(buffer) else { return 0.5 }

            let ptr = basePtr.assumingMemoryBound(to: UInt8.self)
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let stride = CVPixelBufferGetBytesPerRow(buffer)

            var sum = 0.0
            for y in 0..<height {
                let row = ptr + y * stride
                for x in 0..<width {
                    sum += Double(row[x]) / 255.0
                }
            }

            return min(max(sum / Double(width * height), 0), 1)
        }

        return 0.5
    }

    // ==========================================================
    // MARK: - 9) Category Classification
    // ==========================================================

    /// Schedules category classification via async CoreML model.
    private func detectCategory(_ image: UIImage) async -> String? {
        return await withUnsafeContinuation { cont in
            Task.detached(priority: .userInitiated) {
                let result = await self.detectCategoryAsync(image)
                cont.resume(returning: result)
            }
        }
    }

    /// Performs CoreML scene classification using `AICategory_v1`.
    private func detectCategoryAsync(_ image: UIImage) async -> String? {

        guard let wrapper = await AIModelManager.shared.model(named: "AICategory_v1") as? CoreMLModelWrapper,
              let mlModel = wrapper.coreMLModel,
              let cg = image.cgImage else { return nil }

        do {
            let vnModel = try VNCoreMLModel(for: mlModel)
            let req = VNCoreMLRequest(model: vnModel)
            req.imageCropAndScaleOption = .centerCrop

            let handler = VNImageRequestHandler(cgImage: cg)
            try handler.perform([req])

            if let obs = req.results?.first as? VNClassificationObservation {
                return obs.identifier
            }

        } catch {
            return nil
        }

        return nil
    }
}

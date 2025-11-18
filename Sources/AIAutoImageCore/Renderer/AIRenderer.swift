//
//  AIRenderer.swift
//  AIAutoImageCore
//

import Foundation
import UIKit
import CoreImage
import ImageIO
import Accelerate
import Vision
import CoreML

/// A high-performance, AI-assisted image renderer responsible for:
/// - ML-based tone mapping (HDR → SDR, lighting correction)
/// - Vision-based auto orientation
/// - AI-driven sharpness optimization
/// - Multi-stage CIImage processing
/// - HEIC tone-mapping optimization
/// - LOD (Level of Detail) clamping for adaptive quality
/// - Optional watermark overlay
///
/// The renderer combines:
/// - Core Image (GPU-accelerated effects)
/// - Vision (face/dominant object analysis)
/// - CoreML (image enhancement models)
///
/// `AIRenderer` is `@unchecked Sendable` because it internally manages
/// GPU/CIContext/ML queues, but public API methods are thread-safe.
public final class AIRenderer: @unchecked Sendable {

    // MARK: - Core Image Rendering Context

    /// GPU-accelerated CIContext for all rendering operations.
    ///
    /// Options:
    /// - Software renderer disabled
    /// - High-quality downsampling enabled
    private let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .highQualityDownsample: true
    ])

    /// Queue used for ML-based Vision/CoreML tasks.
    private let mlQueue = DispatchQueue(label: "ai.render.ml", qos: .userInitiated)

    /// Queue used for Vision-based processing.
    private let visionQueue = DispatchQueue(label: "ai.render.vision", qos: .userInitiated)

    /// Creates a new renderer instance.
    public init() {}

    // MARK: - Public API

    /// Renders a full AI-enhanced output image using the pipeline.
    ///
    /// Pipeline includes:
    /// 1. Vision-based auto orientation
    /// 2. CoreML HDR tone map
    /// 3. ML-driven sharpness enhancer
    /// 4. HEIC tone mapping
    /// 5. Resolution LOD clamp
    /// 6. Optional watermark
    ///
    /// - Parameters:
    ///   - image: Input image.
    ///   - request: Rendering options and metadata.
    /// - Returns: Fully rendered output image.
    public func render(_ image: UIImage, request: AIImageRequest) async -> UIImage {
        return await performFinalRender(image, request: request)
    }

    // ----------------------------------------------------------
    // MARK: - LOD Clamp (Adaptive Resolution)
    // ----------------------------------------------------------

    /// Applies resolution limits based on image context (usage & quality).
    ///
    /// Rules:
    /// - Thumbnails → clamp to 512px
    /// - Low quality → clamp to 1200px
    /// - Medium → clamp to 2000px
    /// - Adaptive → depends on category (faces stay full-res)
    ///
    /// - Parameters:
    ///   - ci: Input CIImage.
    ///   - request: Image request metadata.
    /// - Returns: Resolution-clamped image.
    private func applyLODClamp(_ ci: CIImage, request: AIImageRequest) -> CIImage {
        let extent = ci.extent
        let maxDimension = max(extent.width, extent.height)

        if request.usageContext == .thumbnail {
            return ci.resized(to: 512)
        }

        if request.quality == .low {
            return ci.resized(to: 1200)
        }

        if request.quality == .medium {
            return ci.resized(to: 2000)
        }

        if request.quality == .adaptive {
            if request.contentCategory == .people {
                return ci  // Preserve max quality for faces
            }
            return ci.resized(to: 1600)
        }

        return ci
    }

    // MARK: - Full Rendering Pipeline

    /// Executes the full AI rendering pipeline asynchronously.
    ///
    /// Stages:
    /// 1. Vision-based auto orientation
    /// 2. ML HDR tone mapping
    /// 3. AI-driven sharpness enhancement
    /// 4. Standard tone curve for HEIC
    /// 5. Level-of-detail resolution clamp
    /// 6. Watermark overlay
    /// 7. Final CI → UIImage conversion
    ///
    /// - Parameters:
    ///   - image: Input UIImage.
    ///   - request: Rendering configuration & metadata.
    /// - Returns: Rendered UIImage.
    private func performFinalRender(_ image: UIImage, request: AIImageRequest) async -> UIImage {
        guard let cg = image.cgImage else { return image }
        var ci = CIImage(cgImage: cg)

        // 1. Vision auto orientation
        if let oriented = try? await autoOrientUsingVision(ci) {
            ci = oriented
        }

        // 2. ML HDR tone map
        if let mlMap = try? await mlToneMap(ci) {
            ci = mlMap
        }

        // 3. AI ML-driven sharpening
        if AIImageConfig.shared.preset == .highQuality {
            ci = await applyAIMLSharpen(ci)
        }

        // 4. Tone map for HEIC
        if request.expectedFormatHint == .heic || request.preferredFormat == .heic {
            ci = applyToneMap(ci)
        }

        // 5. Adaptive resolution clamp
        ci = applyLODClamp(ci, request: request)

        // 6. Optional watermarking
        if watermarkEnabled {
            ci = overlayWatermark(on: ci)
        }

        // 7. Final render
        guard let rendered = ciContext.createCGImage(ci, from: ci.extent) else {
            return image
        }

        return UIImage(cgImage: rendered, scale: image.scale, orientation: .up)
    }

    // ============================================================
    // MARK: - Vision Auto Orientation
    // ============================================================

    /// Attempts to auto-orient the image using Vision face detection.
    ///
    /// Logic:
    /// - If one or more faces exist → orient to `.up`
    /// - Otherwise → leave untouched
    ///
    /// - Parameter ci: Input CIImage.
    /// - Returns: Oriented CIImage.
    private func autoOrientUsingVision(_ ci: CIImage) async throws -> CIImage {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNDetectFaceRectanglesRequest()
                let handler = VNImageRequestHandler(ciImage: ci, options: [:])

                do {
                    try handler.perform([request])
                    if let faces = request.results, !faces.isEmpty {
                        continuation.resume(returning: ci.oriented(.up))
                    } else {
                        continuation.resume(returning: ci)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // ============================================================
    // MARK: - ML Tone Mapping (CoreML HDR Correction)
    // ============================================================

    /// Applies ML-based HDR → SDR tone mapping using model `AIHDRToneMap_v1`.
    ///
    /// - Parameter ci: Input CIImage.
    /// - Parameter modelManager: Model source (defaults to global).
    /// - Returns: Tone-mapped CIImage.
    private func mlToneMap(
        _ ci: CIImage,
        modelManager: AIModelManager = .shared
    ) async throws -> CIImage {

        guard
            let wrapper = await modelManager.model(named: "AIHDRToneMap_v1") as? CoreMLModelWrapper,
            let mlModel = wrapper.coreMLModel
        else {
            return ci
        }

        let vnModel = try VNCoreMLModel(for: mlModel)
        let request = VNCoreMLRequest(model: vnModel)
        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(ciImage: ci, options: [:])
        try handler.perform([request])

        guard
            let obs = request.results?.first as? VNPixelBufferObservation,
            let outCG = CoreMLModelWrapper.image(from: obs.pixelBuffer)?.cgImage
        else {
            return ci
        }

        return CIImage(cgImage: outCG)
    }

    // ============================================================
    // MARK: - ML High-Quality Sharpen
    // ============================================================

    /// AI-driven sharpening based on predicted sharpness score.
    ///
    /// Steps:
    /// 1. Convert CI → UIImage
    /// 2. Predict sharpness with `AICacheQualityPredictor`
    /// 3. Apply `CISharpenLuminance` based on score
    ///
    /// - Parameter ci: Input CIImage.
    /// - Returns: Sharpened CIImage.
    private func applyAIMLSharpen(_ ci: CIImage) async -> CIImage {
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return ci }
        let input = UIImage(cgImage: cg)

        let predicted = await AICacheQualityPredictor.shared.predictSharpness(for: input)

        guard let filter = CIFilter(name: "CISharpenLuminance") else { return ci }

        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(predicted * 0.8, forKey: kCIInputSharpnessKey)

        return filter.outputImage ?? ci
    }

    // ============================================================
    // MARK: - Standard Tone Mapping
    // ============================================================

    /// Applies a static tone curve for HEIC images.
    ///
    /// Uses Core Image’s `CIToneCurve` filter.
    ///
    /// - Parameter ci: Input CIImage.
    /// - Returns: Tone mapped CIImage.
    private func applyToneMap(_ ci: CIImage) -> CIImage {
        guard let filter = CIFilter(name: "CIToneCurve") else { return ci }

        filter.setValue(ci, forKey: kCIInputImageKey)

        filter.setValue(CIVector(x: 0.0,  y: 0.0), forKey: "inputPoint0")
        filter.setValue(CIVector(x: 0.25, y: 0.2), forKey: "inputPoint1")
        filter.setValue(CIVector(x: 0.5,  y: 0.5), forKey: "inputPoint2")
        filter.setValue(CIVector(x: 0.75, y: 0.9), forKey: "inputPoint3")
        filter.setValue(CIVector(x: 1.0,  y: 1.0), forKey: "inputPoint4")

        return filter.outputImage ?? ci
    }

    // ============================================================
    // MARK: - Watermarking
    // ============================================================

    /// Indicates whether watermarking is enabled.
    private var watermarkEnabled: Bool {
        return false
    }

    /// Overlays a watermark image at bottom-right corner.
    ///
    /// - Parameter ci: Input CIImage.
    /// - Returns: CIImage with watermark applied.
    private func overlayWatermark(on ci: CIImage) -> CIImage {
        guard let cg = UIImage(named: "aiautoimage_watermark")?.cgImage else { return ci }

        let wCI = CIImage(cgImage: cg)
        let rect = CGRect(
            x: ci.extent.maxX - wCI.extent.width - 24,
            y: ci.extent.minY + 24,
            width: wCI.extent.width,
            height: wCI.extent.height
        )

        return wCI
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
            .composited(over: ci)
    }
}

public extension UIImage {

    /// Converts a pixel buffer output from CoreML/Vision to `UIImage`.
    ///
    /// - Parameter pixelBuffer: Pixel buffer.
    /// - Returns: Converted `UIImage` or nil.
    static func fromPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: [.useSoftwareRenderer: false])

        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }

    /// Alias for `fromPixelBuffer` for convenience.
    static func from(pixelBuffer: CVPixelBuffer) -> UIImage? {
        return fromPixelBuffer(pixelBuffer)
    }
}

// ----------------------------------------------------------
// MARK: - CIImage Resize Helper (Private)
// ----------------------------------------------------------

private extension CIImage {

    /// Resizes the CIImage so its longest edge matches `maxSize`.
    ///
    /// - Parameter maxSize: Desired longest side length.
    /// - Returns: Scaled CIImage (no upscaling).
    func resized(to maxSize: CGFloat) -> CIImage {
        let scale = maxSize / max(extent.width, extent.height)
        if scale >= 1.0 { return self } // Do not upscale

        let transform = CGAffineTransform(scaleX: scale, y: scale)
        return self.transformed(by: transform)
    }
}

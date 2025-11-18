//
//  UIImage+AI.swift
//  AIAutoImageCore
//

import UIKit
import CoreImage
import Vision
import CoreML
import AIAutoImageCore

/// A dedicated shared Core Image context used for GPU-accelerated rendering.
///
/// Using a single shared CIContext significantly improves performance and reduces
/// memory overhead across repeated image processing operations.
private let _aiCIContext = CIContext()

// MARK: - UIImage AI Extensions

public extension UIImage {

    // =========================================================
    // MARK: - 1) AI Sharpen (CISharpenLuminance)
    // =========================================================

    /// Applies luminance-based sharpening to the image using Core Image.
    ///
    /// This filter increases edge clarity and fine detail by sharpening only
    /// contrast-driven luminance components rather than color, producing a
    /// natural sharpening effect.
    ///
    /// - Parameter amount: The sharpen intensity (`0.0`–`2.0` recommended).
    /// - Returns: A new `UIImage` with sharpening applied, or the original on failure.
    func ai_sharpen(amount: CGFloat) -> UIImage {
        guard let cg = self.cgImage else { return self }
        let ci = CIImage(cgImage: cg)

        guard let filter = CIFilter(name: "CISharpenLuminance") else { return self }
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(amount, forKey: kCIInputSharpnessKey)

        guard let out = filter.outputImage,
              let cgOut = _aiCIContext.createCGImage(out, from: out.extent)
        else { return self }

        return UIImage(cgImage: cgOut, scale: self.scale, orientation: self.imageOrientation)
    }

    // =========================================================
    // MARK: - 2) Vision-Based Local Contrast Boost (async)
    // =========================================================

    /// Boosts contrast only in visually salient areas using Vision saliency detection.
    ///
    /// Steps:
    /// 1. Uses `VNGenerateAttentionBasedSaliencyImageRequest` to extract the regions
    ///    of visual attention (subject/foreground).
    /// 2. Enhances contrast using `CIColorControls`.
    /// 3. Blends the enhanced image back into the original using the saliency mask.
    ///
    /// This produces a subtle, subject-focused clarity and contrast enhancement.
    ///
    /// - Returns: A new `UIImage` with saliency-weighted contrast boosting applied.
    /// - Note: Safe to run off the main thread; returns on continuation thread.
    @available(iOS 15.0, *)
    func ai_contrastBoostedUsingVision() async -> UIImage {
        guard let cg = self.cgImage else { return self }

        return await withCheckedContinuation { cont in
            Task.detached(priority: .userInitiated) {

                let req = VNGenerateAttentionBasedSaliencyImageRequest()
                let handler = VNImageRequestHandler(cgImage: cg)

                try? handler.perform([req])

                guard let obs = req.results?.first as? VNSaliencyImageObservation else {
                    cont.resume(returning: self)
                    return
                }

                let mask: CIImage = CIImage(cvPixelBuffer: obs.pixelBuffer)
                let baseCI = CIImage(cgImage: cg)

                guard let filter = CIFilter(name: "CIColorControls") else {
                    cont.resume(returning: self)
                    return
                }

                filter.setValue(baseCI, forKey: kCIInputImageKey)
                filter.setValue(1.15, forKey: kCIInputContrastKey)

                guard let out = filter.outputImage else {
                    cont.resume(returning: self)
                    return
                }

                // Blend only salient (foreground) areas
                let blended = baseCI.applyingFilter(
                    "CIBlendWithMask",
                    parameters: [
                        kCIInputBackgroundImageKey: baseCI,
                        kCIInputMaskImageKey: mask,
                        kCIInputImageKey: out
                    ]
                )

                if let cgOut = _aiCIContext.createCGImage(blended, from: blended.extent) {
                    cont.resume(returning: UIImage(cgImage: cgOut, scale: self.scale, orientation: self.imageOrientation))
                    return
                }

                cont.resume(returning: self)
            }
        }
    }

    // =========================================================
    // MARK: - 3) ML-Based Denoiser (async)
    // =========================================================

    /// Removes noise from the image using a CoreML denoising model.
    ///
    /// Uses the custom bundled model:
    /// **AIDenoiser_v1.mlmodel**
    ///
    /// Steps:
    /// 1. Converts image → CVPixelBuffer
    /// 2. Runs inference on the ML model
    /// 3. Converts the output pixel buffer → UIImage
    ///
    /// - Returns: A cleaned, denoised version of the image, or original if ML fails.
    func ai_denoisedByML() async -> UIImage {
        guard let _ = self.cgImage else { return self }

        guard let model = await AIModelManager.shared.model(named: "AIDenoiser_v1"),
              let mlModel = model.coreMLModel
        else { return self }

        return await Task(priority: .userInitiated) { @MainActor in
            do {
                guard let buffer = self.pixelBuffer(from: self) else { return self }

                let provider = try MLDictionaryFeatureProvider(
                    dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)]
                )

                let output = try mlModel.prediction(from: provider)

                if let px = output.featureValue(for: "outputImage")?.imageBufferValue {
                    let ci = CIImage(cvPixelBuffer: px)
                    if let cg = _aiCIContext.createCGImage(ci, from: ci.extent) {
                        return UIImage(cgImage: cg)
                    }
                }
                return self
            } catch {
                return self
            }
        }.value
    }

    // =========================================================
    // MARK: - Helper: UIImage → CVPixelBuffer
    // =========================================================

    /// Converts a `UIImage` into a `CVPixelBuffer` for use with CoreML models.
    ///
    /// The pixel buffer:
    /// - Matches the original image dimensions
    /// - Uses 32-bit BGRA format (compatible with Vision+CoreML)
    ///
    /// - Parameter image: The source `UIImage`.
    /// - Returns: A pixel buffer representation of the image, or `nil` on failure.
    private func pixelBuffer(from image: UIImage) -> CVPixelBuffer? {
        guard let cg = image.cgImage else { return nil }

        let width = cg.width, height = cg.height

        let attrs: CFDictionary = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ] as CFDictionary

        var px: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs,
            &px
        )

        guard let buffer = px else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        if let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        return buffer
    }
}

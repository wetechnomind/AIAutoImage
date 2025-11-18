//
//  AIAccessibility.swift
//  AIAutoImageCore
//
//  Provides automatic accessibility descriptions for images.
//  Three-tier strategy:
//    1. CoreML captioning model (if available)
//    2. Vision object/scene detection
//    3. Fallback heuristic description
//
//  Integrated into UIKit extensions for UIImageView to enhance accessibility.
//

import Foundation
import UIKit
import Vision
import CoreML

/// Generates accessibility labels for images using a multi-stage pipeline.
///
/// `AIAccessibility` attempts to describe an image using:
///  1. A CoreML captioning model named **"AICaption_v1"**
///  2. Vision framework's scene/object classification
///  3. Pixel-size-based fallback description
///
/// The description process is fully automatic and asynchronous.
/// Results are automatically applied to `UIImageView` when requested.
public final class AIAccessibility: @unchecked Sendable {

    // MARK: - Singleton

    /// Shared global instance used throughout the framework.
    public static let shared = AIAccessibility()

    private init() {}

    // MARK: - Public API
    // ---------------------------------------------------------------------

    /**
     Generates the most accurate accessibility description for the image.

     Order of evaluation:
      1. CoreML captioning model (*AICaption_v1*)
      2. Vision classification fallback
      3. Heuristic fallback (pixel dimensions)

     - Parameter image: The source image.
     - Returns: A human-readable description suitable for use in `accessibilityLabel`.
     */
    public func description(for image: UIImage) async -> String {
        // 1. CoreML caption generator
        if let caption = await generateCaptionWithModel(image) {
            return caption
        }

        // 2. Vision-based object/scene classification
        if let visionDesc = await detectObjects(image) {
            return visionDesc
        }

        // 3. Fallback heuristic
        return fallbackDescription(image)
    }

    /**
     Synchronously attempts to describe an image using a lightweight heuristic.

     This method is intended only for best-effort synchronous contexts
     (e.g., debugging, placeholder metadata).
     Heavy Vision/CoreML operations are avoided.

     - Parameter image: The target image.
     - Returns: A minimal, pixel-size-based description.
     */
    public func descriptionSync(for image: UIImage) -> String {
        if let ci = image.cgImage {
            return "Image of size \(ci.width)x\(ci.height)"
        }
        return "image"
    }

    /**
     Applies an AI-generated accessibility description to a `UIImageView`.

     The description generation is asynchronous and non-blocking.
     UI is updated on the main actor once the description is ready.

     - Parameters:
       - imageView: The target view to receive the description.
       - image: Image used to compute the accessibility label.
     */
    @MainActor
    public func applyToImageView(_ imageView: UIImageView, image: UIImage) {
        Task {
            let label = await description(for: image)
            await MainActor.run {
                imageView.isAccessibilityElement = true
                imageView.accessibilityLabel = label
            }
        }
    }

    // MARK: - CoreML Caption Model
    // ---------------------------------------------------------------------

    /**
     Attempts to generate a natural-language caption for the image using
     a CoreML captioning model named **"AICaption_v1"**.

     - Parameter image: The source image to caption.
     - Returns: A caption string, or `nil` if unavailable or prediction failed.
     */
    private func generateCaptionWithModel(_ image: UIImage) async -> String? {
        let manager = AIModelManager.shared

        // Load captioning model if available
        guard let model = await manager.model(named: "AICaption_v1") else {
            return nil
        }

        let inputs: [String: Any] = ["image": image]

        do {
            let result = try model.predict(inputs: inputs)
            if let caption = result["caption"] as? String, caption.count > 2 {
                return caption
            }
        } catch {
            await AILog.shared.warning(
                "AIAccessibility: CoreML captioning failed: \(error.localizedDescription)"
            )
        }

        return nil
    }

    // MARK: - Vision Classification Fallback
    // ---------------------------------------------------------------------

    /**
     Uses Vision's built-in classification model to detect objects or scenes
     within the image.

     - Parameter image: The image to classify.
     - Returns: A comma-separated description of detected labels, or nil.
     */
    private func detectObjects(_ image: UIImage) async -> String? {
        guard let cgImage = image.cgImage else { return nil }

        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let results = request.results, !results.isEmpty else {
            return nil
        }

        // Top 3 classifications
        let labels = results
            .prefix(3)
            .map { $0.identifier }
            .joined(separator: ", ")

        return labels.isEmpty ? nil : "An image containing: \(labels)"
    }

    // MARK: - Fallback Description
    // ---------------------------------------------------------------------

    /**
     Simple pixel-dimension fallback description used when both CoreML and
     Vision fail to produce meaningful results.

     - Parameter image: The image to describe.
     - Returns: A pixel-dimension summary.
     */
    private func fallbackDescription(_ image: UIImage) -> String {
        guard let cg = image.cgImage else { return "image" }
        return "Image (\(cg.width)x\(cg.height) pixels)"
    }
}

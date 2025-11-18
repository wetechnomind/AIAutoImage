//
//  AICacheQualityPredictor.swift
//  AIAutoImageCore
//
//  Multi-stage AI sharpness predictor for cache prioritization.
//
//  Strategy:
//    1. CoreML model prediction (if available)
//    2. Dynamic Vision blur detection (VNDetectBlurRequest)
//    3. Heuristic fallback when APIs or models are unavailable
//
//  Output:
//    • Sharpness score in normalized range 0.0–1.0
//

import Foundation
import UIKit
#if canImport(Vision)
import Vision
#endif
import CoreML

/// High-level adaptive sharpness prediction engine used by `AICache`,
/// `AIDiskManifest`, and other AI-enhanced components.
///
/// This actor provides a **multi-tier sharpness scoring pipeline**:
///
/// ### 1. CoreML-based sharpness model
/// If a custom ML model (`AISharpnessPredictor_v1`) is available, it produces the most
/// accurate sharpness score. Returns `obs.confidence` (normalized 0–1).
///
/// ### 2. Vision blur detection
/// Uses dynamic runtime access to `VNDetectBlurRequest` if available (iOS 17+),
/// extracting `blurScore` through private KVC. Score is inverted:
/// `sharpness = 1 – blurScore`.
///
/// ### 3. Heuristic fallback
/// When no ML or Vision API is available, falls back to frame-size heuristics.
///
/// All results are clamped to **0.0–1.0** and optimized for caching logic.
public actor AICacheQualityPredictor: Sendable {

    // MARK: - Singleton
    // ---------------------------------------------------------------------

    /// Shared global predictor instance.
    /// Declared `nonisolated` so it can be accessed without actor-hopping for convenience.
    public nonisolated static let shared = AICacheQualityPredictor()

    private init() {}

    // MARK: - Public API
    // ---------------------------------------------------------------------

    /**
     Predicts an image’s sharpness using the best-available method.

     Pipeline:
      1. Try CoreML sharpness model
      2. Try Vision blur detection (`VNDetectBlurRequest`)
      3. Fallback heuristic estimation

     - Parameter image: The image to evaluate.
     - Returns: A normalized sharpness score from **0.0 to 1.0**.
     */
    public func predictSharpness(for image: UIImage) async -> Double {

        // --- Stage 1: CoreML model ---
        if let mlValue = try? await runMLModel(image) {
            return clamp(mlValue, 0, 1)
        }

        // --- Stage 2: Vision runtime blur scoring ---
        if let blurValue = try? runVisionBlur(image) {
            return clamp(blurValue, 0, 1)
        }

        // --- Stage 3: Heuristic fallback ---
        return heuristic(for: image)
    }


    // MARK: - CoreML Predictor
    // ---------------------------------------------------------------------

    /**
     Attempts to run the CoreML sharpness model if available.

     Uses:
     - Model name: `"AISharpnessPredictor_v1"`
     - Vision `VNCoreMLRequest` wrapper
     - Confidence value as final sharpness score

     - Returns: Normalized score (0–1) or `nil` if unavailable.
     */
    private func runMLModel(_ image: UIImage) async throws -> Double? {

        guard
            let wrapper = await AIModelManager.shared.model(named: "AISharpnessPredictor_v1") as? CoreMLModelWrapper,
            let model = wrapper.coreMLModel
        else {
            return nil
        }

        let vnModel = try VNCoreMLModel(for: model)
        let request = VNCoreMLRequest(model: vnModel)
        request.imageCropAndScaleOption = .scaleFill

        guard let cg = image.cgImage else { return nil }

        let handler = VNImageRequestHandler(cgImage: cg)
        try handler.perform([request])

        if let obs = request.results?.first as? VNClassificationObservation {
            return Double(obs.confidence)
        }

        return nil
    }


    // MARK: - Vision Blur Detection (Dynamic Runtime)
    // ---------------------------------------------------------------------

    /**
     Detects blur using `VNDetectBlurRequest` *(if available at runtime)*.

     Steps:
      - Dynamically loads class using `NSClassFromString`
      - Executes request using `VNImageRequestHandler`
      - Extracts `blurScore` using KVC
      - Converts blurScore → sharpnessScore
        ```
        sharpness = 1.0 - blurScore
        ```

     - Returns: Sharpness score (0–1) or nil if unavailable.
     */
    private func runVisionBlur(_ image: UIImage) throws -> Double? {

        guard let cg = image.cgImage else { return nil }

        // Runtime detection of VNDetectBlurRequest
        guard let blurClass = NSClassFromString("VNDetectBlurRequest") as? VNRequest.Type else {
            return estimateBlurHeuristically(image)
        }

        let request = blurClass.init()

        let handler = VNImageRequestHandler(cgImage: cg)
        try handler.perform([request])

        // Extract `blurScore` dynamically via KVC
        if
            let result = request.results?.first,
            let value = result.value(forKey: "blurScore") as? NSNumber
        {
            let score = value.doubleValue
            return 1.0 - min(max(score, 0.0), 1.0)
        }

        return nil
    }


    // MARK: - Heuristic Fallback
    // ---------------------------------------------------------------------

    /**
     Simple size-based heuristic used when no ML or Vision APIs are available.

     - Small images (< 800 px) are assumed slightly blurry
     - Large images are assumed slightly sharper

     - Returns: Estimated sharpness score.
     */
    private func heuristic(for image: UIImage) -> Double {
        guard let cg = image.cgImage else { return 0.5 }
        return cg.width < 800 || cg.height < 800 ? 0.35 : 0.65
    }

    /**
     Fallback blur estimator used when Vision blur API exists but cannot be executed.

     - Returns: Estimated sharpness-like score (0–1).
     */
    private func estimateBlurHeuristically(_ image: UIImage) -> Double {
        guard let cg = image.cgImage else { return 0.5 }
        let w = cg.width, h = cg.height
        return (w < 900 || h < 900) ? 0.3 : 0.6
    }


    // MARK: - Utility
    // ---------------------------------------------------------------------

    /// Clamps a numeric value to the inclusive range `[lo, hi]`.
    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        return max(lo, min(v, hi))
    }
}

//
//  AIModel.swift
//  AIAutoImageCore
//
//  Updated for full AI, CoreML, and Vision integration.
//  Supports:
//    • CoreML models (via coreMLModel)
//    • Custom inference engines
//    • Dictionary-based prediction I/O
//    • Thread-safe, actor-friendly execution
//

import Foundation
import UIKit
import CoreML

/// A unified protocol that abstracts over multiple types of AI inference engines,
/// including CoreML models, custom neural backends (e.g. MPSGraph, ONNX, PyTorch),
/// and hybrid pipelines.
///
/// Conforming types expose:
/// - A unique name (for caching & debugging)
/// - Estimated memory requirements
/// - Optional CoreML model reference
/// - A dynamic dictionary-based prediction function
///
/// `AIModel` is the backbone of AIAutoImage's intelligence system and powers:
/// - Caption generation
/// - Sharpness prediction
/// - CDN latency prediction
/// - Variant selection
/// - Image enhancement tasks
public protocol AIModel: Sendable {

    // MARK: - Metadata

    /// Human-readable identifier for the model.
    ///
    /// Used by:
    /// - `AIModelManager` for lookup & caching
    /// - Debug tools
    /// - Plugin and analytics layers
    var name: String { get }

    /// Approximate model memory footprint in bytes.
    ///
    /// This helps AIAutoImage decide:
    /// - whether model eviction is needed,
    /// - loading order during pressure situations.
    var sizeBytes: Int { get }


    // MARK: - CoreML Integration

    /// Optional reference to an underlying CoreML model.
    ///
    /// - If the model is implemented fully using CoreML, this should return
    ///   the actual `MLModel` instance.
    ///
    /// - If the model is backed by another runtime (ONNXRuntime, PyTorch Mobile,
    ///   TensorFlow Lite, MPSGraph, custom C++), return `nil`.
    ///
    /// AIAutoImage uses this value to:
    /// - perform CoreML-based Vision requests
    /// - auto-wrap into VNCoreMLModel when needed
    var coreMLModel: MLModel? { get }


    // MARK: - Inference

    /// Runs inference using dynamic key/value inputs and returns a generic output map.
    ///
    /// Implementations should convert incoming values into model-appropriate formats,
    /// perform inference, then convert any model outputs into:
    /// - `UIImage`
    /// - `Data`
    /// - `Float`/`Double`
    /// - `String`
    /// - Multi-output dictionaries
    ///
    /// ### Examples
    ///
    /// **Captioning**
    /// ```
    /// let out = try model.predict(inputs: ["image": uiImage])
    /// let caption = out["caption"] as? String
    /// ```
    ///
    /// **Super-resolution**
    /// ```
    /// let out = try model.predict(inputs: ["image": lowRes])
    /// let upscaled = out["image"] as? UIImage
    /// ```
    ///
    /// **Depth estimation**
    /// ```
    /// let map = out["depth"] as? UIImage
    /// ```
    ///
    /// - Throws:
    ///   - `AIModelError.missingRequiredInput`
    ///   - `AIModelError.unsupportedInputType`
    ///   - `AIModelError.predictionFailed`
    ///   - `AIModelError.modelNotLoaded`
    ///
    /// - Returns: Dictionary of model outputs.
    func predict(inputs: [String: Any]) throws -> [String: Any]
}


// MARK: - Common Error Types

/// Error types for AI model inference, covering CoreML failures and custom engines.
public enum AIModelError: Error, LocalizedError {

    /// A required input is missing from the input dictionary.
    case missingRequiredInput(String)

    /// The model received an unsupported input type.
    case unsupportedInputType(String)

    /// The model returned an output that could not be interpreted.
    case unsupportedOutput(String)

    /// General failure during prediction (e.g. CoreML threw an exception).
    case predictionFailed(String)

    /// The model is not loaded (e.g., CoreML model failed to load from disk).
    case modelNotLoaded

    /// Internal engine error (unexpected failure).
    case internalError(String)


    /// Human-readable error message surfaced to developers.
    public var errorDescription: String? {
        switch self {

        case .missingRequiredInput(let key):
            return "Missing required input: '\(key)'"

        case .unsupportedInputType(let type):
            return "Unsupported input type: \(type)"

        case .unsupportedOutput(let output):
            return "Unsupported model output: \(output)"

        case .predictionFailed(let msg):
            return "Prediction failed: \(msg)"

        case .modelNotLoaded:
            return "Model not loaded or unavailable"

        case .internalError(let msg):
            return "Internal model error: \(msg)"
        }
    }
}

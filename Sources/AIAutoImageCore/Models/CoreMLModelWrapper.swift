//
//  CoreMLModelWrapper.swift
//  AIAutoImageCore
//

import Foundation
import UIKit
@preconcurrency import CoreML
@preconcurrency import VideoToolbox

/// A unified wrapper around a CoreML model conforming to the `AIModel` protocol.
///
/// This class:
/// - Wraps `MLModel` instances
/// - Converts dynamic Swift dictionaries into `MLFeatureProvider`
/// - Handles multi-output serialization
/// - Converts between `UIImage` ↔ `CVPixelBuffer`
///
/// The wrapper is designed to work seamlessly inside the AIAutoImage
/// AI pipeline, including predictors, CDN scorers, and vision models.
///
///
/// # Example
/// ```swift
/// let wrapper = CoreMLModelWrapper(name: "super_res", mlModel: model)
/// let result = try wrapper.predict(inputs: ["image": inputUIImage])
/// let outputImage = result["output"] as? UIImage
/// ```
public final class CoreMLModelWrapper: AIModel, @unchecked Sendable {

    // MARK: - CoreML Model Reference

    /// Optional underlying CoreML model.
    ///
    /// If this wrapper represents a CoreML model, this will be non-nil.
    /// If this wrapper wraps a custom backend (PyTorch, ONNX, etc.),
    /// this will be `nil`.
    public var coreMLModel: MLModel?
    

    // MARK: - Properties

    /// Human-readable model name.
    public let name: String

    /// Approximate memory footprint in bytes.
    ///
    /// The size is estimated using a heuristic value, since CoreML does not
    /// expose accurate runtime memory usage.
    public let sizeBytes: Int


    // MARK: - Initialization

    /// Creates a new wrapper around a CoreML model.
    ///
    /// - Parameters:
    ///   - name: Unique identifier for this model.
    ///   - mlModel: Underlying compiled CoreML model.
    public init(name: String, mlModel: MLModel) {
        self.name = name
        self.coreMLModel = mlModel
        self.sizeBytes = CoreMLModelWrapper.estimateModelSize(mlModel)
    }


    // MARK: - Prediction

    /// Runs inference using a dictionary-based input model.
    ///
    /// Inputs may include:
    /// - `UIImage` → converted to `CVPixelBuffer`
    /// - `Double`, `NSNumber`
    /// - `String`
    /// - `[Double]` → converted to `MLMultiArray`
    ///
    /// Returns a dictionary mapping output feature names to:
    /// - `UIImage`
    /// - `Double`
    /// - `String`
    /// - `MLMultiArray`
    ///
    /// - Parameter inputs: Input features keyed by CoreML model input names.
    /// - Returns: Output features converted to Swift-native types.
    /// - Throws:
    ///   - `AIModelError.modelNotLoaded`
    ///   - `AIModelError.unsupportedInputType`
    ///   - `AIModelError.predictionFailed`
    public func predict(inputs: [String : Any]) throws -> [String : Any] {

        guard let model = coreMLModel else {
            throw AIModelError.modelNotLoaded
        }

        let provider = try prepareFeatureProvider(inputs)

        let outputProvider: MLFeatureProvider
        do {
            outputProvider = try model.prediction(from: provider)
        } catch {
            throw AIModelError.predictionFailed(error.localizedDescription)
        }

        return try serializeOutput(outputProvider)
    }


    // MARK: - Input Preparation

    /// Converts a Swift dictionary into an `MLFeatureProvider`.
    ///
    /// Supported input types:
    /// - `UIImage` → `CVPixelBuffer`
    /// - `Double`, `NSNumber`
    /// - `String`
    /// - `[Double]` → `MLMultiArray`
    ///
    /// - Throws: `AIModelError.unsupportedInputType`
    private func prepareFeatureProvider(_ inputs: [String: Any]) throws -> MLFeatureProvider {

        let dict = try inputs.reduce(into: [String: MLFeatureValue]()) { result, entry in
            let (key, value) = entry

            switch value {

            case let img as UIImage:
                guard let buffer = CoreMLModelWrapper.pixelBuffer(from: img) else {
                    throw AIModelError.unsupportedInputType("UIImage->CVPixelBuffer failed")
                }
                result[key] = MLFeatureValue(pixelBuffer: buffer)

            case let num as NSNumber:
                result[key] = MLFeatureValue(double: num.doubleValue)

            case let str as String:
                result[key] = MLFeatureValue(string: str)

            case let dbl as Double:
                result[key] = MLFeatureValue(double: dbl)

            case let arr as [Double]:
                let ma = try CoreMLModelWrapper.makeMultiArray(arr)
                result[key] = MLFeatureValue(multiArray: ma)

            default:
                throw AIModelError.unsupportedInputType("Unsupported input type for key '\(key)'")
            }
        }

        return try MLDictionaryFeatureProvider(dictionary: dict)
    }


    // MARK: - Output Serialization

    /// Serializes `MLFeatureProvider` into Swift-native output types.
    ///
    /// Output types:
    /// - `.string`  → `String`
    /// - `.double`  → `Double`
    /// - `.multiArray` → `MLMultiArray`
    /// - `.image` → `UIImage` (converted from `CVPixelBuffer`)
    ///
    /// - Parameter features: Raw CoreML output provider.
    /// - Returns: Swift-native dictionary.
    /// - Throws: `AIModelError.unsupportedOutput`
    private func serializeOutput(_ features: MLFeatureProvider) throws -> [String: Any] {
        var out: [String: Any] = [:]

        for featureName in features.featureNames {
            guard let fv = features.featureValue(for: featureName) else { continue }

            switch fv.type {

            case .string:
                out[featureName] = fv.stringValue

            case .double:
                out[featureName] = fv.doubleValue

            case .multiArray:
                out[featureName] = fv.multiArrayValue

            case .image:
                if let buf = fv.imageBufferValue,
                   let ui = CoreMLModelWrapper.image(from: buf) {
                    out[featureName] = ui
                }

            default:
                throw AIModelError.unsupportedOutput("Unsupported CoreML output: \(fv.type)")
            }
        }

        return out
    }


    // MARK: - Model Size Estimation

    /// Heuristic estimation of model memory footprint.
    ///
    /// CoreML does not provide an API for exact memory usage,
    /// so this function returns a best-effort approximation.
    private static func estimateModelSize(_ model: MLModel) -> Int {
        return 5_000_000 // ~5 MB default estimate
    }


    // MARK: - MultiArray Helper

    /// Converts a `[Double]` array into a 1D `MLMultiArray`.
    ///
    /// - Parameter array: Input floating-point array.
    /// - Returns: CoreML-compatible multiarray.
    private static func makeMultiArray(_ array: [Double]) throws -> MLMultiArray {
        let ma = try MLMultiArray(shape: [NSNumber(value: array.count)], dataType: .double)
        for (i, v) in array.enumerated() {
            ma[i] = NSNumber(value: v)
        }
        return ma
    }


    // MARK: - UIImage → CVPixelBuffer

    /// Converts a `UIImage` to a CoreML-compatible `CVPixelBuffer`.
    ///
    /// Used for image-based inference (classification, vision, upscaling, etc.)
    private static func pixelBuffer(from uiImage: UIImage) -> CVPixelBuffer? {
        guard let cgImage = uiImage.cgImage else { return nil }

        let width = cgImage.width
        let height = cgImage.height

        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )

        guard let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])

        if let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) {
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }


    // MARK: - CVPixelBuffer → UIImage

    /// Converts CoreML image buffer output into a standard `UIImage`.
    ///
    /// - Parameter buffer: Vision/ML pixel buffer.
    /// - Returns: A rendered `UIImage`, or `nil` on conversion failure.
    public static func image(from buffer: CVPixelBuffer) -> UIImage? {
        let ci = CIImage(cvPixelBuffer: buffer).oriented(.up)
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

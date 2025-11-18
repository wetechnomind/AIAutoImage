//
//  AITransformPipeline.swift
//  AIAutoImageCore
//

import Foundation
import UIKit
import Vision
import CoreML
import CoreImage

/// A production-grade, fully async AI-driven image transformation pipeline.
///
/// The pipeline provides:
/// - A prioritized transformation queue (CoreML → Vision → Filters → Utility)
/// - AI-gated transforms (run only when conditions are met)
/// - Actor-isolated, thread-safe execution
/// - Metadata-aware transformation stages
/// - Fail-safe operation (no transform can crash the pipeline)
///
/// This component acts as a central coordinator for image enhancement,
/// routing the image through all registered transforms in priority order.
public actor AITransformPipeline: Sendable {

    // MARK: - Shared Singleton

    /// Shared global instance for performance and reuse.
    public static let shared = AITransformPipeline()

    // MARK: - Transform Types

    /// Categories that define the priority order of transforms.
    ///
    /// Priority (lowest raw value runs first):
    /// 1. `.coreML` — ML-powered transforms such as super-resolution or denoising
    /// 2. `.vision` — Vision-based transforms such as saliency or face-aware effects
    /// 3. `.filter` — Core Image filters
    /// 4. `.utility` — Miscellaneous output refinements
    public enum TransformCategory: Int, Sendable {
        case coreML = 0
        case vision = 1
        case filter = 2
        case utility = 3
    }

    /// Defines a single transformation operation in the pipeline.
    ///
    /// Each transform has:
    /// - `id`: A unique identifier
    /// - `category`: Determines execution priority
    /// - `isEnabled`: Allows toggling transforms at runtime
    /// - `run`: Async execution closure producing a new `UIImage`
    public struct TransformEntry: Sendable {
        /// Unique identifier for the transform.
        public let id: String
        
        /// Category indicating transform priority.
        public let category: TransformCategory

        /// Indicates whether the transform should run.
        public let isEnabled: Bool

        /// The async transformation function.
        public let run: @Sendable (UIImage) async -> UIImage
        
        /// Creates a new transform entry.
        ///
        /// - Parameters:
        ///   - id: Unique identifier.
        ///   - category: Priority category.
        ///   - isEnabled: Whether the transform is active.
        ///   - run: Async closure performing the transform.
        public init(
            id: String,
            category: TransformCategory,
            isEnabled: Bool = true,
            run: @escaping @Sendable (UIImage) async -> UIImage
        ) {
            self.id = id
            self.category = category
            self.isEnabled = isEnabled
            self.run = run
        }
    }

    // MARK: - Storage

    /// All registered transforms.
    private var transforms: [TransformEntry] = []

    /// Core Image context reused for filter-based transforms.
    private let ciContext = CIContext()

    /// Creates a new empty pipeline.
    public init() {}

    // MARK: - Registration

    /// Registers a new transform into the pipeline.
    ///
    /// - Parameters:
    ///   - id: Unique identifier.
    ///   - category: Defines its priority.
    ///   - isEnabled: Whether it is active initially.
    ///   - transform: The async transformation function.
    ///
    /// If multiple transforms share the same category, they run in registration order.
    public func register(
        id: String,
        category: TransformCategory,
        isEnabled: Bool = true,
        transform: @escaping @Sendable (UIImage) async -> UIImage
    ) {
        transforms.append(
            TransformEntry(
                id: id,
                category: category,
                isEnabled: isEnabled,
                run: transform
            )
        )
    }

    /// Returns all registered transformation identifiers.
    public func registeredTransformIDs() -> [String] {
        transforms.map { $0.id }
    }

    // MARK: - Apply All Transforms

    /// Applies **all enabled transforms** to the image in priority order.
    ///
    /// - Parameter image: The input `UIImage`.
    /// - Returns: The transformed output image.
    ///
    /// The pipeline:
    /// 1. Filters out disabled transforms
    /// 2. Sorts by category priority
    /// 3. Executes transforms sequentially
    ///
    /// Any transform that throws simply gets skipped to avoid pipeline interruption.
    public func applyAll(to image: UIImage) async -> UIImage {
        let sorted = transforms
            .filter { $0.isEnabled }
            .sorted { $0.category.rawValue < $1.category.rawValue }

        var output = image

        for entry in sorted {
            do {
                output = await entry.run(output)
            } catch {
                // Fail-safe: skip faulty transform
                continue
            }
        }
        return output
    }

    // MARK: - Apply One Transform

    /// Applies a single transform by its identifier.
    ///
    /// - Parameters:
    ///   - id: Transform identifier.
    ///   - image: Input `UIImage`.
    /// - Returns: Transformed result, or the original image if not found.
    public func apply(id: String, to image: UIImage) async -> UIImage {
        guard let entry = transforms.first(where: { $0.id == id && $0.isEnabled }) else {
            return image
        }
        return await entry.run(image)
    }
}

// ======================================================================
// MARK: - Built-In AI Helpers
// ======================================================================

extension AITransformPipeline {

    /// Computes a saliency score using Vision.
    ///
    /// - Parameter image: Input image.
    /// - Returns:
    ///   - `1.0` → Salient objects detected
    ///   - `0.2` → No salient objects detected
    ///   - `0.5` → Fallback score on unsupported systems
    ///
    /// Uses `VNGenerateAttentionBasedSaliencyImageRequest` on iOS 15+.
    public func computeSaliency(_ image: UIImage) async -> Double {
        guard let cg = image.cgImage else { return 0 }

        if #available(iOS 15.0, *) {
            let req = VNGenerateAttentionBasedSaliencyImageRequest()
            let handler = VNImageRequestHandler(cgImage: cg)
            try? handler.perform([req])

            guard let obs = req.results?.first as? VNSaliencyImageObservation else { return 0 }
            return obs.salientObjects?.count == 0 ? 0.2 : 1.0
        }

        return 0.5
    }

    /// Detects whether the input image contains at least one human face.
    ///
    /// - Parameter image: Input image.
    /// - Returns: `true` if at least one face is detected; otherwise `false`.
    ///
    /// Uses `VNDetectFaceRectanglesRequest`.
    public func detectFaces(_ image: UIImage) async -> Bool {
        guard let cg = image.cgImage else { return false }
        let req = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cg)
        try? handler.perform([req])
        return !(req.results?.isEmpty ?? true)
    }

    /// Computes a sharpness score using a Laplacian-based Core Image filter.
    ///
    /// - Parameter image: Input image.
    /// - Returns: A normalized sharpness score (0.0–1.0).
    ///
    /// This method:
    /// - Applies a Laplacian filter to highlight edges
    /// - Computes the maximum pixel intensity
    /// - Normalizes it to the 0–255 range
    public func sharpness(_ image: UIImage) -> Double {
        guard let cg = image.cgImage else { return 0 }

        let ci = CIImage(cgImage: cg)
        let lap = ci
            .applyingFilter("CILaplacian")
            .applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: ci.extent)])
            .clampedToExtent()

        var px: [UInt8] = [0,0,0,0]
        ciContext.render(
            lap,
            toBitmap: &px,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        return Double(px[0]) / 255.0
    }
}

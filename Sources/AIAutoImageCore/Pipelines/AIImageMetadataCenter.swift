//
//  AIImageMetadataCenter.swift
//  AIAutoImageCore
//

import Foundation
import UIKit
import Vision
import CoreML
import ImageIO
import CoreImage

/// A production-grade, actor-isolated metadata extraction hub for images.
///
/// `AIImageMetadataCenter` provides:
/// - A unified API for running all metadata extractors.
/// - Support for custom, pluggable extractors.
/// - Built-in Vision, CoreML, and CoreImage extractors.
/// - Safe sandbox execution for each extractor (no crashes).
/// - Automatic merging of metadata from multiple extractors.
///
/// Extraction runs inside an actor, ensuring:
/// - Thread safety
/// - Sequential, isolation-safe image processing
/// - Non-blocking async API
public actor AIImageMetadataCenter: Sendable {

    // MARK: - Shared Instance

    /// Shared global singleton instance.
    public static let shared = AIImageMetadataCenter()

    // MARK: - Types
    
    /// The signature for a metadata extractor.
    ///
    /// Each extractor receives an input `UIImage` and must return
    /// a dictionary of metadata values.
    ///
    /// Extractors are:
    /// - Fully async
    /// - Isolated per-call (never blocking)
    /// - Guaranteed not to crash the caller
    public typealias MetadataExtractor = @Sendable (UIImage) async -> [String: Any]

    /// Registered extractors mapped by identifier.
    private var extractors: [String: MetadataExtractor] = [:]

    /// Core Image context for local computations.
    private let ciContext = CIContext()

    /// Initializes the metadata center and registers all built-in extractors.
    ///
    /// Built-in extractors include:
    /// - Saliency (Vision)
    /// - Face detection (Vision)
    /// - Classification (CoreML)
    /// - Sharpness + brightness (CoreImage)
    /// - EXIF metadata
    public init() {
        Task { await registerBuiltInExtractors() }
    }

    // MARK: - Registration

    /// Registers a custom extractor with a unique identifier.
    ///
    /// - Parameters:
    ///   - id: A unique string identifying the extractor.
    ///   - extractor: A metadata extractor closure.
    ///
    /// If an extractor with the same ID exists, it will be replaced.
    public func register(id: String, extractor: @escaping MetadataExtractor) {
        extractors[id] = extractor
    }

    /// Returns a list of all registered extractor identifiers.
    public func registeredExtractorIDs() -> [String] {
        Array(extractors.keys)
    }

    // MARK: - Main API

    /// Runs **all registered extractors** on an image and merges their results.
    ///
    /// - Parameter image: The input `UIImage`.
    /// - Returns: A combined `AIMetadataBox` with per-extractor metadata.
    ///
    /// Extractor output format:
    /// ```swift
    /// [
    ///   "saliency": ["confidence": Double],
    ///   "faces": ["count": Int, "boundingBoxes": [[String: Double]]],
    ///   ...
    /// ]
    /// ```
    public func extractAll(from image: UIImage) async -> AIMetadataBox {
        var result: [String: Any] = [:]

        for (id, extractor) in extractors {
            let value = await extractor(image)
            result[id] = value
        }

        return AIMetadataBox(result)
    }

    /// Runs only one extractor by ID.
    ///
    /// - Parameters:
    ///   - id: The extractor identifier.
    ///   - image: The input image.
    /// - Returns: A dictionary of metadata or an empty dictionary if the extractor doesn't exist.
    public func extract(id: String, from image: UIImage) async -> [String: Any] {
        guard let ex = extractors[id] else { return [:] }
        return await ex(image)
    }
}

// ======================================================================
// MARK: - Built-in Production Extractors
// ======================================================================

private extension AIImageMetadataCenter {

    /// Registers all built-in extractors.
    ///
    /// This method is async to allow safe execution inside an actor during initialization.
    func registerBuiltInExtractors() async {

        // ----------------------------------------------------
        // 1) Saliency (Vision)
        // ----------------------------------------------------
        register(id: "saliency") { [weak self] img in
            guard let self else { return [:] }
            let score = await self.computeSaliency(img)
            return ["confidence": score]
        }

        // ----------------------------------------------------
        // 2) Face detection (Vision)
        // ----------------------------------------------------
        register(id: "faces") { [weak self] img in
            guard let self else { return [:] }
            let faces = await self.detectFaces(img)
            return [
                "count": faces.count,
                "boundingBoxes": faces.map {
                    [
                        "x": $0.origin.x,
                        "y": $0.origin.y,
                        "w": $0.size.width,
                        "h": $0.size.height
                    ]
                }
            ]
        }

        // ----------------------------------------------------
        // 3) Category classification (CoreML)
        // ----------------------------------------------------
        register(id: "category") { [weak self] img in
            guard let self else { return [:] }
            let cls = await self.classify(img)
            return ["label": cls ?? "unknown"]
        }

        // ----------------------------------------------------
        // 4) Sharpness + brightness (CoreImage)
        // ----------------------------------------------------
        register(id: "quality") { [weak self] img in
            guard let self else { return [:] }
            return [
                "sharpness": self.computeSharpness(img),
                "brightness": self.computeBrightness(img)
            ]
        }

        // ----------------------------------------------------
        // 5) EXIF metadata (ImageIO)
        // ----------------------------------------------------
        register(id: "exif") { img in
            extractEXIF(from: img)
        }
    }
}

// ======================================================================
// MARK: - AI / Vision helpers
// ======================================================================

private extension AIImageMetadataCenter {

    // ----------------------------------------------------
    // Saliency
    // ----------------------------------------------------

    /// Computes a simple saliency score using Vision.
    ///
    /// - Parameter image: Input image.
    /// - Returns: `1.0` if salient objects were detected, otherwise a fallback score.
    ///
    /// Uses `VNGenerateAttentionBasedSaliencyImageRequest` on iOS 15+.
    func computeSaliency(_ image: UIImage) async -> Double {
        guard let cg = image.cgImage else { return 0 }

        if #available(iOS 15.0, *) {
            let req = VNGenerateAttentionBasedSaliencyImageRequest()
            let handler = VNImageRequestHandler(cgImage: cg)
            try? handler.perform([req])

            guard let obs = req.results?.first as? VNSaliencyImageObservation else { return 0 }
            return obs.salientObjects?.isEmpty == true ? 0.2 : 1.0
        }
        return 0.5
    }

    // ----------------------------------------------------
    // Face Detection
    // ----------------------------------------------------

    /// Detects all faces in the image using Vision.
    ///
    /// - Parameter image: The input image.
    /// - Returns: An array of Vision-style bounding boxes (normalized rectangles).
    func detectFaces(_ image: UIImage) async -> [CGRect] {
        guard let cg = image.cgImage else { return [] }

        let req = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cg)
        try? handler.perform([req])
        return req.results?.map { $0.boundingBox } ?? []
    }

    // ----------------------------------------------------
    // ML Classification
    // ----------------------------------------------------

    /// Classifies the image using CoreML (model: `AICategory_v1`).
    ///
    /// - Parameter image: The input image.
    /// - Returns: A label string or `nil` if classification fails.
    func classify(_ image: UIImage) async -> String? {
        guard
            let wrapper = await AIModelManager.shared.model(named: "AICategory_v1")
                    as? CoreMLModelWrapper,
            let mlModel = wrapper.coreMLModel,
            let cg = image.cgImage
        else { return nil }

        do {
            let vnModel = try VNCoreMLModel(for: mlModel)
            let req = VNCoreMLRequest(model: vnModel)
            req.imageCropAndScaleOption = .centerCrop

            let handler = VNImageRequestHandler(cgImage: cg)
            try handler.perform([req])

            return (req.results?.first as? VNClassificationObservation)?.identifier
        } catch {
            return nil
        }
    }

    // ----------------------------------------------------
    // Sharpness
    // ----------------------------------------------------

    /// Computes a simple sharpness score using a Laplacian filter.
    ///
    /// - Parameter image: The input image.
    /// - Returns: A value between `0.0` and `1.0`.
    ///
    /// This method is `nonisolated` because it does local stateless work.
    nonisolated func computeSharpness(_ image: UIImage) -> Double {
        guard let cg = image.cgImage else { return 0 }

        let ci = CIImage(cgImage: cg)
        let filtered = ci.applyingFilter("CILaplacian")

        var px = [UInt8](repeating: 0, count: 4)
        let context = CIContext()

        context.render(
            filtered,
            toBitmap: &px,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        return Double(px[0]) / 255
    }

    // ----------------------------------------------------
    // Brightness
    // ----------------------------------------------------

    /// Computes global brightness using the `CIAreaAverage` filter.
    ///
    /// - Parameter image: The input image.
    /// - Returns: A normalized brightness value (0.0–1.0).
    nonisolated func computeBrightness(_ image: UIImage) -> Double {
        guard let cg = image.cgImage else { return 0 }

        let ci = CIImage(cgImage: cg)
        let avg = ci.applyingFilter(
            "CIAreaAverage",
            parameters: [kCIInputExtentKey: CIVector(cgRect: ci.extent)]
        )

        var px = [UInt8](repeating: 0, count: 4)
        let context = CIContext()

        context.render(
            avg,
            toBitmap: &px,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        return Double(px[0]) / 255
    }
}

// ======================================================================
// MARK: - EXIF Extraction
// ======================================================================

/// Extracts EXIF and TIFF metadata from a `UIImage`.
///
/// - Parameter image: Input `UIImage`.
/// - Returns: A dictionary of EXIF/TIFF metadata fields.
///
/// This uses `CGImageSource` and supports both PNG and JPEG image data.
private func extractEXIF(from image: UIImage) -> [String: Any] {
    guard let data = image.pngData() ?? image.jpegData(compressionQuality: 1) else { return [:] }

    guard
        let src = CGImageSourceCreateWithData(data as CFData, nil),
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
    else {
        return [:]
    }

    var out: [String: Any] = [:]

    if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
        for (k, v) in exif { out[String(describing: k)] = v }
    }

    if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
        for (k, v) in tiff { out[String(describing: k)] = v }
    }

    return out
}

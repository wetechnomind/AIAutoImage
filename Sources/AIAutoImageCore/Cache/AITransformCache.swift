//
//  AITransformCache.swift
//  AIAutoImageCore
//
//  High-performance transform cache with AI-aware eviction.
//
//  Purpose:
//   • Cache results of expensive image transformations
//   • Use Vision + CoreImage metadata for intelligent prioritization
//   • Evict entries using hybrid scoring: AI importance + LRU
//   • Reduce repeated computation of derived images (blur, crop, resize, filters)
//

import Foundation
import UIKit
import Vision
import CoreML
import CoreImage

/// A production-grade in-memory cache for storing transformed images.
///
/// This cache is specifically designed for:
///  - AI-enhanced image transformations
///  - Repeated operations (resize / blur / filters / effects)
///  - AI-prioritized eviction based on saliency + sharpness
///
/// Eviction uses a **hybrid scoring model**:
///  1. **AI Score** — Vision saliency + CI sharpness
///  2. **LRU** — Least-recently used timestamp
///
/// The cache is actor-isolated to ensure **thread safety** during concurrent transforms.
public actor AITransformCache: Sendable {

    // MARK: - Singleton
    // ---------------------------------------------------------------------

    /// Shared global instance for transformation caching.
    public static let shared = AITransformCache()


    // MARK: - Internal Storage
    // ---------------------------------------------------------------------

    /// NSCache-based memory store (fast eviction, cost-based).
    private let memory = NSCache<NSString, CacheEntry>()

    /// Last-access timestamps used for LRU scoring.
    private var accessLog: [String : Date] = [:]

    /// Reusable Vision saliency request.
    private lazy var saliencyRequest: VNGenerateAttentionBasedSaliencyImageRequest =
        VNGenerateAttentionBasedSaliencyImageRequest()

    /// Shared CIContext for sharpness evaluation.
    private let ciContext = CIContext()


    // MARK: - Cache Entry Structure
    // ---------------------------------------------------------------------

    /// Internal wrapper for cached images with AI metadata.
    private final class CacheEntry: NSObject {
        let image: UIImage
        let aiScore: Float
        let cost: Int

        init(image: UIImage, aiScore: Float, cost: Int) {
            self.image = image
            self.aiScore = aiScore
            self.cost = cost
        }
    }


    // MARK: - Initialization
    // ---------------------------------------------------------------------

    /// Initializes transform cache with a fraction of the main memory cache limit.
    private init() {
        memory.totalCostLimit = AIImageConfig.shared.memoryCacheTotalCost / 3
    }


    // MARK: - Public API
    // ---------------------------------------------------------------------

    /**
     Stores a transformed image in cache with AI scoring.

     AI scoring includes:
     - Vision saliency confidence
     - Laplacian-based sharpness score
     - Weighted combination → aiScore

     - Parameters:
       - image: The transformed UIImage.
       - key: Unique string identifying the transformation.
     */
    public func store(_ image: UIImage, forKey key: String) async {
        let cost = approximateCost(of: image)
        let aiScore = await computeAIValue(for: image)

        let entry = CacheEntry(image: image, aiScore: aiScore, cost: cost)
        memory.setObject(entry, forKey: key as NSString, cost: cost)

        accessLog[key] = Date()
    }

    /**
     Retrieves a previously stored transformed image if available.

     - Parameter key: Unique transform cache key.
     - Returns: The cached UIImage or nil.
     */
    public func retrieve(forKey key: String) -> UIImage? {
        guard let entry = memory.object(forKey: key as NSString) else { return nil }
        accessLog[key] = Date()   // update LRU access time
        return entry.image
    }

    /// Clears all entries from the transform cache.
    public func clear() {
        memory.removeAllObjects()
        accessLog.removeAll()
    }


    // MARK: - Cost Calculation
    // ---------------------------------------------------------------------

    /// Approximates memory cost (bytes) from CGImage dimensions.
    private func approximateCost(of image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 1 }
        return cg.bytesPerRow * cg.height
    }


    // MARK: - AI Scoring
    // ---------------------------------------------------------------------

    /**
     Computes AI importance score for a transformed image.

     Combination:
     ```
     aiScore = (saliency * 0.7) + (sharpness * 0.3)
     ```

     - Parameter image: Source image for AI evaluation.
     - Returns: Weighted AI score between 0–1.
     */
    private func computeAIValue(for image: UIImage) async -> Float {
        guard let cg = image.cgImage else { return 0.1 }

        let handler = VNImageRequestHandler(cgImage: cg, options: [:])

        var saliencyScore: Float = 0
        let sharpnessScore: Float = computeSharpness(of: image)

        do {
            try handler.perform([saliencyRequest])
            if let saliency = saliencyRequest.results?.first {
                saliencyScore = Float(saliency.confidence)
            }
        } catch {
            // fallback to sharpness-only scoring
            return sharpnessScore
        }

        return (saliencyScore * 0.7) + (sharpnessScore * 0.3)
    }


    // MARK: - Sharpness Evaluation (Laplacian)
    // ---------------------------------------------------------------------

    /**
     Computes sharpness score based on Laplacian edge magnitude.

     Steps:
     1. Apply CILaplacian
     2. Reduce to maximum area
     3. Crop to 1×1 pixel sample
     4. Normalize 0–1

     - Parameter image: Source image to evaluate.
     - Returns: Sharpness score in range 0–1.
     */
    private func computeSharpness(of image: UIImage) -> Float {
        guard let cg = image.cgImage else { return 0 }

        let ciImage = CIImage(cgImage: cg)

        guard let laplacian = ciImage
            .applyingFilter("CILaplacian")
            .applyingFilter(
                "CIAreaMaximum",
                parameters: [kCIInputExtentKey: CIVector(cgRect: ciImage.extent)]
            )
            .clampedToExtent()
            .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1)) as CIImage? else {
            return 0
        }

        var pixel: [UInt8] = [0, 0, 0, 0]

        ciContext.render(
            laplacian,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        return Float(pixel[0]) / 255.0
    }


    // MARK: - Cache Key Helper
    // ---------------------------------------------------------------------

    /**
     Generates a stable transform-cache key from:
     - original request key
     - transform identifier

     - Returns: `"requestKey::transform::transformId"`
     */
    public static func transformCacheKey(for requestKey: String, transformId: String) -> String {
        "\(requestKey)::transform::\(transformId)"
    }


    // MARK: - Trimming & Eviction
    // ---------------------------------------------------------------------

    /**
     Trims the transform cache to a maximum memory size using hybrid AI+LRU strategy.

     Removal priority:
       1. Low AI score (less important images)
       2. Oldest access (LRU)
       3. Largest images removed first until memory is below threshold

     - Parameter maxBytes: Maximum allowed memory usage for all transform entries.
     */
    public func trimTo(maxBytes: Int) {
        var total = 0
        var list: [(key: String, score: Double, size: Int)] = []

        // Build eviction list
        for (key, _) in accessLog {
            if let entry = memory.object(forKey: key as NSString) {
                let size = entry.cost
                total += size

                // Normalize age over ~72 hours
                let age = Date().timeIntervalSinceNow - (accessLog[key]?.timeIntervalSinceNow ?? 0)
                let ageNorm = min(max(abs(age) / (3600 * 24 * 3), 0), 1)

                // Higher removalScore = more disposable
                let removalScore = Double((1.0 - entry.aiScore)) * 0.6 + ageNorm * 0.4

                list.append((key, removalScore, size))
            }
        }

        guard total > maxBytes else { return }

        // Remove worst-scoring items first
        list.sort { $0.score > $1.score }

        for item in list {
            if total <= maxBytes { break }
            memory.removeObject(forKey: item.key as NSString)
            accessLog.removeValue(forKey: item.key)
            total -= item.size
        }
    }
}

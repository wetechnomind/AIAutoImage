//
//  AIPredictor.swift
//  AIAutoImage
//

import Foundation
import UIKit
@preconcurrency import Vision
import CoreML

// MARK: - Missing Enum Fix

/// A high-level strategy indicating how aggressively the system should
/// download or process images based on network conditions, device speed,
/// or UI scroll velocity.
///
/// `.fast`
/// → Prefer high speed, eager loading, aggressive prefetching.
///
/// `.balanced`
/// → Default mode; optimized for quality/speed balance.
///
/// `.lowData`
/// → Reduce network usage aggressively; small thumbnails, low-data requests.
public enum AINetworkStrategy: Sendable {
    case fast
    case balanced
    case lowData
}

// MARK: - Main Predictor

/// A production-grade prediction engine powering:
/// - Scroll velocity-based prefetching
/// - CDN host ranking and selection
/// - Network strategy prediction
/// - Image category prediction (URL/heuristics/CoreML/Vision)
/// - Intelligent prefetch scoring (ranking image importance)
///
/// `AIPredictor` works as a lightweight heuristics + ML hybrid layer.
///
/// It is safe to use across threads (`@unchecked Sendable`) and uses
/// lock-protected internal state to track recent scroll velocity,
/// observed CDN performance, and context usage history.
public final class AIPredictor: @unchecked Sendable {

    // MARK: - Internal State

    /// Sliding window of recent scroll velocities (for UI prefetch ranking).
    private var velocityHistory: [CGFloat] = []

    /// Runtime CDN performance history keyed by host.
    private var cdnHistory: [String: Double] = [:]

    /// Tracks frequency of request contexts (detail/gallery/prefetch/etc).
    private var contextHistory: [AIRequestContext: Int] = [
        .gallery: 0,
        .detail: 0,
        .prefetch: 0,
        .background: 0,
        .normal: 0,
        .thumbnail: 0,
        .listItem: 0
    ]

    /// Lock for thread-safe mutation of internal history arrays.
    private let lock = NSLock()

    /// Initialize predictor (no setup required).
    public init() {}

    // MARK: - SCROLL PREDICTION

    /// Predicts which image indexes are likely to become visible next,
    /// based on UI scroll velocity and direction.
    ///
    /// Used by:
    /// - Prefetchers
    /// - Lazy loaders
    /// - Adaptive quality selection
    ///
    /// - Parameters:
    ///   - currentOffset: Current scroll position (index or pixel offset).
    ///   - velocity: Current scroll velocity.
    ///   - count: Total number of items.
    ///   - windowSize: Base window size to prefetch.
    ///
    /// - Returns: A sorted list of predicted indexes to prefetch.
    public func predictNextVisibleIndexes(
        currentOffset: CGFloat,
        velocity: CGFloat,
        count: Int,
        windowSize: Int = 5
    ) -> [Int] {

        // Update velocity history
        lock.lock()
        velocityHistory.append(velocity)
        if velocityHistory.count > 5 { velocityHistory.removeFirst() }
        lock.unlock()

        let avgVelocity = velocityHistory.average

        // Determine direction of scroll
        let direction: CGFloat = velocity >= 0 ? 1 : -1

        // Predict jump amount based on normalized velocity
        let predictedJump = Int(
            (abs(avgVelocity) / 1200)
                .clamped(0.5, 6.0)
                * CGFloat(windowSize)
        )

        let startIdx = max(0, Int(currentOffset) + (direction > 0 ? 1 : -predictedJump))
        let endIdx = min(count - 1, startIdx + windowSize + predictedJump)

        return Array(startIdx...endIdx)
    }

    // MARK: - CDN Prediction

    /// Selects the best CDN host based on historical performance scoring.
    ///
    /// Faster hosts get higher scores over time.
    /// Used when an image has multiple CDN sources.
    ///
    /// - Parameter candidates: List of possible URLs.
    /// - Returns: Best-ranked CDN URL or nil if empty.
    public func bestCDN(for candidates: [URL]) -> URL? {
        guard !candidates.isEmpty else { return nil }

        lock.lock()
        defer { lock.unlock() }

        let ranked = candidates.sorted { lhs, rhs in
            let a = cdnHistory[lhs.host ?? ""] ?? 0
            let b = cdnHistory[rhs.host ?? ""] ?? 0
            return a > b
        }

        return ranked.first
    }

    /// Updates performance score for a given CDN host.
    ///
    /// - Parameters:
    ///   - host: CDN hostname.
    ///   - delta: Score adjustment (+/-).
    public func updateCDNScore(host: String, delta: Double) {
        lock.lock()
        cdnHistory[host, default: 0] += delta
        lock.unlock()
    }

    // MARK: - NETWORK STRATEGY

    /// Predicts network loading strategy based on recent scroll velocity.
    ///
    /// - parameter url: Optional URL (may aid future heuristics)
    /// - returns: A prioritized network strategy.
    public func predictNetworkStrategy(for url: URL?) -> AINetworkStrategy {

        lock.lock()
        let avgVelocity = velocityHistory.average
        lock.unlock()

        if avgVelocity > 1800 { return .fast }
        if avgVelocity < 200 { return .lowData }
        return .balanced
    }

    // MARK: - PREFETCH RANKING

    /// Computes a weighted score indicating how important it is to prefetch the image.
    ///
    /// This uses:
    /// - Image type (product/portrait/fashion/scene/etc)
    /// - Usage context (detail/gallery/list/thumbnail)
    /// - Transform count
    /// - Requested quality (high/medium/low/adaptive/lossless)
    ///
    /// - Parameter request: An `AIImageRequest` (KVC to support missing fields).
    /// - Returns: A score where higher means “prefetch sooner”.
    public func prefetchScore(for request: AIImageRequest) -> Double {
        var score: Double = 0

        // Safely use request metadata (if not present, defaults apply)
        let contentCategory: AIImageCategory =
            (request as AnyObject).value(forKey: "contentCategory") as? AIImageCategory
            ?? .unknown

        let usageContext: AIRequestContext =
            (request as AnyObject).value(forKey: "usageContext") as? AIRequestContext
            ?? .normal

        let quality: AIQuality =
            (request as AnyObject).value(forKey: "quality") as? AIQuality
            ?? .adaptive

        // Content category importance
        switch contentCategory {
        case .product: score += 2.2
        case .people: score += 2.0
        case .portrait: score += 1.8
        case .fashion: score += 1.6
        case .scene: score += 1.3
        default: break
        }

        // Context importance
        switch usageContext {
        case .detail: score += 2.5
        case .gallery: score += 1.2
        case .prefetch: score += 1.0
        case .listItem: score += 0.8
        case .thumbnail: score += 0.5
        default: break
        }

        // More transforms = more important
        score += Double(request.transformations.count) * 0.3

        // Requested quality
        switch quality {
        case .high: score += 1.0
        case .medium: score += 0.7
        case .adaptive: score += 0.5
        case .low: score += 0.2
        case .lossless: score += 1.2
        }

        return score
    }

    // MARK: - CATEGORY PREDICTION (URL heuristic)

    /// Predicts image category using simple URL heuristics.
    ///
    /// - Parameter url: Source URL.
    /// - Returns: Category guess (product/portrait/fashion/etc).
    public func predictCategory(for url: URL) -> AIImageCategory {
        let path = url.absoluteString.lowercased()

        if path.contains("product") { return .product }
        if path.contains("avatar")  { return .portrait }
        if path.contains("fashion") { return .fashion }
        if path.contains("food")    { return .food }
        if path.contains("art")     { return .art }

        return .unknown
    }

    // MARK: - CATEGORY PREDICTION (Vision / CoreML from UIImage)

    /// Predicts image category using ML if available, falling back to Vision API.
    ///
    /// Steps:
    /// 1. Attempt CoreML classification via Vision + `AICategory_v1`
    /// 2. Fallback to Vision’s `VNClassifyImageRequest`
    /// 3. Otherwise return `.unknown`
    ///
    /// - Parameter image: The input image.
    /// - Returns: Predicted `AIImageCategory`.
    public func predictCategory(for image: UIImage) async -> AIImageCategory {
        // 1) Try CoreML
        if let mlCategory = try? await predictCategoryWithCoreML(image),
           mlCategory != .unknown {
            return mlCategory
        }

        // 2) Vision fallback
        if let visionCategory = try? await predictCategoryWithVision(image),
           visionCategory != .unknown {
            return visionCategory
        }

        return .unknown
    }

    // MARK: - CoreML via Vision Helper

    /// Attempts to classify an image using the registered CoreML model "AICategory_v1".
    ///
    /// - Parameter image: Input `UIImage`.
    /// - Returns: Category or `.unknown`.
    private func predictCategoryWithCoreML(_ image: UIImage) async throws -> AIImageCategory {
        guard let cg = image.cgImage else { return .unknown }

        guard let model = await AIModelManager.shared.model(named: "AICategory_v1"),
              let wrapper = model as? CoreMLModelWrapper,
              let mlModel = wrapper.coreMLModel
        else { return .unknown }

        let vnModel = try VNCoreMLModel(for: mlModel)
        let request = VNCoreMLRequest(model: vnModel)
        request.imageCropAndScaleOption = .centerCrop

        return try await performVisionClassificationRequest(request, cgImage: cg)
    }

    // MARK: - Vision Fallback Helper

    /// Fallback classifier using Vision's `VNClassifyImageRequest`.
    ///
    /// - Parameter image: Input image.
    /// - Returns: Category guess.
    private func predictCategoryWithVision(_ image: UIImage) async throws -> AIImageCategory {
        guard let cg = image.cgImage else { return .unknown }

        if #available(iOS 13.0, *) {
            let req = VNClassifyImageRequest()
            return try await performVisionClassificationRequest(req, cgImage: cg)
        }

        return .unknown
    }

    // MARK: - Vision Classification Runner

    /// Executes a Vision request off the main thread and maps results into `AIImageCategory`.
    ///
    /// - Parameters:
    ///   - request: Vision request (CoreML or Vision-based).
    ///   - cgImage: Source image.
    /// - Returns: Highest-confidence mapped category.
    private func performVisionClassificationRequest(
        _ request: VNRequest,
        cgImage: CGImage
    ) async throws -> AIImageCategory {

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<AIImageCategory, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let handler = VNImageRequestHandler(cgImage: cgImage)

                do {
                    try handler.perform([request])

                    if let observations = request.results as? [VNClassificationObservation],
                       let top = observations.first {

                        let id = top.identifier.lowercased()

                        if id.contains("product") || id.contains("bottle") || id.contains("box") {
                            c.resume(returning: .product); return
                        }
                        if id.contains("person") || id.contains("face") || id.contains("portrait") {
                            c.resume(returning: .portrait); return
                        }
                        if id.contains("fashion") || id.contains("clothing") {
                            c.resume(returning: .fashion); return
                        }
                        if id.contains("food") || id.contains("dish") {
                            c.resume(returning: .food); return
                        }
                        if id.contains("art") || id.contains("painting") {
                            c.resume(returning: .art); return
                        }

                        c.resume(returning: .unknown)
                        return
                    }

                    c.resume(returning: .unknown)
                }
                catch {
                    c.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - Helpers

/// Average of CGFloat collection.
private extension Collection where Element == CGFloat {
    var average: CGFloat {
        guard !isEmpty else { return 0 }
        return reduce(0, +) / CGFloat(count)
    }
}

/// Clamps CGFloat into provided range.
private extension CGFloat {
    func clamped(_ min: CGFloat, _ max: CGFloat) -> CGFloat {
        Swift.max(min, Swift.min(self, max))
    }
}

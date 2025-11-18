//
//  AITransformCache.swift
//  AIAutoImageCore
//

import Foundation
import UIKit
import Vision
import CoreML
import CoreImage

// ===============================================================
// MARK: - MainActor Config Capture (SAFE)
// ===============================================================

public enum AITransformCacheConfigStore {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedMemoryLimit: Int = 30 * 1024 * 1024   // fallback 30MB

    /// SAFE WRITE (MainActor provides thread safety)
    @MainActor
    public static func updateFromConfig() {
        let newValue = AIImageConfig.shared.memoryCacheTotalCost
        lock.lock()
        storedMemoryLimit = newValue
        lock.unlock()
    }

    /// SAFE READ (nonisolated)
    public nonisolated static func memoryLimit() -> Int {
        lock.lock()
        let value = storedMemoryLimit
        lock.unlock()
        return value
    }
}

// ===============================================================
// MARK: - Transform Cache Actor
// ===============================================================

public actor AITransformCache: Sendable {

    // MARK: Singleton
    public static let shared = AITransformCache()

    // MARK: Internal Storage
    private let memory = NSCache<NSString, CacheEntry>()
    private var accessLog: [String : Date] = [:]
    private lazy var saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()
    private let ciContext = CIContext()

    // MARK: Cache Entry
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

    // MARK: Init (NO MainActor calls here)
    private init() {
        let limit = AITransformCacheConfigStore.memoryLimit()
        memory.totalCostLimit = limit / 3
    }

    // ===============================================================
    // MARK: - STORE
    // ===============================================================

    public func store(_ image: UIImage, forKey key: String) async {
        let cost = approximateCost(of: image)
        let aiScore = await computeAIValue(for: image)

        let entry = CacheEntry(image: image, aiScore: aiScore, cost: cost)
        memory.setObject(entry, forKey: key as NSString, cost: cost)
        accessLog[key] = Date()
    }

    // ===============================================================
    // MARK: - RETRIEVE
    // ===============================================================

    public func retrieve(forKey key: String) -> UIImage? {
        guard let entry = memory.object(forKey: key as NSString) else { return nil }
        accessLog[key] = Date()  // LRU update
        return entry.image
    }

    public func clear() {
        memory.removeAllObjects()
        accessLog.removeAll()
    }

    // ===============================================================
    // MARK: - Helpers
    // ===============================================================

    private func approximateCost(of image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 1 }
        return cg.bytesPerRow * cg.height
    }

    // ===============================================================
    // MARK: - AI SCORING
    // ===============================================================

    private func computeAIValue(for image: UIImage) async -> Float {
        guard let cg = image.cgImage else { return 0.1 }

        let handler = VNImageRequestHandler(cgImage: cg, options: [:])

        var saliencyScore: Float = 0
        let sharpnessScore: Float = computeSharpness(of: image)

        do {
            try handler.perform([saliencyRequest])
            if let obs = saliencyRequest.results?.first {
                saliencyScore = Float(obs.confidence)
            }
        } catch {
            return sharpnessScore
        }

        return (saliencyScore * 0.7) + (sharpnessScore * 0.3)
    }

    private func computeSharpness(of image: UIImage) -> Float {
        guard let cg = image.cgImage else { return 0 }
        let ciImage = CIImage(cgImage: cg)

        guard let lap = ciImage
            .applyingFilter("CILaplacian")
            .applyingFilter("CIAreaMaximum",
                parameters: [kCIInputExtentKey: CIVector(cgRect: ciImage.extent)]
            )
            .clampedToExtent()
            .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1)) as CIImage?
        else { return 0 }

        var pixel = [UInt8](repeating: 0, count: 4)

        ciContext.render(
            lap,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        return Float(pixel[0]) / 255.0
    }

    // ===============================================================
    // MARK: - Cache Key Helper
    // ===============================================================

    public static func transformCacheKey(for requestKey: String, transformId: String) -> String {
        "\(requestKey)::transform::\(transformId)"
    }

    // ===============================================================
    // MARK: - Eviction
    // ===============================================================

    public func trimTo(maxBytes: Int) {
        var total = 0
        var list: [(key: String, score: Double, size: Int)] = []

        for (key, _) in accessLog {
            if let entry = memory.object(forKey: key as NSString) {
                let size = entry.cost
                total += size

                let age = abs(Date().timeIntervalSince(accessLog[key] ?? Date()))
                let ageNorm = min(max(age / (3600 * 24 * 3), 0), 1)

                let score = Double(1.0 - entry.aiScore) * 0.6 + ageNorm * 0.4

                list.append((key, score, size))
            }
        }

        guard total > maxBytes else { return }

        list.sort { $0.score > $1.score }

        for item in list {
            if total <= maxBytes { break }
            memory.removeObject(forKey: item.key as NSString)
            accessLog.removeValue(forKey: item.key)
            total -= item.size
        }
    }
}

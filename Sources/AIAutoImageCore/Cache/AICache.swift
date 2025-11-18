//
//  AICache.swift
//  AIAutoImageCore
//
//  Unified AI-aware memory + disk caching system optimized for image pipelines.
//
//  Features:
//   • Actor-isolated cache (thread-safe by design)
//   • AI-prioritized eviction (sharpness + brightness scoring)
//   • Memory cost limiting via NSCache
//   • Automatic disk persistence (PNG/JPEG/HEIC)
//   • Disk manifest indexing for trimming and metadata
//   • SHA-256 key hashing for safe filenames
//

import Foundation
import UIKit
import CryptoKit
import AVFoundation
import ImageIO

/// Global, actor-isolated cache responsible for storing images in:
///   - Fast AI-prioritized memory cache
///   - Persistent on-disk cache
///
/// The cache performs AI-based eviction using:
///   - Sharpness score
///   - Brightness score
///   - Last access timestamp
///
/// The actor isolation ensures mutation safety across async tasks.
public actor AICache {

    // MARK: - Singleton
    // ---------------------------------------------------------------------

    /// Shared global cache instance.
    public static let shared = AICache()


    // MARK: - Memory Cache (AI-Prioritized)
    // ---------------------------------------------------------------------

    /// Internal NSCache entry storing image + AI metrics.
    private final class AIMemoryEntry: NSObject {
        let image: UIImage
        let cost: Int
        let aiScore: Float
        var lastAccess: Date

        init(image: UIImage, cost: Int, aiScore: Float) {
            self.image = image
            self.cost = cost
            self.aiScore = aiScore
            self.lastAccess = Date()
        }
    }

    /// Fast memory cache using NSCache with totalCostLimit.
    private let memory = NSCache<NSString, AIMemoryEntry>()

    /// File manager for disk I/O.
    private let fileManager = FileManager()

    /// Directory where cached images are stored.
    private let diskDirectory: URL

    /// Tracks which keys are in memory (NSCache does not expose keys).
    private var memoryKeys = Set<String>()

    /// Memory cost limit (in bytes).
    private var memoryCostLimit: Int { AIImageConfig.shared.memoryCacheTotalCost }

    /// Disk cache limit (in bytes).
    private var diskCostLimit: Int { AIImageConfig.shared.diskCacheLimit }


    // MARK: - Initialization
    // ---------------------------------------------------------------------

    /// Creates memory + disk caches and ensures the disk directory exists.
    private init() {
        memory.totalCostLimit = AIImageConfig.shared.memoryCacheTotalCost

        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("AIAutoImageCache", isDirectory: true)

        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        self.diskDirectory = dir
    }


    // MARK: - Memory Cache API
    // ---------------------------------------------------------------------

    /**
     Retrieves an image stored in the in-memory cache.

     - Parameter key: Unique cache key.
     - Returns: The UIImage if found, otherwise nil.
     */
    public func memoryImage(forKey key: String) -> UIImage? {
        if let entry = memory.object(forKey: key as NSString) {
            entry.lastAccess = Date()
            return entry.image
        }
        return nil
    }

    /**
     Stores a UIImage in memory with AI-aware prioritization.

     - Parameter image: The image to store.
     - Parameter key: Cache key.
     */
    public func storeInMemory(_ image: UIImage, forKey key: String) {
        let cost = approximateCost(of: image)
        let aiScore: Float = computeAIValue(for: image)

        let entry = AIMemoryEntry(image: image, cost: cost, aiScore: aiScore)
        memory.setObject(entry, forKey: key as NSString, cost: cost)

        memoryKeys.insert(key)

        Task { await trimMemoryIfNeeded() }
    }

    /// Removes an image from memory cache.
    public func removeFromMemory(forKey key: String) {
        memory.removeObject(forKey: key as NSString)
        memoryKeys.remove(key)
    }

    /// Clears all memory-cached images.
    public func clearMemory() {
        memory.removeAllObjects()
        memoryKeys.removeAll()
    }


    // MARK: - Memory Trimming
    // ---------------------------------------------------------------------

    /**
     Trims memory cache when exceeding cost limit.

     Eviction priority:
     1. Lowest AI score
     2. Oldest last access
     */
    private func trimMemoryIfNeeded() async {
        let current = currentMemoryCost()
        let limit = memoryCostLimit
        guard current > limit else { return }

        var entries: [(key: String, entry: AIMemoryEntry)] = []

        for key in allMemoryKeys() {
            if let e = memory.object(forKey: key as NSString) {
                entries.append((key, e))
            }
        }

        // Sort: worst AI score → oldest access first
        let sorted = entries.sorted {
            if $0.entry.aiScore == $1.entry.aiScore {
                return $0.entry.lastAccess < $1.entry.lastAccess
            }
            return $0.entry.aiScore < $1.entry.aiScore
        }

        var cost = current
        for item in sorted {
            if cost <= limit { break }
            memory.removeObject(forKey: item.key as NSString)
            memoryKeys.remove(item.key)
            cost -= item.entry.cost
        }
    }

    /// Returns total estimated memory cost.
    private func currentMemoryCost() -> Int {
        var total = 0
        for key in allMemoryKeys() {
            if let entry = memory.object(forKey: key as NSString) {
                total += entry.cost
            }
        }
        return total
    }

    /// All keys currently in memory cache.
    private func allMemoryKeys() -> [String] {
        Array(memoryKeys)
    }


    // MARK: - AI Scoring (Sharpness + Brightness)
    // ---------------------------------------------------------------------

    /**
     Computes a fast “AI score” for an image.

     Weighted formula:
     ```
     score = 0.65 * sharpness + 0.35 * brightness
     ```
     */
    private func computeAIValue(for image: UIImage) -> Float {
        let sharp = computeSharpness(image)
        let bright = computeBrightness(image)
        return 0.65 * sharp + 0.35 * bright
    }

    /// Fast Laplacian sharpness measurement.
    private func computeSharpness(_ image: UIImage) -> Float {
        guard let cg = image.cgImage else { return 0 }

        let ci = CIImage(cgImage: cg)
        let lap = ci.applyingFilter("CILaplacian")

        var px: [UInt8] = [0,0,0,0]
        let ctx = CIContext()

        ctx.render(
            lap,
            toBitmap: &px,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        return Float(px[0]) / 255.0
    }

    /// Fast CoreImage brightness measurement.
    private func computeBrightness(_ image: UIImage) -> Float {
        guard let cg = image.cgImage else { return 0 }

        let ci = CIImage(cgImage: cg)
        let avg = ci.applyingFilter(
            "CIAreaAverage",
            parameters: [kCIInputExtentKey: CIVector(cgRect: ci.extent)]
        )

        var px: [UInt8] = [0,0,0,0]
        let ctx = CIContext()

        ctx.render(
            avg,
            toBitmap: &px,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        return Float(px[0]) / 255.0
    }

    /// Estimates memory cost of a UIImage.
    private func approximateCost(of image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 1 }
        return cg.bytesPerRow * cg.height
    }


    // MARK: - Disk Cache API
    // ---------------------------------------------------------------------

    /**
     Retrieves an image from disk cache if available.

     - Parameter key: Cache key.
     - Returns: Decoded UIImage or nil.
     */
    public func diskImage(forKey key: String) -> UIImage? {
        let url = fileURL(for: key)

        guard let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else {
            return nil
        }

        Task { await AIDiskManifest.shared.updateAccessDate(for: key) }
        return image
    }

    /**
     Stores an image on disk using preferred encoding:
     - PNG
     - JPEG
     - HEIC
     - Auto (alpha → PNG, else JPEG)

     Automatically registers metadata in `AIDiskManifest`.

     - Parameters:
       - image: Image to store.
       - key: Cache key.
       - preferredFormat: Encoding format.
     */
    public func storeOnDisk(
        _ image: UIImage,
        forKey key: String,
        preferredFormat: AIImageFormat = .auto
    ) {
        let url = fileURL(for: key)

        guard let data = encoded(image, preferredFormat: preferredFormat) else { return }

        do { try data.write(to: url, options: [.atomic]) }
        catch { return }

        Task {
            await AIDiskManifest.shared.registerImage(
                key: key,
                fileName: url.lastPathComponent,
                size: data.count,
                image: image,
                variantTag: nil
            )
        }

        Task { await trimDiskIfNeeded(maxBytes: diskCostLimit) }
    }

    /// Encodes an image to PNG/JPEG/HEIC.
    private func encoded(_ image: UIImage, preferredFormat: AIImageFormat) -> Data? {
        guard let cg = image.cgImage else { return nil }

        let hasAlpha: Bool = {
            switch cg.alphaInfo {
            case .premultipliedLast, .premultipliedFirst, .last, .first: return true
            default: return false
            }
        }()

        switch preferredFormat {
        case .png: return image.pngData()
        case .jpeg: return image.jpegData(compressionQuality: 0.9)
        case .heic: return image.heicData(quality: 0.9)
        case .auto:
            return hasAlpha ? image.pngData()
                            : image.jpegData(compressionQuality: 0.9)
        default:
            return image.pngData()
        }
    }

    /// Removes a cached image from disk.
    public func removeFromDisk(forKey key: String) {
        let url = fileURL(for: key)
        try? fileManager.removeItem(at: url)
        Task { await AIDiskManifest.shared.remove(key: key) }
    }

    /// Clears entire disk cache folder + manifest.
    public func clearDisk() {
        guard let files = try? fileManager.contentsOfDirectory(at: diskDirectory,
                                                               includingPropertiesForKeys: nil)
        else { return }

        for url in files { try? fileManager.removeItem(at: url) }
        Task { await AIDiskManifest.shared.clear() }
    }


    // MARK: - Disk Trimming
    // ---------------------------------------------------------------------

    /**
     Trims disk cache until under maxBytes using manifest eviction rules:
     - Least-recently used
     - AI-value based (optional inside manifest)
     */
    private func trimDiskIfNeeded(maxBytes: Int) async {
        let removeList = await AIDiskManifest.shared.trimTo(maxBytes: maxBytes)

        for (_, entry) in removeList {
            let url = diskDirectory.appendingPathComponent(entry.fileName)
            try? fileManager.removeItem(at: url)
        }
    }


    // MARK: - Key Handling
    // ---------------------------------------------------------------------

    /// Computes disk filename for a cache key using SHA-256.
    private func fileURL(for key: String) -> URL {
        diskDirectory.appendingPathComponent(sha256(key))
    }

    private func sha256(_ key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }


    // MARK: - Compatibility Helpers
    // ---------------------------------------------------------------------

    /// Removes an image from both memory and disk.
    public func remove(forKey key: String) {
        memory.removeObject(forKey: key as NSString)
        memoryKeys.remove(key)

        let url = fileURL(for: key)
        try? fileManager.removeItem(at: url)

        Task { await AIDiskManifest.shared.remove(key: key) }
    }

    /// Clears memory + disk cache fully.
    public func clearAll() {
        memory.removeAllObjects()
        memoryKeys.removeAll()

        if let files = try? fileManager.contentsOfDirectory(at: diskDirectory,
                                                            includingPropertiesForKeys: nil) {
            for f in files { try? fileManager.removeItem(at: f) }
        }

        Task { await AIDiskManifest.shared.clear() }
    }
}


// MARK: - UIImage HEIC Encoding Helper
// ---------------------------------------------------------------------

fileprivate extension UIImage {

    /// Encodes an image as HEIC using CoreGraphics.
    func heicData(quality: CGFloat) -> Data? {
        guard let cg = self.cgImage else { return nil }

        let data = NSMutableData()
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary

        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData,
            AVFileType.heic as CFString,
            1,
            nil
        ) else { return nil }

        CGImageDestinationAddImage(dest, cg, options)
        guard CGImageDestinationFinalize(dest) else { return nil }

        return data as Data
    }
}

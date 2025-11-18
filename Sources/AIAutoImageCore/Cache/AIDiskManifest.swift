//
//  AIDiskManifest.swift
//  AIAutoImageCore
//
//  Disk metadata index for the AIAutoImage caching system.
//
//  Responsibilities:
//   • Maintain metadata for all disk-cached images
//   • Track access timestamps (LRU)
//   • Store AI-derived metadata (saliency, face presence, sharpness, category)
//   • Balance eviction decisions using AI importance + recency
//   • Persist manifest.json on disk asynchronously
//

import Foundation
import UIKit
import Vision
import CoreML

/// Persistent disk metadata manager for the AIAutoImage disk cache.
///
/// `AIDiskManifest` maintains a **manifest.json** file containing one entry
/// for each cached image:
///
///  - File metadata (size, filename, lastAccess)
///  - AI metadata (saliency, face detection, sharpness, category)
///  - Variant tags for transformed versions
///
/// The manifest is used to make intelligent decisions during disk trimming,
/// prioritizing the most important images using a hybrid scoring system.
public actor AIDiskManifest: Sendable {

    // MARK: - Singleton
    // ---------------------------------------------------------------------

    /// Global shared instance for the disk manifest.
    public static let shared = AIDiskManifest()


    // MARK: - Manifest Entry Structure
    // ---------------------------------------------------------------------

    /// Metadata entry stored for each image on disk.
    ///
    /// Includes size, filename, timestamps, and multiple AI signals.
    public struct Entry: Codable, Sendable {
        public let key: String
        public var fileName: String
        public var size: Int
        public var lastAccess: Date

        // AI Metadata
        public var saliency: Double          // 0–1 range
        public var hasFace: Bool             // Detected via Vision
        public var sharpness: Double         // CoreML / Laplacian score
        public var category: String?         // Vision classification label

        // User-defined variant tag (e.g. blurred, resized, cropped)
        public var variantTag: String?
    }


    // MARK: - Manifest Storage
    // ---------------------------------------------------------------------

    /// Location of manifest.json
    private var manifestURL: URL

    /// In-memory map of all entries by cache key.
    private var entries: [String: Entry] = [:]

    /// Encoders are created once to avoid overhead.
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()


    // MARK: - Initialization
    // ---------------------------------------------------------------------

    /// Initializes manifest location and asynchronously loads stored entries.
    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("AIAutoImageCache", isDirectory: true)

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        manifestURL = dir.appendingPathComponent("manifest.json")

        // Load manifest asynchronously within actor context
        Task { await load() }
    }


    // MARK: - Load / Save
    // ---------------------------------------------------------------------

    /// Loads manifest.json into memory.
    private func load() async {
        guard let data = try? Data(contentsOf: manifestURL) else { return }
        if let decoded = try? jsonDecoder.decode([String: Entry].self, from: data) {
            self.entries = decoded
        }
    }

    /// Saves manifest.json asynchronously without blocking the actor.
    private func saveAsync() {
        let snapshot = self.entries

        Task.detached(priority: .utility) { [manifestURL] in
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: manifestURL, options: .atomic)
        }
    }


    // MARK: - Public Manifest API
    // ---------------------------------------------------------------------

    /// Returns manifest entry for a given cache key.
    public func entry(for key: String) -> Entry? {
        entries[key]
    }

    /// Updates last access timestamp for LRU logic.
    public func updateAccessDate(for key: String) {
        guard var e = entries[key] else { return }
        e.lastAccess = Date()
        entries[key] = e
        saveAsync()
    }

    /// Removes entry from manifest.
    public func remove(key: String) {
        entries.removeValue(forKey: key)
        saveAsync()
    }

    /// Returns total size in bytes for all cached entries.
    public func totalSize() -> Int {
        entries.values.reduce(0) { $0 + $1.size }
    }

    /// Returns entries sorted from oldest → newest by last access.
    public func sortedByLRU() -> [Entry] {
        entries.values.sorted { $0.lastAccess < $1.lastAccess }
    }


    // MARK: - Register New Image with AI Metadata
    // ---------------------------------------------------------------------

    /**
     Registers a newly cached image and extracts AI metadata.

     This performs:
     - Vision saliency scoring
     - Vision face detection
     - Sharpness scoring via CoreML predictor
     - Vision scene classification
     - Writes entry into manifest

     - Parameters:
       - key: Cache key
       - fileName: Filename on disk
       - size: Compressed file size (bytes)
       - image: Original UIImage before encoding
       - variantTag: Optional descriptive tag (crop, blur, etc.)
     */
    public func registerImage(
        key: String,
        fileName: String,
        size: Int,
        image: UIImage,
        variantTag: String?
    ) async {

        let sal = await computeSaliency(image)
        let face = await detectFaces(image)
        let sharp = await AICacheQualityPredictor.shared.predictSharpness(for: image)
        let category = await classify(image)

        let entry = Entry(
            key: key,
            fileName: fileName,
            size: size,
            lastAccess: Date(),
            saliency: sal,
            hasFace: face,
            sharpness: sharp,
            category: category,
            variantTag: variantTag
        )

        entries[key] = entry
        saveAsync()
    }


    // MARK: - Disk Trimming (AI + LRU)
    // ---------------------------------------------------------------------

    /**
     Trims disk usage to meet a maximum byte budget.

     Eviction uses hybrid scoring:
       1. **AI importance**
          • Saliency
          • Face detection
          • Sharpness
       2. **Age (LRU)**
          Older files become more eligible for removal.

     - Parameter maxBytes: Maximum allowed disk usage.
     - Returns: List of `(key, entry)` pairs removed.
     */
    public func trimTo(maxBytes: Int) -> [(String, Entry)] {
        var removed: [(String, Entry)] = []
        var total = totalSize()

        guard total > maxBytes else { return removed }

        // Score entries for removal importance
        let scored = entries.values.map { entry -> (Entry, Double) in

            let faceFactor = entry.hasFace ? 1.0 : 0.5
            let saliencyFactor = entry.saliency
            let sharpFactor = entry.sharpness

            // Higher aiScore = more important → less likely to be removed
            let aiScore = (faceFactor * 0.4) + (saliencyFactor * 0.4) + (sharpFactor * 0.2)

            // Age weight, normalized 0–1 (older → closer to 1)
            let age = ageWeight(entry.lastAccess)

            // Higher removalScore = more likely to be removed
            let removalScore = (1.0 - aiScore) * 0.6 + age * 0.4

            return (entry, removalScore)
        }

        // Sort: highest removalScore first (lowest priority)
        let sorted = scored.sorted { $0.1 < $1.1 }

        for (entry, _) in sorted {
            if total <= maxBytes { break }

            entries.removeValue(forKey: entry.key)
            removed.append((entry.key, entry))
            total -= entry.size
        }

        saveAsync()
        return removed
    }

    /// Converts last-access time to a normalized 0–1 age score.
    private func ageWeight(_ date: Date) -> Double {
        let hours = abs(date.timeIntervalSinceNow) / 3600
        return min(hours / 72, 1.0)   // 72 hours → full weight
    }


    // MARK: - Direct Insert / Update Convenience APIs
    // ---------------------------------------------------------------------

    /// Inserts or updates an entry.
    public func addOrUpdate(_ entry: Entry) { entries[entry.key] = entry; saveAsync() }
    public func insert(_ entry: Entry) { entries[entry.key] = entry; saveAsync() }
    public func update(_ entry: Entry) { entries[entry.key] = entry; saveAsync() }
    public func record(_ entry: Entry) { entries[entry.key] = entry; saveAsync() }
    public func write(_ entry: Entry)  { entries[entry.key] = entry; saveAsync() }
    public func set(_ entry: Entry)    { entries[entry.key] = entry; saveAsync() }

    /// Clears entire manifest.
    public func clear() {
        entries.removeAll()
        saveAsync()
    }
}


// MARK: - Vision + AI Helpers
// ---------------------------------------------------------------------

extension AIDiskManifest {

    /**
     Computes Vision saliency score (0–1) using pixelBuffer averaging.

     - Parameter image: Source image.
     */
    private func computeSaliency(_ image: UIImage) async -> Double {
        guard let cg = image.cgImage else { return 0 }

        if #available(iOS 15.0, *) {
            let req = VNGenerateAttentionBasedSaliencyImageRequest()
            let handler = VNImageRequestHandler(cgImage: cg)
            try? handler.perform([req])

            guard let obs = req.results?.first as? VNSaliencyImageObservation else { return 0 }

            let buffer = obs.pixelBuffer

            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let stride = CVPixelBufferGetBytesPerRow(buffer)

            var sum = 0.0
            for y in 0..<height {
                let row = base + y * stride
                for x in 0..<width { sum += Double(row[x]) / 255.0 }
            }

            return sum / Double(width * height)
        }

        // Fallback when Vision saliency is not available
        return 0.5
    }

    /**
     Detects presence of faces using Vision.

     - Parameter image: Source image.
     - Returns: `true` if any faces were detected.
     */
    private func detectFaces(_ image: UIImage) async -> Bool {
        guard let cg = image.cgImage else { return false }

        let req = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cg)

        try? handler.perform([req])
        return !(req.results?.isEmpty ?? true)
    }

    /**
     Classifies image category using Vision's built-in classifier.

     - Parameter image: The image to classify.
     - Returns: The top identifier string or nil.
     */
    private func classify(_ image: UIImage) async -> String? {
        guard let cg = image.cgImage else { return nil }

        let req = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cg)

        try? handler.perform([req])
        return req.results?.first?.identifier
    }
}

//
//  AIPrefetcher.swift
//  AIAutoImageCore
//

import Foundation
import UIKit
import Network
import Vision
import CoreML

/// A production-grade, actor-isolated intelligent image prefetcher.
///
/// `AIPrefetcher` handles:
/// - AI-driven prioritization of images
/// - Saliency-aware thumbnail analysis
/// - URL and metadata heuristics
/// - Optional CoreML-based prioritization
/// - Adaptive concurrency based on network conditions
/// - Deduplication of requests
/// - Non-blocking async prefetch batches
///
/// Prefetching works by:
/// 1. Adding image requests to an internal queue
/// 2. Sorting them by an AI-based score
/// 3. Fetching only lightweight requests (headers or small chunks)
/// 4. Warming the system's cache before the actual image load
///
/// This dramatically improves scroll performance, especially in galleries.
public actor AIPrefetcher: Sendable {

    // MARK: - Singleton

    /// Shared singleton instance.
    public static let shared = AIPrefetcher()

    // MARK: - Queue

    /// The internal prefetch queue.
    private var queue: [AIImageRequest] = []

    /// Indicates whether a prefetch batch is actively running.
    private var isRunning = false

    /// AI-based score cache keyed by image URL.
    private var aiScoreCache: [URL: Float] = [:]

    // MARK: - Network Monitoring

    /// Monitors network conditions and determines adaptive concurrency.
    private let pathMonitor = NWPathMonitor()

    /// Serial queue used by `NWPathMonitor`.
    private let pathQueue = DispatchQueue(label: "AIAutoImageCore.prefetch.network")

    // MARK: - Concurrency

    /// Maximum parallel prefetch operations (adaptive).
    private var maxConcurrent: Int = 3

    // MARK: - Vision AI

    /// Optional Vision saliency request used to prioritize thumbnails.
    private lazy var saliencyReq = VNGenerateAttentionBasedSaliencyImageRequest()

    // MARK: - Optional ML Prioritizer

    /// Optional CoreML/AI-based prioritization function.
    ///
    /// Example use cases:
    /// - Personalized ranking
    /// - Recommendations
    /// - Business-specific priority rules
    public var mlPrioritizer: (@Sendable (AIImageRequest) async -> Float)?

    /// Private initializer — use shared.
    private init() {
        pathMonitor.start(queue: pathQueue)
    }

    // MARK: - Public API

    /// Adds a list of image requests to the prefetch queue.
    ///
    /// - Prefetch flow:
    ///   1. Append new requests
    ///   2. Deduplicate by URL
    ///   3. Convert back into `AIImageRequest` instances
    ///   4. Kick off async run loop
    ///
    /// - Parameter requests: List of `AIImageRequest` objects to prefetch.
    public func prefetch(_ requests: [AIImageRequest]) {

        // 1. Append incoming requests
        queue.append(contentsOf: requests)
        
        // 2. Deduplicate by URL
        let uniqueURLs = Array(Set(queue.map { $0.url }))
        queue = uniqueURLs.map { AIImageRequest(url: $0) }

        // 3. Start processing
        Task { await run() }
    }

    // ============================================================
    // MARK: - Cancel Helpers
    // ============================================================

    /// Cancels all pending prefetch requests.
    public func cancelAll() {
        queue.removeAll()
    }

    /// Cancels a single request by its URL.
    public func cancel(url: URL) {
        queue.removeAll { $0.url == url }
    }

    // MARK: - Main Loop

    /// Main execution loop for the prefetch pipeline.
    ///
    /// Runs batches until the queue is empty.
    /// Each batch:
    /// - Sorts queue by AI score
    /// - Adapts concurrency based on network state
    /// - Launches prefetch tasks concurrently
    private func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let session = URLSession.shared

        while !queue.isEmpty {

            // 1) AI-sort queue
            await sortQueueByAI()

            // 2) Adapt concurrency
            adjustConcurrency()

            // 3) Determine current batch
            let batch = Array(queue.prefix(maxConcurrent))
            queue.removeFirst(min(queue.count, maxConcurrent))

            // 4) Process batch in parallel
            await withTaskGroup(of: Void.self) { group in
                for req in batch {
                    group.addTask { [self] in
                        await prefetchOne(req, session: session)
                    }
                }
                await group.waitForAll()
            }
        }
    }

    // MARK: - Prefetch One

    /// Prefetches a single request by downloading a lightweight version
    /// of the resource (headers or minimal bytes).
    ///
    /// Prefetching does *not* decode or transform the image —
    /// it simply warms up:
    /// - CDN edge cache
    /// - URLSession memory/disk cache
    ///
    /// - Parameters:
    ///   - request: The request to prefetch.
    ///   - session: URL session used for network calls.
    private func prefetchOne(_ request: AIImageRequest, session: URLSession) async {
        let req = request
        let urlReq = req.makeURLRequest()

        do {
            let (_, _) = try await session.data(for: urlReq)
            // The actual data is discarded — cache is warmed.
        } catch {
            // Prefetch failures are non-critical.
        }
    }

    // MARK: - AI Sorting

    /// Sorts the prefetch queue by AI-computed priority score (descending).
    private func sortQueueByAI() async {
        var scored: [(AIImageRequest, Float)] = []

        for req in queue {
            let score = await aiScore(for: req)
            scored.append((req, score))
        }

        scored.sort { $0.1 > $1.1 }
        queue = scored.map { $0.0 }
    }

    // MARK: - AI Score (0…1)

    /// Computes an AI score representing how important it is to prefetch the image.
    ///
    /// Components:
    /// - ML prioritizer (optional)
    /// - URL heuristics
    /// - Size/type hints
    /// - Vision saliency for thumbnails
    ///
    /// Results are cached per URL.
    ///
    /// - Parameter request: The image request.
    /// - Returns: Score clamped to `0…1`.
    private func aiScore(for request: AIImageRequest) async -> Float {

        // Cache hit
        if let cached = aiScoreCache[request.url] {
            return cached
        }

        var score: Float = 0.0

        // 1. ML prioritizer (optional)
        if let ml = mlPrioritizer {
            score = max(score, await ml(request))
        }

        // 2. URL heuristics
        score = max(score, request.priority, urlPriority(request.url))

        // 3. Target size / type heuristic
        score = max(score, sizeHintPriority(request))

        // 4. Vision saliency (if thumbnail provided)
        if let thumb = request.thumbnailImage {
            let saliency = await saliencyPriority(image: thumb)
            score = max(score, saliency)
        }

        // Clamp 0…1 and cache
        score = min(max(score, 0), 1)
        aiScoreCache[request.url] = score
        return score
    }

    // MARK: - URL Heuristics

    /// Heuristic score based on the structure and semantic meaning of the URL.
    ///
    /// Examples:
    /// - profile/avatar → high score
    /// - thumbnails → medium score
    /// - AVIF/WebP assets → high score
    ///
    /// - Parameter url: URL to evaluate.
    /// - Returns: A float in the range `0…1`.
    private func urlPriority(_ url: URL) -> Float {
        let path = url.absoluteString.lowercased()

        if path.contains("profile")   { return 0.85 }
        if path.contains("avatar")    { return 0.75 }
        if path.contains("thumbnail") { return 0.7  }
        if path.contains("full")      { return 0.5  }

        if path.hasSuffix(".avif") || path.hasSuffix(".webp") {
            return 0.9
        }

        return 0.4
    }

    // MARK: - Size/Quality Hints

    /// Assigns priority based on pixel width (proxy for visual importance).
    ///
    /// - Parameter req: The request.
    /// - Returns: Score hint.
    private func sizeHintPriority(_ req: AIImageRequest) -> Float {
        let w = req.targetPixelSize?.width ?? 0
        return w > 500 ? 0.8 : 0.4
    }

    // MARK: - Vision Priority

    /// Computes saliency-based priority from a thumbnail image.
    ///
    /// Uses Vision’s `VNGenerateAttentionBasedSaliencyImageRequest` to detect
    /// whether the image has a strong focal region.
    ///
    /// - Parameter image: A small preview image.
    /// - Returns: A saliency confidence score, or a fallback of `0.1`.
    private func saliencyPriority(image: UIImage?) async -> Float {
        guard let cg = image?.cgImage else { return 0.1 }

        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do {
            try handler.perform([saliencyReq])
            return Float(saliencyReq.results?.first?.confidence ?? 0.1)
        } catch {
            return 0.1
        }
    }

    // MARK: - Adaptive Concurrency

    /// Adjusts the number of parallel prefetch tasks based on current network conditions.
    ///
    /// Behaviors:
    /// - No network → concurrency = 1
    /// - Expensive network (cellular/hotspot) → concurrency = 2
    /// - Good Wi-Fi / Ethernet → concurrency = 4
    ///
    /// This helps avoid saturation of mobile data and improves responsiveness.
    private func adjustConcurrency() {
        let path = pathMonitor.currentPath

        // No network
        if path.status != .satisfied {
            maxConcurrent = 1
            return
        }

        // Metered network
        if path.isExpensive {
            maxConcurrent = 2
            return
        }

        // Strong Wi-Fi / Ethernet
        maxConcurrent = 4
    }
}

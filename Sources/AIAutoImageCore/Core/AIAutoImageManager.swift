//
//  AIAutoImageManager.swift
//  AIAutoImageCore
//
//  High-level load coordinator for AIAutoImage.
//
//  Responsibilities:
//   • Handles deduplication of pipeline tasks
//   • Manages memory/disk caching logic
//   • Applies final images to UIImageView safely on MainActor
//   • Unified load API for UIImageView and async workflows
//

import Foundation
import UIKit

// MARK: - Safe wrapper for UIImageView
// ----------------------------------------------------------------------

/// A lightweight `Sendable` wrapper for `UIImageView`.
///
/// Because UIKit views are not thread-safe nor `Sendable`, this wrapper
/// allows image views to be referenced safely inside actors without
/// violating concurrency rules.
///
/// The wrapped `UIImageView` is held weakly to prevent retain cycles.
public struct AIImageViewBox: Sendable {
    public weak var view: UIImageView?
    public init(_ v: UIImageView?) { self.view = v }
}


// MARK: - Shared Pipeline
// ----------------------------------------------------------------------

/// Convenience shared reference to the main pipeline.
extension AIImagePipeline {
    public static let shared = AIImagePipeline()
}


// MARK: - Manager Actor
// ----------------------------------------------------------------------

/// Primary coordinator for image loading, caching, and UI delivery.
///
/// `AIAutoImageManager` is responsible for:
/// - Task deduplication (avoid duplicate loads for same key)
/// - Memory + disk cache lookup
/// - Running the full AI image pipeline when needed
/// - Delivering results to the correct UIImageView
/// - Applying accessibility descriptions
/// - Emitting analytics / telemetry events
///
/// This actor ensures all load operations are:
/// - Thread-safe
/// - Cancelable
/// - Efficient under high concurrency
public actor AIAutoImageManager {

    // MARK: Singleton

    /// Shared global instance.
    public static let shared = AIAutoImageManager()

    private let pipeline = AIImagePipeline.shared
    private let cache = AICache.shared

    /// MainActor reference to analytics.
    @MainActor private var analytics: AIAnalytics {
        AIAnalytics.shared
    }

    /// Deduplication map: cacheKey → active load task.
    private var tasks: [String: Task<UIImage, Error>] = [:]

    private init() {}


    // MARK: - PUBLIC LOAD API
    // ------------------------------------------------------------------

    /**
     Loads an image using the full AIAutoImage pipeline and optionally
     applies the result to a provided `UIImageView`.

     Features:
      • Memory cache lookup
      • Disk cache lookup
      • Full AI processing pipeline
      • Task deduplication
      • UI-safe updates
      • Progress callbacks

     - Parameters:
       - request: A complete `AIImageRequest`.
       - imageView: Optional wrapper for the target UIImageView.
       - progress: Optional progress callback reporting pipeline stage + fraction.
     - Returns: A `Task` resolving to the final processed `UIImage`.
     */
    @discardableResult
    public func load(
        _ request: AIImageRequest,
        into imageView: AIImageViewBox? = nil,
        progress: ((AIImagePipelineStage, Double) -> Void)? = nil
    ) -> Task<UIImage, Error> {

        let key = request.effectiveCacheKey

        // ---------------------------------------------------------
        // 1) TASK DEDUPLICATION
        // ---------------------------------------------------------
        if let existing = tasks[key] {
            attachImageViewUpdate(to: existing, imageView: imageView)
            return existing
        }

        // ---------------------------------------------------------
        // 2) CREATE NEW TASK
        // ---------------------------------------------------------
        let task = Task<UIImage, Error> {

            // Memory Cache
            if !request.bypassMemoryCache,
               let mem = await cache.memoryImage(forKey: key) {

                await analytics.recordCacheLevelHit(level: "memory")
                await applyImage(mem, to: imageView?.view)
                return mem
            }

            // Disk Cache
            if !request.bypassDiskCache,
               let disk = await cache.diskImage(forKey: key) {

                await analytics.recordCacheLevelHit(level: "disk")
                await cache.storeInMemory(disk, forKey: key)

                await applyImage(disk, to: imageView?.view)
                return disk
            }

            // Full Pipeline
            try Task.checkCancellation()

            let finalImage = try await pipeline.process(
                request,
                sourceURL: request.url,
                progress: progress
            )

            // Cache result
            if !request.bypassMemoryCache {
                await cache.storeInMemory(finalImage, forKey: key)
            }

            if !request.bypassDiskCache {
                await cache.storeOnDisk(finalImage, forKey: key, preferredFormat: request.preferredFormat)
            }

            await applyImage(finalImage, to: imageView?.view)
            return finalImage
        }

        tasks[key] = task

        // ---------------------------------------------------------
        // 3) CLEANUP WHEN FINISHED
        // ---------------------------------------------------------
        Task.detached { [weak self] in
            guard let self else { return }
            _ = try? await task.value
            await self.removeTask(forKey: key)
        }

        return task
    }


    // MARK: - CANCEL OPERATIONS
    // ------------------------------------------------------------------

    /// Cancels an in-flight load for a specific URL.
    public func cancel(url: URL) {
        let key = AIImageRequest(url: url).effectiveCacheKey
        tasks[key]?.cancel()
        tasks[key] = nil
    }

    /// Cancels all active loads.
    public func cancelAll() {
        for (_, t) in tasks { t.cancel() }
        tasks.removeAll()
    }


    // MARK: - CACHE MANAGEMENT
    // ------------------------------------------------------------------

    /// Removes a specific URL from both memory and disk cache.
    public func removeFromCache(for url: URL) {
        let key = AIImageRequest(url: url).effectiveCacheKey
        Task { await cache.remove(forKey: key) }
    }

    /// Clears all memory + disk caches.
    public func clearAllCaches() {
        Task { await cache.clearAll() }
    }


    // MARK: - PRIVATE HELPERS
    // ------------------------------------------------------------------

    /// Removes completed or canceled tasks from the dedupe dictionary.
    private func removeTask(forKey key: String) {
        tasks[key] = nil
    }

    /**
     Attaches UI update behavior to an existing task.

     If the task finishes successfully, the resulting image is applied to the
     supplied UIImageView (if still alive).
     */
    private func attachImageViewUpdate(
        to task: Task<UIImage, Error>,
        imageView: AIImageViewBox?
    ) {
        Task {
            if let img = try? await task.value {
                await applyImage(img, to: imageView?.view)
            }
        }
    }
}


// MARK: - MAIN-ACTOR UI APPLIER
// ----------------------------------------------------------------------

/// Applies an image to a UIImageView on the main thread.
///
/// Features:
///  - Optional fade animation when debug logs enabled
///  - Automatically injects accessibility labels when enabled
@MainActor
private func applyImage(_ image: UIImage, to imageView: UIImageView?) async {
    guard let iv = imageView else { return }

    if AIImageConfig.shared.enableDebugLogs {
        UIView.transition(
            with: iv,
            duration: 0.25,
            options: .transitionCrossDissolve,
            animations: { iv.image = image },
            completion: nil
        )
    } else {
        iv.image = image
    }

    if AIImageConfig.shared.enableAIAccessibility {
        AIAccessibility.shared.applyToImageView(iv, image: image)
    }
}

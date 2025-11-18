//
//  AIThread.swift
//  AIAutoImageCore
//
//  Centralized threading utilities for the entire AIAutoImage pipeline.
//  Provides optimized GCD queues and async helpers that align with
//  decoding, rendering, CoreML, Vision, and caching operations.
//

import Foundation

// MARK: - Global Queues (Production-Safe Defaults)

/// High-level collection of optimized GCD queues used across the AIAutoImage system.
///
/// These queues ensure:
/// - **Zero CPU starvation**
/// - **Non-blocking UI**
/// - **Dedicated parallelism for ML, decoding, rendering, and I/O**
/// - **Consistent QoS across the entire pipeline**
///
/// Each queue is:
/// - Named (visible in Instruments)
/// - Concurrent where useful
/// - Configured with the appropriate QoS for that stage
///
/// Queues:
/// - `network`   → networking / prefetch
/// - `decode`    → image format decoding (JPEG/PNG/WebP/HEIC/AVIF)
/// - `transform` → CoreML + Vision transforms
/// - `render`    → CoreGraphics/CIImage rendering
/// - `cache`     → Disk I/O for caches
public enum AIQueues {

    // MARK: Network

    /// Networking queue responsible for downloads and prefetches.
    ///
    /// QoS: `.userInitiated`
    /// Attributes: `.concurrent`
    /// Ensures fast async loads while preventing UI blocking.
    public static let network: DispatchQueue = {
        DispatchQueue(
            label: "com.aiautoimage.network",
            qos: DispatchQoS(qosClass: .userInitiated, relativePriority: 0),
            attributes: .concurrent
        )
    }()

    // MARK: Decode

    /// Decode queue for PNG/JPEG/WebP/HEIC decoding.
    ///
    /// Performs CPU-bound decode tasks in parallel.
    public static let decode: DispatchQueue = {
        DispatchQueue(
            label: "com.aiautoimage.decode",
            qos: DispatchQoS(qosClass: .userInitiated, relativePriority: 0),
            attributes: .concurrent
        )
    }()

    // MARK: Transform

    /// Transform queue for CoreML and Vision tasks.
    ///
    /// Heavy AI tasks such as:
    /// - Super-resolution
    /// - Background removal
    /// - Style transfer
    /// - Person segmentation
    ///
    /// are safely isolated here.
    public static let transform: DispatchQueue = {
        DispatchQueue(
            label: "com.aiautoimage.transform",
            qos: DispatchQoS(qosClass: .userInitiated, relativePriority: 0),
            attributes: .concurrent
        )
    }()

    // MARK: Render

    /// Render queue for CoreGraphics/CIImage operations:
    /// - Cropping
    /// - Resizing
    /// - Compositing
    /// - Tone mapping
    ///
    /// QoS `.utility` makes it background-friendly without harming interactivity.
    public static let render: DispatchQueue = {
        DispatchQueue(
            label: "com.aiautoimage.render",
            qos: DispatchQoS(qosClass: .utility, relativePriority: 0),
            attributes: .concurrent
        )
    }()

    // MARK: Cache

    /// Disk-cache queue for local I/O operations.
    ///
    /// Serial queue ensures safe and deterministic file writes.
    public static let cache: DispatchQueue = {
        DispatchQueue(
            label: "com.aiautoimage.cache",
            qos: DispatchQoS(qosClass: .utility, relativePriority: 0)
        )
    }()

    // MARK: Queue Type Enum

    /// Identifies the logical queue category.
    ///
    /// Useful when allowing plugins or dynamic scheduling systems
    /// to choose a queue at runtime.
    public enum QueueType {
        case network
        case decode
        case transform
        case render
    }

    // MARK: Queue Reconfiguration

    /// Allows future dynamic queue tuning based on `AIPerformanceMode`.
    ///
    /// Note:
    /// DispatchQueue QoS cannot be changed after creation.
    /// If dynamic QoS is needed, replace queues here at runtime.
    ///
    /// - Parameter mode: The performance mode to configure for.
    public static func reconfigureQueues(for mode: AIPerformanceMode) {
        // Placeholder for future dynamic queue swapping.
        _ = mode
    }
}

// MARK: - Load Priority (TaskPriority Wrapper)

/// Internal load priority used for mapping network/transform requests
/// to Swift concurrency `TaskPriority` values.
///
/// Unlike `AILoadPriority` in TransformTypes.swift,
/// this avoids symbol conflicts when used inside AIThread.
public enum AILoadPriorityLevel: Sendable {

    /// Background priority (prefetching, caching)
    case low

    /// Standard priority (gallery, list)
    case normal

    /// Highest priority (detail screens, hero images)
    case high

    /// Converts priority into `TaskPriority`.
    public var taskPriority: TaskPriority {
        switch self {
        case .low:
            return .low
        case .normal:
            return .medium
        case .high:
            return .high
        }
    }
}

// MARK: - Global Async Helpers

/// Lightweight async helpers for running work on the correct queue.
///
/// Example:
/// ```swift
/// AIThread.decode {
///     let decoded = try? decodeWebP(data)
///     AIThread.main { completion(decoded) }
/// }
/// ```
public enum AIThread {

    /// Executes a block on the networking queue.
    ///
    /// - Parameter block: Work to execute asynchronously.
    public static func network(_ block: @escaping @Sendable () -> Void) {
        AIQueues.network.async(execute: block)
    }

    /// Executes decoding work on the decode queue.
    public static func decode(_ block: @escaping @Sendable () -> Void) {
        AIQueues.decode.async(execute: block)
    }

    /// Executes CoreML/Vision transforms on the transform queue.
    public static func transform(_ block: @escaping @Sendable () -> Void) {
        AIQueues.transform.async(execute: block)
    }

    /// Executes CoreGraphics/CoreImage rendering work.
    public static func render(_ block: @escaping @Sendable () -> Void) {
        AIQueues.render.async(execute: block)
    }

    /// Executes disk-based cache operations.
    public static func cache(_ block: @escaping @Sendable () -> Void) {
        AIQueues.cache.async(execute: block)
    }

    /// Runs a block on the main actor.
    ///
    /// - Parameter block: UI completion or main-thread-only work.
    @MainActor
    public static func main(_ block: @escaping @Sendable () -> Void) {
        block()
    }
}

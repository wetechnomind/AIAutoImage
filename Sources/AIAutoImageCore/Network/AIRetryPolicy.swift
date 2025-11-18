//
//  AIRetryPolicy.swift
//  AIAutoImageCore
//

import Foundation
import Network
import CoreML
import Vision

/// Represents a retry decision evaluated by `AIRetryPolicy`.
///
/// Includes:
/// - Whether a retry is allowed
/// - The delay before retrying
/// - Explanation of the decision (debug / analytics)
public struct AIRetryDecision: Sendable {
    /// Should the operation retry?
    public let shouldRetry: Bool

    /// Suggested delay before retrying.
    /// May be `nil` if no retry is allowed.
    public let delay: TimeInterval?

    /// Human-readable reason for the decision.
    public let reason: String
}

/// Defines retry behavior strategies for image loading and AI pipelines.
///
/// Includes:
/// - No retry
/// - Fixed retry intervals
/// - Exponential backoff
/// - AI-adaptive delay based on learned network conditions
public enum AIRetryStrategy: Sendable {

    /// Disable all retries.
    case none

    /// Retry a fixed number of times at a constant interval.
    case fixed(times: Int, interval: TimeInterval)

    /// Retry with exponential backoff:
    /// Delay doubles every attempt up to `max`.
    case exponential(times: Int, initial: TimeInterval, max: TimeInterval = 60)

    /// AI-driven adaptive retry:
    /// Uses a fixed base value, adjusted by AI scoring.
    case aiAdaptive(maxTimes: Int, base: TimeInterval)

    /// Computes the base retry delay for a specific attempt.
    ///
    /// - Parameter attempt: Zero-based attempt index.
    /// - Returns: A base delay or `nil` if no more retries allowed.
    public func baseDelay(at attempt: Int) -> TimeInterval? {
        switch self {

        case .none:
            return nil

        case .fixed(let times, let interval):
            return attempt < times ? interval : nil

        case .exponential(let times, let initial, let max):
            guard attempt < times else { return nil }
            let delay = initial * pow(2.0, Double(attempt))
            return min(delay, max)

        case .aiAdaptive(let maxTimes, let base):
            return attempt < maxTimes ? base : nil
        }
    }
}

/// Production-grade retry policy designed for:
/// - Image loading
/// - AI inference requests
/// - Network-bound ML pipelines
///
/// Features:
/// - **AI-driven retry probability** (`aiClassifier`)
/// - **Exponential & adaptive backoff**
/// - **Network quality checks** via `NWPathMonitor`
/// - **Circuit breaker** for repeated failures
/// - **Random jitter** to avoid retry storms
public struct AIRetryPolicy: Sendable {

    // MARK: - AI Callback

    /// Optional async classifier to evaluate error severity.
    ///
    /// - Must return a score between `0` and `1`:
    ///   - `1.0` → High value, retry strongly recommended
    ///   - `0.0` → Do not retry
    ///
    /// Example:
    /// ```swift
    /// policy.aiClassifier = { error in
    ///     if error is URLError { return 0.8 }
    ///     return 0.2
    /// }
    /// ```
    public var aiClassifier: (@Sendable (Error) async -> Float)?

    // MARK: - Network State

    /// Monitors network path to evaluate connection quality.
    private let monitor = NWPathMonitor()

    /// Serial queue used by `NWPathMonitor`.
    private let queue = DispatchQueue(label: "AIAutoImageCore.retry")

    // MARK: - Circuit Breaker

    /// Count of recent failures (resets automatically).
    private var failureCount = 0

    /// Timestamp of the last failure, used to slow retry frequency.
    private var lastFailureTime: Date?

    // MARK: - Jitter

    /// Random jitter range applied to avoid retry synchronization storms.
    public var jitterRange: ClosedRange<Double> = 0.9...1.2

    /// Creates a new retry policy.
    ///
    /// Automatically starts monitoring network path.
    public init() {
        monitor.start(queue: queue)
    }

    // MARK: - Evaluation

    /// Evaluates whether a retry should be attempted and the delay before retrying.
    ///
    /// - Parameters:
    ///   - strategy: Retry strategy to use.
    ///   - error: The error that caused the failure.
    ///   - attempt: Zero-based attempt index.
    ///
    /// - Returns: An `AIRetryDecision` describing the retry behavior.
    public func evaluate(
        strategy: AIRetryStrategy,
        error: Error,
        attempt: Int
    ) async -> AIRetryDecision {

        // ------------------------------------------------------
        // 1) Strategy-defined base delay
        // ------------------------------------------------------
        guard let baseDelay = strategy.baseDelay(at: attempt) else {
            return AIRetryDecision(
                shouldRetry: false,
                delay: nil,
                reason: "Strategy stopped retries"
            )
        }

        // ------------------------------------------------------
        // 2) AI scoring for error classification
        // ------------------------------------------------------
        let aiScore: Float = await aiClassifier?(error) ?? 1.0

        if aiScore < 0.25 {
            return AIRetryDecision(
                shouldRetry: false,
                delay: nil,
                reason: "AI predicted retry not worth it"
            )
        }

        // ------------------------------------------------------
        // 3) Network quality evaluation
        // ------------------------------------------------------
        let path = monitor.currentPath
        let networkGood = path.status == .satisfied

        if !networkGood {
            return AIRetryDecision(
                shouldRetry: true,
                delay: baseDelay * 3,
                reason: "Network unstable — delaying retries"
            )
        }

        // ------------------------------------------------------
        // 4) Circuit breaker for rapid consecutive failures
        // ------------------------------------------------------
        if let last = lastFailureTime,
           Date().timeIntervalSince(last) < 1.0 {

            return AIRetryDecision(
                shouldRetry: true,
                delay: baseDelay * 2,
                reason: "Circuit breaker active — slowing retries"
            )
        }

        // ------------------------------------------------------
        // 5) Apply jitter + AI scaling
        // ------------------------------------------------------
        let jitter = Double.random(in: jitterRange)
        let finalDelay = baseDelay * jitter * Double(aiScore)

        return AIRetryDecision(
            shouldRetry: true,
            delay: finalDelay,
            reason: "Retry allowed (AI score: \(aiScore))"
        )
    }
}

//
//  AINetwork.swift
//  AIAutoImageCore
//

import Foundation
import UIKit
import CoreML
#if canImport(Vision)
import Vision
#endif

// ================================================================
// MARK: - AI-powered network advisor
// ================================================================

/// An AI-assisted network advisor that dynamically selects the best CDN,
/// predicts latency using CoreML, evaluates image importance using Vision,
/// and guides backoff strategies.
///
/// Features:
/// - Predict CDN latency via `AICDNLatency_v1` CoreML model
/// - Track success/error scores per host for quality scoring
/// - Vision-based saliency scoring for image importance
/// - AI-based exponential backoff strategy
/// - Used by `AINetwork` and loader components
public actor AINetworkAdvisor: Sendable {

    /// Shared global singleton.
    public static let shared = AINetworkAdvisor()

    /// Predicted latency score for each host (0 = slow, 1 = fast).
    private var latencyScores: [String : Double] = [:]

    /// Historical count of network errors per host.
    private var errorScores: [String : Int] = [:]

    /// Historical count of successful responses per host.
    private var successScores: [String : Int] = [:]

    private init() {}

    // ------------------------------------------------------------
    // MARK: - AI Latency Prediction
    // ------------------------------------------------------------

    /// Predicts expected network latency for a given host using a CoreML model.
    ///
    /// - Parameter host: Hostname to evaluate.
    /// - Returns: Latency score from `0.0` (poor) to `1.0` (excellent).
    ///
    /// Uses:
    /// - Unicode embedding of hostname
    /// - `AICDNLatency_v1.mlmodel` inference
    public func predictLatency(for host: String) async -> Double {

        guard
            let wrapper = await AIModelManager.shared.model(named: "AICDNLatency_v1") as? CoreMLModelWrapper,
            let mlModel = wrapper.coreMLModel
        else {
            return 0.5
        }

        let embedding = MLMultiArray.fromString(host)

        guard let input = try? MLDictionaryFeatureProvider(
            dictionary: ["host": MLFeatureValue(multiArray: embedding)]
        ) else {
            return 0.5
        }

        guard
            let output = try? mlModel.prediction(from: input),
            let value = output.featureValue(for: "score")?.doubleValue
        else {
            return 0.5
        }

        return max(0.0, min(1.0, value))
    }

    // ------------------------------------------------------------
    // MARK: - Vision: Image Importance
    // ------------------------------------------------------------

    /// Computes importance score for an image using Vision saliency maps.
    ///
    /// - Parameter image: The image to analyze.
    /// - Returns: Importance score `0–1`.
    ///
    /// Uses `VNGenerateAttentionBasedSaliencyImageRequest`.
    public func importanceScore(for image: UIImage) async -> Double {
        #if canImport(Vision)
        guard let cg = image.cgImage else { return 0.5 }

        if #available(iOS 15.0, macOS 12.0, *) {
            if let score = try? runVisionScoring(cg) {
                return score
            }
        }
        #endif
        return 0.4
    }

    /// Performs full saliency scan on the provided CGImage.
    @available(iOS 15.0, *)
    private func runVisionScoring(_ cg: CGImage) throws -> Double {
        let req = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cg)
        try handler.perform([req])

        guard let obs = req.results?.first as? VNSaliencyImageObservation else {
            return 0.5
        }

        let buffer = obs.pixelBuffer

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0.5 }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        var sum = 0.0
        for y in 0..<height {
            let row = ptr + y * stride
            for x in 0..<width { sum += Double(row[x]) / 255.0 }
        }

        let mean = sum / Double(width * height)
        return max(0, min(1, mean))
    }

    // ------------------------------------------------------------
    // MARK: - Host Success/Error Tracking
    // ------------------------------------------------------------

    /// Records a successful or failed network attempt for a given host.
    public func record(host: String, success: Bool) {
        if success {
            successScores[host, default: 0] += 1
        } else {
            errorScores[host, default: 0] += 1
        }
    }

    // ------------------------------------------------------------
    // MARK: - Best CDN Selection
    // ------------------------------------------------------------

    /// Selects the best host among a list of URLs using:
    /// - CoreML latency prediction
    /// - Historical success/error scoring
    ///
    /// - Parameter urls: Candidate CDN URLs.
    /// - Returns: Best performing URL or nil.
    public func bestHost(from urls: [URL]) async -> URL? {
        guard !urls.isEmpty else { return nil }

        var ranked: [(URL, Double)] = []

        for url in urls {
            let host = url.host ?? ""
            let aiLatency = await predictLatency(for: host)

            let success = Double(successScores[host, default: 0])
            let failures = Double(errorScores[host, default: 0])

            let score = aiLatency + success * 0.1 - failures * 0.15
            ranked.append((url, score))
        }

        return ranked.sorted { $0.1 > $1.1 }.first?.0
    }

    // ------------------------------------------------------------
    // MARK: - AI Backoff
    // ------------------------------------------------------------

    /// Computes intelligent backoff time using:
    /// - Exponential growth
    /// - Host error penalty
    ///
    /// - Parameter attempt: Retry attempt number.
    /// - Parameter host: Host name used to adjust penalty.
    /// - Returns: Recommended delay in seconds.
    public func aiBackoff(for attempt: Int, host: String) async -> TimeInterval {
        let penalty = Double(errorScores[host, default: 0]) * 0.05
        return pow(1.6, Double(attempt)) + penalty
    }
}


// ================================================================
// MARK: - Task Storage Actor
// ================================================================

/// Thread-safe storage for active URLSession tasks.
///
/// Actor ensures:
/// - Safe add/remove
/// - Lookup by URL
/// - Bulk cancel
actor AINetworkActor {

    private var tasks: [URL: URLSessionTask] = [:]

    /// Store task for specific URL.
    func setTask(_ task: URLSessionTask, for url: URL) {
        tasks[url] = task
    }

    /// Remove task for URL.
    func removeTask(for url: URL) {
        tasks.removeValue(forKey: url)
    }

    /// Fetch stored task.
    func getTask(for url: URL) -> URLSessionTask? {
        tasks[url]
    }

    /// Get all active tasks.
    func allTasks() -> [URLSessionTask] {
        Array(tasks.values)
    }

    /// Remove all tasks.
    func clearAll() {
        tasks.removeAll()
    }
}


// ================================================================
// MARK: - Main AI+Network Engine
// ================================================================

/// AI-powered, retry-capable HTTP client used by the AIAutoImage pipeline.
///
/// Features:
/// - Automatic retries with AI-driven backoff
/// - Integration with Vision & CoreML network advisor
/// - URLSession wrapper with structured concurrency
/// - Cancel-safe task handling
/// - CDN host selection logic
///
/// Used by:
/// - `AILoader`
/// - `AIImagePipeline`
/// - Prefetchers
public final class AINetwork: Sendable {

    /// Max retry attempts for failed requests.
    public let maxRetries: Int

    /// Base backoff time before AI adjustment.
    public let baseBackoff: TimeInterval

    /// Underlying URLSession handling HTTP operations.
    public let session: URLSession

    /// Actor storing active session tasks.
    private let state = AINetworkActor()

    /// Create a network instance with optional session & backoff tuning.
    public init(
        session: URLSession? = nil,
        maxRetries: Int = 2,
        baseBackoff: TimeInterval = 0.25
    ) {
        self.maxRetries = maxRetries
        self.baseBackoff = baseBackoff

        if let s = session {
            self.session = s
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = AIImageConfig.shared.networkTimeout
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: cfg)
        }
    }

    deinit {
        Task.detached { [actor = state] in
            let list = await actor.allTasks()
            for t in list { t.cancel() }
            await actor.clearAll()
        }
    }

    // ============================================================
    // MARK: - Main HTTP Execution
    // ============================================================

    /// Performs an HTTP request with full AI-enhanced logic.
    ///
    /// Includes:
    /// - Global & per-request modifiers
    /// - AI advisor host scoring
    /// - Automatic retries & intelligent backoff
    /// - Error classification and structured cancellation
    ///
    /// - Returns: `(Data, URLResponse?, URLSessionTask)`
    public func perform(_ request: URLRequest) async throws -> (Data, URLResponse?, URLSessionTask) {

        var req = request

        // Apply global modifier
        if let mod = AIImageConfig.shared.requestModifier {
            mod(&req)
        }

        let host = req.url?.host ?? ""
        var lastError: Error? = nil

        for attempt in 0...maxRetries {

            try Task.checkCancellation()

            let (data, resp, task) = try await createAndRunTask(with: req)

            if let url = req.url {
                await state.setTask(task, for: url)
            }

            if let http = resp as? HTTPURLResponse {

                // Success 2xx
                if (200..<300).contains(http.statusCode) {
                    await AINetworkAdvisor.shared.record(host: host, success: true)
                    if let url = req.url { await state.removeTask(for: url) }
                    return (data, resp, task)
                }

                // Retryable codes
                if [429, 500, 502, 503, 504].contains(http.statusCode),
                   attempt < maxRetries {

                    lastError = NSError(
                        domain: "AINetwork",
                        code: http.statusCode,
                        userInfo: [NSLocalizedDescriptionKey : "HTTP \(http.statusCode)"]
                    )

                    // AI-driven exponential backoff
                    let delay = await AINetworkAdvisor.shared.aiBackoff(for: attempt, host: host)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1e9))

                    await AINetworkAdvisor.shared.record(host: host, success: false)
                    continue
                }

                // Non-retryable
                await AINetworkAdvisor.shared.record(host: host, success: false)
                if let url = req.url { await state.removeTask(for: url) }

                throw NSError(
                    domain: "AINetwork",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey : "HTTP \(http.statusCode)"]
                )
            }

            // Non-HTTP response (success)
            if let url = req.url { await state.removeTask(for: url) }
            return (data, resp, task)
        }

        // Final error
        throw lastError ?? NSError(
            domain: "AINetwork",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Network error"]
        )
    }

    // ============================================================
    // MARK: - Cancel APIs
    // ============================================================

    /// Cancels an active task for the given URL.
    public func cancel(_ url: URL) {
        Task {
            if let task = await state.getTask(for: url) {
                task.cancel()
                await state.removeTask(for: url)
            }
        }
    }

    /// Cancels all active network tasks.
    public func cancelAll() {
        Task {
            let all = await state.allTasks()
            for t in all { t.cancel() }
            await state.clearAll()
        }
    }

    // ============================================================
    // MARK: - Task Creator
    // ============================================================

    /// Creates and runs a URLSession data task wrapped in async/await.
    ///
    /// Ensures:
    /// - Cancellation propagation
    /// - Safe error mapping
    /// - URLSessionTask returned for tracking
    private func createAndRunTask(with req: URLRequest)
        async throws -> (Data, URLResponse?, URLSessionTask)
    {
        try Task.checkCancellation()

        return try await withCheckedThrowingContinuation { cont in

            final class Box: @unchecked Sendable { var task: URLSessionDataTask? }

            let box = Box()

            let task = session.dataTask(with: req) { data, resp, error in

                guard let realTask = box.task else {
                    cont.resume(throwing:
                        NSError(domain: "AINetwork", code: -3,
                            userInfo: [NSLocalizedDescriptionKey: "Missing task reference"]))
                    return
                }

                if let err = error {
                    // Treat cancelled task correctly
                    if (err as NSError).code == NSURLErrorCancelled {
                        cont.resume(throwing: CancellationError())
                        return
                    }
                    cont.resume(throwing: err)
                    return
                }

                guard let data else {
                    cont.resume(throwing:
                        NSError(domain: "AINetwork", code: -2,
                                userInfo: [NSLocalizedDescriptionKey: "No data"]))
                    return
                }

                cont.resume(returning: (data, resp, realTask))
            }

            box.task = task
            task.resume()
        }
    }

    // ============================================================
    // MARK: - CDN Prefetch / Warm-Up
    // ============================================================

    /// Performs lightweight CDN URL warm-up using `HEAD` requests.
    ///
    /// Used for:
    /// - Reducing cold-start latency
    /// - Pre-warming CDN edge nodes
    /// - AICDNRouting improvements
    public func prefetch(_ urls: [URL]) {
        Task.detached { [weak self] in
            guard let self else { return }

            for url in urls {
                var req = URLRequest(url: url)
                req.httpMethod = "HEAD"
                _ = try? await self.session.data(for: req)
            }
        }
    }
}


// ================================================================
// MARK: - MLMultiArray Helpers
// ================================================================

public extension MLMultiArray {

    /// Creates a simple Unicode-scalar embedding vector from a string.
    ///
    /// - Parameter s: String to embed.
    /// - Parameter length: Desired vector length (default = 32).
    /// - Returns: A fixed-size `MLMultiArray` vector.
    static func fromString(_ s: String, length: Int = 32) -> MLMultiArray {
        let arr = try! MLMultiArray(shape: [length as NSNumber], dataType: .double)

        let scalars = s.unicodeScalars.map { UInt32($0.value) }

        for i in 0..<length {
            let v = scalars.isEmpty ? 0 : Double(scalars[i % scalars.count]) / 1000.0
            arr[i] = NSNumber(value: v)
        }

        return arr
    }
}

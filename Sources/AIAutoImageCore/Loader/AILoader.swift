//
//  AILoader.swift
//  AIAutoImageCore
//

import Foundation
import UIKit
#if canImport(Vision)
import Vision
#endif
import CoreML

/// A high-performance, actor-isolated network loader designed for AI-enhanced
/// image streaming and advanced fetch behaviors.
///
/// `AILoader` supports:
/// - Normal image fetches
/// - Progressive downloads (streaming JPEG/WebP/AVIF)
/// - Automatic CDN switching using AI latency prediction
/// - Vision-based saliency extraction
/// - CoreML-based category prediction
/// - Retry logic via `AIRetryPolicy`
/// - Cancellation of individual or all active tasks
///
/// This loader is a foundational component of:
/// - `AIImagePipeline`
/// - `AIProgressiveDecoder`
/// - `AIAutoImageManager`
public actor AILoader {

    // ============================================================
    // MARK: - State
    // ============================================================

    /// Active URLSessionTasks keyed by URL for cancellation and tracking.
    private var tasks: [URL: URLSessionTask] = [:]

    /// Creates a new loader instance.
    public init() {}


    // ============================================================
    // MARK: - PUBLIC: NORMAL FETCH (NON-PROGRESSIVE)
    // ============================================================

    /// Fetches a full image via HTTP/S without progressive streaming.
    ///
    /// - Parameters:
    ///   - request: The finalized URLRequest for the image.
    ///   - network: Abstraction layer for URLSession networking.
    ///   - config: Global configuration determining pipeline features.
    ///
    /// - Returns: The fully downloaded `Data` for the image.
    ///
    /// Behavior:
    /// 1. AI-based CDN routing (optional)
    /// 2. If progressive mode is active → internally forwards to `fetchStream`
    /// 3. Normal network fetch
    /// 4. Runs async Vision saliency + CoreML category prediction (non-blocking)
    public func fetch(
        request: URLRequest,
        network: AINetwork,
        config: AIImageConfig
    ) async throws -> Data {

        try Task.checkCancellation()

        // Optional: CDN rewrite
        let finalRequest = await rewriteRequestIfBetterCDN(request)

        // Auto-escalate to streaming if progressive is enabled
        if config.enableProgressiveLoading ||
            (request.value(forHTTPHeaderField: "X-AI-Progressive") == "1")
        {
            return try await fetchStream(request: finalRequest) { _, _ in }
        }

        // Normal network fetch
        let (data, _) = try await performNetwork(finalRequest, network: network)

        // Trigger async enrichment
        _ = await computeVisionSaliencyIfImage(data)
        _ = await predictCategoryIfImage(data)

        return data
    }


    // ============================================================
    // MARK: - PROGRESSIVE FETCH (STREAMING JPEG / WEBP / AVIF)
    // ============================================================

    /// Streams image bytes progressively (progressive JPEG, WebP, AVIF, etc.)
    ///
    /// - Parameters:
    ///   - request: URLRequest for the image.
    ///   - progress: Closure called on each partial chunk:
    ///       - partial data so far
    ///       - `isFinal` flag when stream ends
    ///
    /// - Returns: The final fully-accumulated `Data`.
    ///
    /// Streaming Behavior:
    /// - Uses `AsyncThrowingStream` to surface incoming network chunks.
    /// - Each chunk forwarded to caller on the main thread (safe for UI updates).
    /// - Emits final callback after the stream completes.
    /// - Suitable for progressive decoding via `AIProgressiveDecoder`.
    public func fetchStream(
        request: URLRequest,
        progress: @Sendable @escaping (Data, Bool) -> Void
    ) async throws -> Data {

        guard let url = request.url else {
            throw loaderError("Missing URL")
        }

        var accumulated = Data()

        // Async stream of incoming bytes
        let stream = AsyncThrowingStream<Data, Error> { continuation in

            // MARK: - Delegate for streaming network callbacks
            final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {

                let continuation: AsyncThrowingStream<Data, Error>.Continuation

                init(_ c: AsyncThrowingStream<Data, Error>.Continuation) {
                    self.continuation = c
                }

                /// Called when new bytes arrive.
                func urlSession(
                    _ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data
                ) {
                    continuation.yield(data)
                }

                /// Called when streaming ends.
                func urlSession(
                    _ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?
                ) {
                    if let e = error {
                        continuation.finish(throwing: e)
                    } else {
                        continuation.finish()
                    }
                }
            }

            // Build a streaming URLSession
            let delegate = Delegate(continuation)
            let session = URLSession(
                configuration: .default,
                delegate: delegate,
                delegateQueue: nil
            )

            let task = session.dataTask(with: request)

            Task { await self.storeTask(task, url: url) }

            task.resume()

            // Handle cancellation
            continuation.onTermination = { @Sendable _ in
                task.cancel()
                continuation.finish(throwing: CancellationError())
            }
        }

        // MARK: - Consume Streaming Bytes
        for try await chunk in stream {
            try Task.checkCancellation()
            accumulated.append(chunk)

            let snapshot = accumulated

            // deliver to main thread
            Task { @MainActor in
                progress(snapshot, false)
            }
        }

        // Final callback
        Task { @MainActor in
            progress(accumulated, true)
        }

        await removeTask(url)

        // AI metadata extraction (async, non-blocking)
        _ = await computeVisionSaliencyIfImage(accumulated)
        _ = await predictCategoryIfImage(accumulated)

        return accumulated
    }


    /// Stores a URLSessionTask so the loader can cancel or track it.
    private func storeTask(_ task: URLSessionTask, url: URL) async {
        tasks[url] = task
    }

    /// Removes the completed/cancelled task from the loader.
    private func removeTask(_ url: URL) async {
        tasks[url] = nil
    }


    // ============================================================
    // MARK: - INTERNAL: NORMAL NETWORK CALL
    // ============================================================

    /// Performs a standard network request using `AINetwork` abstraction.
    ///
    /// - Returns: `(Data, URLResponse?)`
    private func performNetwork(
        _ request: URLRequest,
        network: AINetwork
    ) async throws -> (Data, URLResponse?) {

        guard let url = request.url else {
            throw loaderError("Missing URL in request")
        }

        let (data, response, task) = try await network.perform(request)

        tasks[url] = task
        try validate(response: response, data: data)
        tasks[url] = nil

        return (data, response)
    }


    // ============================================================
    // MARK: - AI CDN REWRITE
    // ============================================================

    /// Optionally rewrites the URL using smart CDN routing.
    ///
    /// - Logic:
    ///   - Predict latency using CoreML
    ///   - If `provider.bestAlternative()` exceeds threshold → switch CDN
    private func rewriteRequestIfBetterCDN(_ req: URLRequest) async -> URLRequest {

        guard let url = req.url,
              let host = url.host else { return req }

        let latency = await predictLatency(for: host)

        if latency < 0.35,
           let provider = AIImageConfig.shared.cdnProvider,
           let better = await provider.bestAlternative(for: url)
        {
            var modified = req
            modified.url = better
            return modified
        }

        return req
    }

    /// Predicts network latency score (0–1) using CoreML.
    ///
    /// - Lower score = better CDN candidate.
    private func predictLatency(for host: String) async -> Double {

        guard let wrapper = await AIModelManager.shared.model(named: "AICDNLatency_v1")
                as? CoreMLModelWrapper,
              let ml = wrapper.coreMLModel else { return 0.5 }

        // Convert host string to multi-array embedding
        let vector = (try? MLMultiArray(host.unicodeScalars.map { Double($0.value) })) ??
            (try! MLMultiArray([Double](repeating: 0.1, count: 8)))

        let provider = try? MLDictionaryFeatureProvider(
            dictionary: ["host": MLFeatureValue(multiArray: vector)]
        )

        guard let prediction = try? ml.prediction(from: provider!),
              let score = prediction.featureValue(for: "score")?.doubleValue else {
            return 0.5
        }

        return max(0, min(1, score))
    }


    // ============================================================
    // MARK: - Vision Saliency (Optional)
    // ============================================================

    /// Computes Vision saliency score if the data is an image.
    ///
    /// - Returns: A saliency score (0–1).
    private func computeVisionSaliencyIfImage(_ data: Data) async -> Double {
        guard let ui = UIImage(data: data),
              let cg = ui.cgImage else { return 0.3 }

        #if canImport(Vision)
        if #available(iOS 15.0, *) {
            return (try? runVisionAttention(cg)) ?? 0.3
        }
        #endif

        return 0.3
    }

    /// Vision saliency implementation for iOS 15+.
    @available(iOS 15.0, *)
    private func runVisionAttention(_ cg: CGImage) throws -> Double {

        let req = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cg)

        try handler.perform([req])

        guard let obs = req.results?.first as? VNSaliencyImageObservation else { return 0.3 }

        let buffer = obs.pixelBuffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0.3 }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        var sum = 0.0

        for y in 0..<height {
            let row = ptr + y * stride
            for x in 0..<width {
                sum += Double(row[x]) / 255.0
            }
        }

        return min(1, max(0, sum / Double(width * height)))
    }


    // ============================================================
    // MARK: - CoreML: Category Prediction
    // ============================================================

    /// Uses CoreML category classifier to predict the image class.
    private func predictCategoryIfImage(_ data: Data) async -> String? {
        guard let ui = UIImage(data: data),
              let cg = ui.cgImage else { return nil }

        guard let wrapper = await AIModelManager.shared.model(named: "AICategory_v1")
                as? CoreMLModelWrapper,
              let ml = wrapper.coreMLModel else { return nil }

        let vnModel = try? VNCoreMLModel(for: ml)
        let request = VNCoreMLRequest(model: vnModel!)
        let handler = VNImageRequestHandler(cgImage: cg)

        try? handler.perform([request])
        return (request.results?.first as? VNClassificationObservation)?.identifier
    }


    // ============================================================
    // MARK: - HTTP VALIDATION
    // ============================================================

    /// Validates HTTP response codes (200–299 allowed).
    private func validate(response: URLResponse?, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }

        if (200..<300).contains(http.statusCode) { return }

        throw loaderError("HTTP error \(http.statusCode)")
    }

    /// Builds a simple NSError for loader issues.
    private func loaderError(_ msg: String) -> Error {
        NSError(domain: "AILoader", code: -1, userInfo: [
            NSLocalizedDescriptionKey: msg
        ])
    }


    // ============================================================
    // MARK: - RETRY WRAPPER
    // ============================================================

    /// Wrapper that performs automatic AI-adaptive retry logic.
    ///
    /// - Parameters:
    ///   - request: Original URLRequest.
    ///   - network: Network handler.
    ///   - retry: Retry policy provider.
    ///
    /// - Returns: Successfully downloaded `Data`.
    public func fetchWithRetry(
        _ request: URLRequest,
        network: AINetwork,
        retry: AIRetryPolicy
    ) async throws -> Data {

        var attempt = 0

        while true {
            do {
                return try await fetch(
                    request: request,
                    network: network,
                    config: AIImageConfig.shared
                )
            } catch {
                let decision = await retry.evaluate(
                    strategy: .aiAdaptive(maxTimes: 2, base: 0.3),
                    error: error,
                    attempt: attempt
                )

                if !decision.shouldRetry { throw error }

                if let delay = decision.delay {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1e9))
                }

                attempt += 1
            }
        }
    }


    // ============================================================
    // MARK: - CANCELLATION
    // ============================================================

    /// Cancels an active task for a specific URL.
    public func cancel(_ url: URL) {
        tasks[url]?.cancel()
        tasks[url] = nil
    }

    /// Cancels all active ongoing fetches.
    public func cancelAll() {
        for (_, t) in tasks { t.cancel() }
        tasks.removeAll()
    }
}

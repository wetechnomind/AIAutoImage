//
//  AIAnalytics.swift
//  AIAutoImageCore
//
//  Provides AI-driven telemetry for the AIAutoImage ecosystem.
//  Features include:
//
//   • Vision-based saliency scoring
//   • CoreML category prediction
//   • Model-load / latency tracking
//   • Cache hit metrics
//   • Pipeline transformation analytics
//   • Batched async-safe network flushing
//

import Foundation
import UIKit
import Vision
import CoreML

// MARK: - Analytics Event Structure

/// A lightweight analytics payload used to transport
/// events to a telemetry endpoint.
///
/// Each event contains:
///  - `name`     : Event identifier
///  - `timestamp`: UNIX time when event occurred
///  - `payload`  : Key-value metadata dictionary
public struct AIAnalyticsEvent: Codable {
    public let name: String
    public let timestamp: TimeInterval
    public let payload: [String: String]
}


// MARK: - AIAnalytics Manager

/// Centralized analytics engine responsible for:
///
///  • Collecting image-processing telemetry
///  • Recording performance metrics and errors
///  • Performing AI-based metadata extraction
///  • Batching & sending telemetry to a server endpoint
///
///  The manager is `@MainActor` isolated because:
///  - Most analytics originate from UI-driven flows
///  - Buffer mutations are kept thread-safe
///
///  All network operations run asynchronously without blocking UI.
@MainActor
public final class AIAnalytics {

    /// Global shared instance.
    public static let shared = AIAnalytics()

    // MARK: - Configuration

    /// Max number of events before forced flush.
    private let maxBatchSize = 50

    /// Auto-flush interval in seconds.
    private let flushInterval: TimeInterval = 60

    /// Background flush task.
    private var flushTask: Task<Void, Never>?

    /// Telemetry endpoint provided via global config.
    private var endpoint: URL? { AIImageConfig.shared.telemetryEndpoint }

    /// Global telemetry toggle.
    private var telemetryEnabled: Bool { AIImageConfig.shared.telemetryEnabled }

    // MARK: - State

    /// Local buffer of pending telemetry events.
    private var buffer: [AIAnalyticsEvent] = []

    /// Last successful flush timestamp.
    private var lastFlush: Date = Date()

    // MARK: - Initialization

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        startAutoFlush()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        Task { [weak self] in
            await self?.flushTask?.cancel()
        }
    }


    // MARK: - Public Event Recording APIs
    // ---------------------------------------------------------------------

    /**
     Records a high-level pipeline completion event.

     - Parameters:
       - url: Original image URL
       - format: Image file type (e.g. "jpeg", "webp")
       - transformations: Steps performed by the pipeline
       - saliency: Optional Vision saliency score
       - category: Optional CoreML-predicted category
     */
    public func recordPipelineCompletion(
        url: URL,
        format: String,
        transformations: [Any],
        saliency: Double? = nil,
        category: String? = nil
    ) {
        guard telemetryEnabled, endpoint != nil else { return }

        var payload: [String: String] = [
            "host": url.host ?? "unknown",
            "path": url.path,
            "format": format,
            "transforms": transformations.map { "\($0)" }.joined(separator: ",")
        ]

        if let s = saliency { payload["saliency"] = String(format: "%.3f", s) }
        if let c = category { payload["category"] = c }

        append(
            AIAnalyticsEvent(
                name: "pipeline_completion",
                timestamp: Date().timeIntervalSince1970,
                payload: payload
            )
        )
    }

    /**
     Records a cache-level hit (e.g., memory, disk, network).

     - Parameter level: Identifier such as `"memory"`, `"disk"`, `"network"`.
     */
    public func recordCacheLevelHit(level: String) {
        guard telemetryEnabled else { return }

        append(
            AIAnalyticsEvent(
                name: "cache_hit",
                timestamp: Date().timeIntervalSince1970,
                payload: ["level": level]
            )
        )
    }

    /**
     Records a predicted latency score for the host using CoreML.

     - Parameters:
       - host: Target server host
       - score: Predicted latency value
     */
    public func recordLatency(host: String, score: Double) {
        guard telemetryEnabled else { return }

        append(
            AIAnalyticsEvent(
                name: "latency_prediction",
                timestamp: Date().timeIntervalSince1970,
                payload: [
                    "host": host,
                    "score": String(format: "%.3f", score)
                ]
            )
        )
    }

    /**
     Records model-loading metadata such as load time and file size.

     - Parameters:
       - name: CoreML model name
       - duration: Load time in seconds
       - sizeBytes: Raw model size in bytes
     */
    public func recordModelLoad(name: String, duration: TimeInterval, sizeBytes: Int) {
        guard telemetryEnabled else { return }

        append(
            AIAnalyticsEvent(
                name: "model_load",
                timestamp: Date().timeIntervalSince1970,
                payload: [
                    "model": name,
                    "duration_ms": "\(Int(duration * 1000))",
                    "size_kb": "\(sizeBytes / 1024)"
                ]
            )
        )
    }

    /**
     Records a generic analytics error event.

     - Parameters:
       - name: Error identifier
       - info: Additional details
     */
    public func recordError(_ name: String, info: String) {
        guard telemetryEnabled else { return }

        append(
            AIAnalyticsEvent(
                name: "error",
                timestamp: Date().timeIntervalSince1970,
                payload: ["error": name, "info": info]
            )
        )
    }

    // MARK: - Automated AI Signals
    // ---------------------------------------------------------------------

    /**
     Computes Vision saliency score for an image and records it.

     Uses `VNGenerateAttentionBasedSaliencyImageRequest`
     (available on iOS 15+). Produces a normalized average saliency value.

     - Parameter image: Source image
     */
    public func recordImageSaliency(_ image: UIImage) async {
        guard telemetryEnabled else { return }
        guard let cg = image.cgImage else { return }

        if #available(iOS 15.0, *) {
            let request = VNGenerateAttentionBasedSaliencyImageRequest()
            let handler = VNImageRequestHandler(cgImage: cg)

            try? handler.perform([request])

            guard let obs = request.results?.first as? VNSaliencyImageObservation else {
                return
            }

            let buffer: CVPixelBuffer = obs.pixelBuffer
            let score = computePixelBufferAverage(buffer)

            recordValue(name: "vision_saliency", value: score)
        }
    }

    /**
     Predicts image category using a CoreML model.

     - Parameters:
       - modelName: Name of the registered CoreML model wrapper
       - image: Source image
     */
    public func recordCategory(using modelName: String, image: UIImage) async {
        guard telemetryEnabled else { return }
        guard let cg = image.cgImage else { return }

        guard
            let wrapper = await AIModelManager.shared.model(named: modelName) as? CoreMLModelWrapper,
            let ml = wrapper.coreMLModel
        else { return }

        do {
            let vn = try VNCoreMLModel(for: ml)
            let request = VNCoreMLRequest(model: vn)
            request.imageCropAndScaleOption = .centerCrop

            let handler = VNImageRequestHandler(cgImage: cg)
            try handler.perform([request])

            if let obs = request.results?.first as? VNClassificationObservation {
                recordValue(name: "ai_category", value: obs.identifier)
            }

        } catch {
            recordError("category_prediction", info: error.localizedDescription)
        }
    }

    /**
     Records extracted metadata keys for a target URL.

     - Parameters:
       - url: Original source URL
       - metadata: Extracted metadata wrapped in `AIMetadataBox`
     */
    public func recordMetadata(for url: URL, metadata: AIMetadataBox) async {
        guard telemetryEnabled else { return }

        let keys = metadata.value.keys.joined(separator: ",")

        append(
            AIAnalyticsEvent(
                name: "metadata_extracted",
                timestamp: Date().timeIntervalSince1970,
                payload: [
                    "host": url.host ?? "unknown",
                    "meta_keys": keys
                ]
            )
        )

        #if DEBUG
        print("[AIAnalytics] Metadata recorded → keys: \(keys)")
        #endif
    }

    // MARK: - Private Recording Helpers

    /// Convenience wrapper for recording a simple numeric or string value.
    private func recordValue(name: String, value: Any) {
        append(
            AIAnalyticsEvent(
                name: name,
                timestamp: Date().timeIntervalSince1970,
                payload: ["value": "\(value)"]
            )
        )
    }

    // MARK: - Saliency PixelBuffer Helper

    /**
     Computes the normalized average brightness of a saliency heatmap.

     Used to derive a simple 0–1 saliency score.

     - Parameter buffer: Pixel buffer from Vision saliency request
     - Returns: Normalized average value between `0` and `1`
     */
    private func computePixelBufferAverage(_ buffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0.5 }

        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)

        let ptr = base.assumingMemoryBound(to: UInt8.self)

        var sum: Double = 0
        for y in 0..<h {
            let row = ptr + y * stride
            for x in 0..<w {
                sum += Double(row[x]) / 255.0
            }
        }

        return min(max(sum / Double(w * h), 0), 1)
    }

    // MARK: - Buffer Handling
    // ---------------------------------------------------------------------

    /**
     Appends an analytics event to the buffer.
     Automatically triggers a flush if the batch size is reached.
     */
    private func append(_ event: AIAnalyticsEvent) {
        buffer.append(event)
        if buffer.count >= maxBatchSize {
            Task { await flushBuffer() }
        }
    }

    /**
     Flushes the buffer to the telemetry endpoint.

     - Returns:
       - `true` if successful or nothing to send
       - `false` if failed or telemetry disabled
     */
    @discardableResult
    public func flushBuffer() async -> Bool {
        guard telemetryEnabled, let endpoint else {
            buffer.removeAll()
            lastFlush = Date()
            return false
        }

        guard !buffer.isEmpty else {
            lastFlush = Date()
            return true
        }

        let events = buffer
        buffer.removeAll()
        lastFlush = Date()

        do {
            let payload = try JSONEncoder().encode(events)

            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = payload
            req.timeoutInterval = 10

            let (_, resp) = try await URLSession.shared.data(for: req)

            guard
                let http = resp as? HTTPURLResponse,
                (200..<300).contains(http.statusCode)
            else {
                return false
            }

            return true

        } catch {
            if AIImageConfig.shared.enableDebugLogs {
                await AILog.shared.warning("AIAnalytics flush failed → \(error.localizedDescription)")
            }
            return false
        }
    }

    // MARK: - Auto Flush Timer

    /// Starts a repeating background task that flushes analytics every 60 seconds.
    private func startAutoFlush() {
        flushTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(flushInterval * 1e9))
                await self.flushBuffer()
            }
        }
    }

    // MARK: - Background Handling

    /// Flushes analytics when the app transitions to background.
    @objc private func appDidEnterBackground() {
        Task { await flushBuffer() }
    }

    // MARK: - AI: Image Category Tracking (Convenience)

    /**
     Extracts image category via CoreML model `"AICategory_v1"`.

     - Parameter image: The input image used for category prediction.
     */
    public func recordImageCategory(_ image: UIImage) async {
        guard telemetryEnabled else { return }

        guard
            let wrapper = await AIModelManager.shared.model(named: "AICategory_v1") as? CoreMLModelWrapper,
            let mlModel = wrapper.coreMLModel,
            let cg = image.cgImage
        else { return }

        do {
            let vnModel = try VNCoreMLModel(for: mlModel)
            let request = VNCoreMLRequest(model: vnModel)
            request.imageCropAndScaleOption = .centerCrop

            let handler = VNImageRequestHandler(cgImage: cg)
            try handler.perform([request])

            if let obs = request.results?.first as? VNClassificationObservation {
                recordValue(name: "image_category", value: obs.identifier)
            }

        } catch {
            if AIImageConfig.shared.enableDebugLogs {
                await AILog.shared.warning("recordImageCategory failed → \(error.localizedDescription)")
            }
        }
    }
}

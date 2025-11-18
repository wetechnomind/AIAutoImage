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

public actor AINetworkAdvisor: Sendable {

    public static let shared = AINetworkAdvisor()

    private var latencyScores: [String : Double] = [:]
    private var errorScores: [String : Int] = [:]
    private var successScores: [String : Int] = [:]

    private init() {}

    public func predictLatency(for host: String) async -> Double {
        guard
            let wrapper = await AIModelManager.shared.model(named: "AICDNLatency_v1") as? CoreMLModelWrapper,
            let mlModel = wrapper.coreMLModel
        else { return 0.5 }

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

    @available(iOS 15.0, *)
    private func runVisionScoring(_ cg: CGImage) throws -> Double {
        let req = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cg)
        try handler.perform([req])

        guard let obs = req.results?.first as? VNSaliencyImageObservation else { return 0.5 }

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

        return max(0, min(1, sum / Double(width * height)))
    }

    public func record(host: String, success: Bool) {
        if success { successScores[host, default: 0] += 1 }
        else { errorScores[host, default: 0] += 1 }
    }

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

    public func aiBackoff(for attempt: Int, host: String) async -> TimeInterval {
        let penalty = Double(errorScores[host, default: 0]) * 0.05
        return pow(1.6, Double(attempt)) + penalty
    }
}


// ================================================================
// MARK: - Task Storage Actor
// ================================================================

actor AINetworkActor {
    private var tasks: [URL: URLSessionTask] = [:]

    func setTask(_ task: URLSessionTask, for url: URL) { tasks[url] = task }
    func removeTask(for url: URL) { tasks.removeValue(forKey: url) }
    func getTask(for url: URL) -> URLSessionTask? { tasks[url] }
    func allTasks() -> [URLSessionTask] { Array(tasks.values) }
    func clearAll() { tasks.removeAll() }
}


// ================================================================
// MARK: - Main AI+Network Engine
// ================================================================

public final class AINetwork: Sendable {

    public let maxRetries: Int
    public let baseBackoff: TimeInterval
    public let session: URLSession

    private let state = AINetworkActor()

    // -----------------------------------------------------------------
    // FIX: SAFE — captured MAIN ACTOR values (no crash)
    // -----------------------------------------------------------------
    // -----------------------------------------------------------------
    // MARK: - Safe MainActor Configuration Capture (Swift 6 compliant)
    // -----------------------------------------------------------------

    private actor AINetworkConfigStore {
        private(set) var timeout: TimeInterval = 20.0

        func getTimeout() -> TimeInterval {
            timeout
        }

        func updateTimeout(_ value: TimeInterval) {
            timeout = value
        }
    }

    
    /// Internal actor to safely hold configuration values.
    private static let configStore = AINetworkConfigStore()

    public nonisolated static func capturedTimeout() async -> TimeInterval {
        await configStore.getTimeout()
    }

    @MainActor
    public static func configureFromMainActor() {
        let newValue = AIImageConfig.shared.networkTimeout

        Task { @Sendable in
            await configStore.updateTimeout(newValue)
        }
    }




    // -----------------------------------------------------------------
    // SAFE init — no MainActor reads here
    // -----------------------------------------------------------------
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

            // Async apply timeout safely
            Task { @Sendable in
                let timeout = await AINetwork.capturedTimeout()
                cfg.timeoutIntervalForRequest = timeout
            }

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
    // MARK: - Perform HTTP Request
    // ============================================================

    public func perform(_ request: URLRequest) async throws -> (Data, URLResponse?, URLSessionTask) {

        var req = request

        // SAFE: Execute requestModifier on MainActor
        await MainActor.run {
            if let mod = AIImageConfig.shared.requestModifier {
                mod(&req)
            }
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

                if (200..<300).contains(http.statusCode) {
                    await AINetworkAdvisor.shared.record(host: host, success: true)
                    if let url = req.url { await state.removeTask(for: url) }
                    return (data, resp, task)
                }

                if [429, 500, 502, 503, 504].contains(http.statusCode),
                    attempt < maxRetries {

                    lastError = NSError(
                        domain: "AINetwork",
                        code: http.statusCode,
                        userInfo: [NSLocalizedDescriptionKey : "HTTP \(http.statusCode)"]
                    )

                    let delay = await AINetworkAdvisor.shared.aiBackoff(for: attempt, host: host)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1e9))

                    await AINetworkAdvisor.shared.record(host: host, success: false)
                    continue
                }

                await AINetworkAdvisor.shared.record(host: host, success: false)
                if let url = req.url { await state.removeTask(for: url) }

                throw NSError(
                    domain: "AINetwork",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]
                )
            }

            if let url = req.url { await state.removeTask(for: url) }
            return (data, resp, task)
        }

        throw lastError ?? NSError(
            domain: "AINetwork",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Network error"]
        )
    }

    // ============================================================
    // MARK: - Task Creator
    // ============================================================

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
    // MARK: - Cancel APIs
    // ============================================================

    public func cancel(_ url: URL) {
        Task {
            if let task = await state.getTask(for: url) {
                task.cancel()
                await state.removeTask(for: url)
            }
        }
    }

    public func cancelAll() {
        Task {
            let all = await state.allTasks()
            for t in all { t.cancel() }
            await state.clearAll()
        }
    }

    // ============================================================
    // MARK: - Prefetch
    // ============================================================

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

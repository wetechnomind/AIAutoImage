//
//  AIModelManager.swift
//  AIAutoImageCore
//

import Foundation
import CoreML
import UIKit

/// A centralized, thread-safe (actor-isolated) manager responsible for loading,
/// caching, and evicting AI models used throughout the AIAutoImage framework.
///
/// `AIModelManager` provides:
/// - Registration and discovery of AI models
/// - Automatic memory budgeting based on `AIImageConfig.modelMemoryLimit`
/// - CoreML loading with analytics instrumentation
/// - LRU-like trimming to stay within memory limits
///
/// Models may include:
/// - CoreML-based predictors (sharpness, CDN latency, category classification)
/// - Custom backends (ONNX, PyTorch wrappers, depth estimators, upscalers)
///
/// # Example
/// ```swift
/// let url = Bundle.main.url(forResource: "MyModel", withExtension: "mlmodelc")!
/// let model = try await AIModelManager.shared.loadCoreMLModel(named: "super_res", from: url)
///
/// if let m = await AIModelManager.shared.model(named: "super_res") {
///     let output = try m.predict(inputs: ["image": inputImage])
/// }
/// ```
public actor AIModelManager: Sendable {

    // MARK: - Singleton

    /// Global shared instance used by the entire pipeline.
    ///
    /// Marked `nonisolated` so it is accessible without requiring `await`.
    public nonisolated static let shared = AIModelManager()

    // MARK: - Internal Storage

    /// In-memory dictionary of currently loaded models, keyed by model name.
    private var loaded: [String: AIModel] = [:]

    /// Current total memory consumed by loaded models.
    private var totalLoadedBytes: Int = 0

    /// Maximum memory budget for models, sourced from global configuration.
    private var maxMemoryBytes: Int {
        AIImageConfig.shared.modelMemoryLimit
    }

    /// Private initializer—only accessible via the singleton.
    private init() {}


    // MARK: - Registration

    /// Registers a new model into memory.
    ///
    /// If a model with the same name already exists, it is replaced and its
    /// memory usage is subtracted from the total.
    ///
    /// After registration, the manager may immediately evict older/larger models
    /// if the memory limit is exceeded.
    ///
    /// - Parameter model: The AI model to register.
    public func register(_ model: AIModel) {
        if let old = loaded[model.name] {
            totalLoadedBytes -= old.sizeBytes
        }

        loaded[model.name] = model
        totalLoadedBytes += model.sizeBytes

        trimIfNeeded()
    }

    /// Removes a model with the given name, if present.
    ///
    /// - Parameter name: Unique model identifier.
    public func removeModel(named name: String) {
        guard let old = loaded.removeValue(forKey: name) else { return }
        totalLoadedBytes -= old.sizeBytes
    }

    /// Removes **all models** immediately, resetting memory counters.
    public func clearAll() {
        loaded.removeAll()
        totalLoadedBytes = 0
    }


    // MARK: - Lookup

    /// Returns a previously registered model, or `nil` if not found.
    ///
    /// - Parameter name: Name used when registering the model.
    public func model(named name: String) -> AIModel? {
        loaded[name]
    }


    // MARK: - Load CoreML Models

    /// Loads a CoreML model from disk, wraps it in a `CoreMLModelWrapper`,
    /// registers it, and reports analytics.
    ///
    /// This function:
    /// - Loads an `.mlmodelc` directory or `.mlmodel` file
    /// - Measures load time
    /// - Wraps into `CoreMLModelWrapper`
    /// - Registers it for caching and trimming
    /// - Sends analytics events to `AIAnalytics`
    ///
    /// - Parameters:
    ///   - name: Unique name used for registration and lookup.
    ///   - url: File URL to a compiled CoreML model (`.mlmodelc`) or `.mlmodel`.
    ///
    /// - Returns: The wrapped `AIModel`.
    ///
    /// - Throws: Any error thrown by `MLModel(contentsOf:)`.
    @discardableResult
    public func loadCoreMLModel(named name: String, from url: URL) async throws -> AIModel {

        // Load model
        let start = Date()
        let mlmodel = try MLModel(contentsOf: url)
        let duration = Date().timeIntervalSince(start)

        // Wrap
        let wrapper = CoreMLModelWrapper(name: name, mlModel: mlmodel)

        // Register into memory
        register(wrapper)

        // Analytics must run on main thread
        await MainActor.run {
            AIAnalytics.shared.recordModelLoad(
                name: name,
                duration: duration,
                sizeBytes: wrapper.sizeBytes
            )
        }

        return wrapper
    }


    // MARK: - Memory Cleanup (LRU-like)

    /// Evicts models until the total memory usage fits within the global budget.
    ///
    /// Removal strategy:
    /// - Sort models by size descending (largest first)
    /// - Remove models until total memory ≤ limit
    ///
    /// This is simple yet effective for memory-constrained environments.
    private func trimIfNeeded() {
        guard totalLoadedBytes > maxMemoryBytes else { return }

        // Largest-first deletion to free max memory quickly.
        let sorted = loaded.values.sorted { $0.sizeBytes > $1.sizeBytes }

        for model in sorted {
            if totalLoadedBytes <= maxMemoryBytes { break }

            loaded.removeValue(forKey: model.name)
            totalLoadedBytes -= model.sizeBytes
        }
    }


    // MARK: - Debug

    /// Provides a diagnostic snapshot of all loaded models and their memory usage.
    ///
    /// - Returns: List of `(name, sizeKB)` pairs, for UI inspection or logs.
    public func debugLoadedModels() -> [(name: String, sizeKB: Int)] {
        loaded.values.map { ($0.name, $0.sizeBytes / 1024) }
    }
}

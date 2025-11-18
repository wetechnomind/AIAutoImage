//
//  AIModelManager.swift
//  AIAutoImageCore
//

import Foundation
import CoreML
import UIKit

public actor AIModelManager: Sendable {

    // MARK: - Singleton (nonisolated)
    public nonisolated static let shared = AIModelManager()


    // MARK: - Internal Storage
    private var loaded: [String: AIModel] = [:]
    private var totalLoadedBytes: Int = 0

    /// Maximum ML memory budget (safe value set after configuration)
    private var maxMemoryBytes: Int = 128 * 1024 * 1024   // default fallback 128MB


    // MARK: - Initialization

    /// Nonisolated initializer — MUST NOT read MainActor values.
    private init() {
        // uses fallback `maxMemoryBytes` until configured
    }

    /// Call once at app startup to sync MainActor config.
    public func configureFromMainActor() async {
        let memLimit = await MainActor.run {
            AIImageConfig.shared.modelMemoryLimit
        }
        self.maxMemoryBytes = memLimit
    }


    // MARK: - Registration

    public func register(_ model: AIModel) {
        if let old = loaded[model.name] {
            totalLoadedBytes -= old.sizeBytes
        }

        loaded[model.name] = model
        totalLoadedBytes += model.sizeBytes

        trimIfNeeded()
    }

    public func removeModel(named name: String) {
        guard let old = loaded.removeValue(forKey: name) else { return }
        totalLoadedBytes -= old.sizeBytes
    }

    public func clearAll() {
        loaded.removeAll()
        totalLoadedBytes = 0
    }


    // MARK: - Lookup

    public func model(named name: String) -> AIModel? {
        loaded[name]
    }


    // MARK: - Load CoreML Models

    @discardableResult
    public func loadCoreMLModel(named name: String, from url: URL) async throws -> AIModel {

        let start = Date()
        let mlmodel = try MLModel(contentsOf: url)
        let duration = Date().timeIntervalSince(start)

        let wrapper = CoreMLModelWrapper(name: name, mlModel: mlmodel)
        register(wrapper)

        await MainActor.run {
            AIAnalytics.shared.recordModelLoad(
                name: name,
                duration: duration,
                sizeBytes: wrapper.sizeBytes
            )
        }

        return wrapper
    }


    // MARK: - Memory Cleanup

    private func trimIfNeeded() {
        guard totalLoadedBytes > maxMemoryBytes else { return }

        let sorted = loaded.values.sorted { $0.sizeBytes > $1.sizeBytes }

        for model in sorted {
            if totalLoadedBytes <= maxMemoryBytes { break }
            loaded.removeValue(forKey: model.name)
            totalLoadedBytes -= model.sizeBytes
        }
    }


    // MARK: - Debug

    public func debugLoadedModels() -> [(name: String, sizeKB: Int)] {
        loaded.values.map { ($0.name, $0.sizeBytes / 1024) }
    }
}

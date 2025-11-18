//
//  AIPluginManager.swift
//  AIAutoImageCore
//

import Foundation
import UIKit

/// Central actor-based manager responsible for orchestrating all `AIPlugin`
/// instances within **AIAutoImageCore**.
///
/// The plugin manager handles:
/// - Plugin registration and priority ordering
/// - Plugin lifecycle (`onLoad`, `onUnload`)
/// - Broadcasting registration requests for:
///    - Decoders
///    - Image transforms
///    - Metadata extractors
/// - Broadcasting events such as:
///    - Image decoded events
///    - Image request events
///
/// All operations run inside an actor, ensuring:
/// - Thread safety
/// - Deterministic plugin ordering
/// - Non-blocking asynchronous execution
///
/// Plugins are stored by name and sorted by priority (higher first).
public actor AIPluginManager: Sendable {

    /// Shared global instance.
    public static let shared = AIPluginManager()

    /// Plugin storage, keyed by `plugin.name`.
    private var plugins: [String: AIPlugin] = [:]

    /// Private initializer — use `AIPluginManager.shared`.
    private init() {}

    // MARK: - Plugin Registration

    /// Registers a plugin and triggers its `onLoad()` lifecycle event.
    ///
    /// Registration automatically:
    /// - Inserts the plugin into the internal plugin map
    /// - Re-sorts all plugins by priority (highest first)
    /// - Calls `plugin.onLoad()`
    ///
    /// - Parameter plugin: The plugin instance to register.
    public func register(_ plugin: AIPlugin) async {
        plugins[plugin.name] = plugin

        // Sort plugins by priority (descending)
        let sorted = plugins.values.sorted { $0.priority > $1.priority }

        // Recreate dictionary in the new sorted order
        plugins = Dictionary(uniqueKeysWithValues: sorted.map { ($0.name, $0) })

        // Trigger plugin load (often used for ML model warm-up)
        await plugin.onLoad()
    }

    /// Unloads all plugins and clears the registry.
    ///
    /// Calls `onUnload()` for each plugin before removal.
    public func unloadAll() async {
        for p in plugins.values {
            await p.onUnload()
        }
        plugins.removeAll()
    }

    // MARK: - Access

    /// Retrieves a plugin by its name.
    ///
    /// - Parameter named: Plugin name.
    /// - Returns: The plugin instance or `nil`.
    public func plugin(named: String) -> AIPlugin? {
        return plugins[named]
    }

    /// Returns all registered plugins in priority order.
    public func allPlugins() -> [AIPlugin] {
        return Array(plugins.values)
    }

    // MARK: - Decoder Registration Pipeline

    /// Allows all plugins to register their custom decoders.
    ///
    /// - Parameter registrar: The central decoder registrar.
    ///
    /// Plugins override `registerDecoders` to add:
    /// - WebP decoders
    /// - AVIF/HEIF handlers
    /// - RAW processors
    /// - AI-specific decoding formats
    public func registerDecoders(into registrar: AIImageCodersRegistrar) async {
        for plugin in plugins.values {
            await plugin.registerDecoders(into: registrar)
        }
    }

    // MARK: - Transform Registration Pipeline

    /// Allows plugins to add transforms into the shared transform pipeline.
    ///
    /// - Parameter pipeline: The central image transformation pipeline.
    ///
    /// Typical plugin transforms include:
    /// - Super-resolution
    /// - Denoising
    /// - Style transfer
    /// - Face-aware corrections
    public func registerTransforms(into pipeline: AITransformPipeline) async {
        for plugin in plugins.values {
            await plugin.registerTransforms(into: pipeline)
        }
    }

    // MARK: - Metadata Extractor Registration

    /// Allows plugins to register custom metadata extractors.
    ///
    /// - Parameter center: The metadata extraction center.
    ///
    /// Examples:
    /// - OCR readers
    /// - Face detectors
    /// - Content classifiers
    /// - Sharpness/brightness metrics
    public func registerMetadataExtractors(into center: AIImageMetadataCenter) async {
        for plugin in plugins.values {
            await plugin.registerMetadataExtractors(into: center)
        }
    }

    // MARK: - Event Dispatch

    /// Broadcasts an “image decoded” event to all plugins.
    ///
    /// - Parameters:
    ///   - image: The decoded image (JPEG/PNG/WebP/AVIF/GIF/APNG/etc.)
    ///   - context: Optional metadata context from the request.
    ///
    /// Each plugin receives its event on a detached task to allow parallel processing.
    public func notifyImageDecoded(_ image: UIImage, context: [String: Sendable]? = nil) async {
        for plugin in plugins.values {
            Task.detached {
                await plugin.onImageDecoded(image, context: context)
            }
        }
    }

    /// Broadcasts an “image request” event to all plugins.
    ///
    /// - Parameters:
    ///   - url: The URL being requested (network/disk/cache).
    ///   - context: Optional metadata.
    ///
    /// Useful for:
    /// - Logging
    /// - Analytics
    /// - Cache behavior customization
    public func notifyRequest(_ url: URL, context: [String: Sendable]? = nil) async {
        for plugin in plugins.values {
            Task.detached {
                await plugin.onRequest(url, context: context)
            }
        }
    }

    // MARK: - Utilities

    /// Returns the number of registered plugins.
    public func pluginCount() -> Int {
        plugins.count
    }
}

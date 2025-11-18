//
//  AIPlugin.swift
//  AIAutoImageCore
//

import Foundation
import CoreML
import Vision
import UIKit

/// A production-grade plugin contract for extending `AIAutoImageCore`.
///
/// Plugins enable modular, composable enhancements to the system by
/// allowing external modules to:
/// - Register custom decoders (WebP, AVIF, HEIC, RAW, AI formats)
/// - Inject Vision/CoreML pipelines
/// - Add custom image transforms
/// - Modify caching strategies
/// - Add metadata processors (OCR, faces, saliency, classification)
/// - Provide animated-image hooks
/// - Observe decode and request lifecycle events
///
/// All plugin APIs are:
/// - `async` (non-blocking)
/// - `Sendable` (actor-safe)
/// - Executed inside the plugin center's actor isolation
///
/// A plugin typically loads models or sets up resources in `onLoad()`,
/// and registers its features using the various registration hooks.
public protocol AIPlugin: Sendable {

    // MARK: - Identity

    /// Human-readable plugin name.
    ///
    /// Appears in logs, debugging, and introspection tools.
    var name: String { get }

    /// Plugin priority, where a higher number is executed earlier.
    ///
    /// Recommended range: **100–900**, similar to UIKit layout priorities:
    /// - 900+ → critical system plugins
    /// - 700–800 → heavy ML plugins
    /// - 500 → default plugins
    /// - 300 → optional filters
    var priority: Int { get }

    // MARK: - Lifecycle

    /// Called once when the plugin is first loaded.
    ///
    /// Use this to:
    /// - Load CoreML models
    /// - Initialize Vision request handlers
    /// - Warm up GPU contexts
    /// - Allocate resources
    func onLoad() async

    /// Called before plugin removal or system shutdown.
    ///
    /// Use to:
    /// - Release ML models
    /// - Save state
    /// - Shutdown observers
    func onUnload() async

    // MARK: - Decoder Hooks

    /// Allow plugins to register custom image decoders.
    ///
    /// Examples:
    /// - WebP
    /// - AVIF
    /// - RAW formats
    /// - HEIC helpers
    /// - AI-specific embeddings
    ///
    /// - Parameter registrar: Decoder registrar for injection.
    func registerDecoders(into registrar: AIImageCodersRegistrar) async

    // MARK: - Transform Hooks

    /// Allow plugins to register image transforms into the pipeline.
    ///
    /// Examples:
    /// - Super-resolution
    /// - Face-aware lighting correction
    /// - AI denoise
    /// - Style transfer
    ///
    /// - Parameter pipeline: Main transform pipeline.
    func registerTransforms(into pipeline: AITransformPipeline) async

    // MARK: - Metadata Hooks

    /// Allow plugins to register metadata extractors.
    ///
    /// Examples:
    /// - Face detection
    /// - Saliency scoring
    /// - OCR extraction
    /// - Sharpness/contrast analysis
    /// - AI content classification
    ///
    /// - Parameter center: Metadata extraction center.
    func registerMetadataExtractors(into center: AIImageMetadataCenter) async

    // MARK: - Events

    /// Optional callback fired after an image has been decoded.
    ///
    /// - Parameters:
    ///   - image: The decoded image.
    ///   - context: Optional request context propagated by the pipeline.
    func onImageDecoded(_ image: UIImage, context: [String: Sendable]?) async

    /// Optional callback fired when an image request begins.
    ///
    /// - Parameters:
    ///   - url: The requested image URL.
    ///   - context: Optional metadata associated with the request.
    func onRequest(_ url: URL, context: [String: Sendable]?) async
}


// MARK: - Default Implementations (Optional Methods)

/// Unified default plugin behaviors so plugins may override
/// only the hooks they require.
///
/// This keeps plugin implementations lightweight and focused.
public extension AIPlugin {

    /// Default priority is medium (500).
    var priority: Int { 500 }

    /// Default lifecycle callbacks (no-ops).
    func onLoad() async {}
    func onUnload() async {}

    /// Default decoders / transforms / metadata hooks (no-ops).
    func registerDecoders(into registrar: AIImageCodersRegistrar) async {}
    func registerTransforms(into pipeline: AITransformPipeline) async {}
    func registerMetadataExtractors(into center: AIImageMetadataCenter) async {}

    /// Default events (no-ops).
    func onImageDecoded(_ image: UIImage, context: [String: Sendable]?) async {}
    func onRequest(_ url: URL, context: [String: Sendable]?) async {}
}


// MARK: - Plugin Center

/// Central actor responsible for managing all registered plugins.
///
/// Responsibilities:
/// - Registers plugins and sorts them by priority
/// - Calls plugin lifecycle events (`onLoad`, `onUnload`)
/// - Dispatches decode/request events
/// - Allows plugins to inject decoders, transforms, and metadata extractors
///
/// `AIPluginCenter` guarantees:
/// - Full actor isolation (thread-safety)
/// - Ordered plugin execution (highest priority first)
/// - Non-blocking async behavior
public actor AIPluginCenter {

    /// Shared global singleton.
    public static let shared = AIPluginCenter()

    /// Private initializer — use `shared`.
    private init() {}

    /// All registered plugins, sorted by priority.
    private var plugins: [AIPlugin] = []

    /// Registers a plugin and immediately triggers `onLoad()`.
    ///
    /// - Parameter plugin: The plugin instance.
    ///
    /// After registration, plugins are sorted so higher-priority
    /// plugins execute earlier in the pipeline.
    public func register(_ plugin: AIPlugin) async {
        plugins.append(plugin)
        plugins.sort { $0.priority > $1.priority }
        await plugin.onLoad()
    }

    /// Unloads and removes all plugins from the system.
    ///
    /// Calls `onUnload()` for each plugin before clearing.
    public func unloadAll() async {
        for p in plugins {
            await p.onUnload()
        }
        plugins.removeAll()
    }

    /// Sends image decoded event to all plugins.
    ///
    /// - Parameters:
    ///   - image: Decoded UI image.
    ///   - context: Optional request context.
    public func notifyImageDecoded(_ image: UIImage, context: [String: Sendable]?) async {
        for p in plugins {
            await p.onImageDecoded(image, context: context)
        }
    }

    /// Sends request event to all plugins.
    ///
    /// - Parameters:
    ///   - url: URL of the requested image.
    ///   - context: Optional metadata.
    public func notifyRequest(_ url: URL, context: [String: Sendable]?) async {
        for p in plugins {
            await p.onRequest(url, context: context)
        }
    }

    /// Allows plugins to register custom decoders.
    ///
    /// - Parameter registrar: Decoder registrar instance.
    public func registerDecoders(into registrar: AIImageCodersRegistrar) async {
        for p in plugins {
            await p.registerDecoders(into: registrar)
        }
    }
}

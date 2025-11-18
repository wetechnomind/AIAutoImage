//
//  AIImageCodersRegistrar.swift
//  AIAutoImageCore
//
//  AI-aware pluggable image decoder registry.
//
//  Features:
//  • Actor-isolated, Sendable-safe design
//  • Plugin-based decoders for WebP/AVIF/custom formats
//  • Magic-byte heuristics for instant MIME guessing
//  • Optional async CoreML/Vision format classifier
//  • Hybrid ranking: magic-bytes + classifier + decoder heuristic
//  • Small in-actor caches and telemetry tracking
//

import Foundation
import UIKit
import Vision
import CoreImage
import CoreML

/// Global registry for all custom image decoders (WebP, AVIF, plugin codecs).
///
/// The registrar is:
/// - **Actor-isolated** (thread-safe)
/// - **Fully Sendable**
/// - **Extensible at runtime**
///
/// Decoding pipeline combines:
/// - Fast magic-byte header checks
/// - Optional async CoreML/Vision MIME classifier
/// - Decoder-specific confidence heuristics
///
/// Returns first successful decoded object:
/// - `UIImage`
/// - `AIAnimatedImage`
/// - Any custom format provided by the plugin
public actor AIImageCodersRegistrar: Sendable {

    // MARK: - Singleton

    /// Shared global instance.
    public static let shared = AIImageCodersRegistrar()


    // MARK: - Decoder Entry

    /// Fully Sendable wrapper for each decoder plugin.
    ///
    /// A decoder provides:
    /// - **mimeHint**: Optional MIME type to help ranking
    /// - **confidence(data)**: Decoder-specific heuristic
    /// - **decode(data)**: Async decode function (must return `UIImage?` or `AIAnimatedImage?`)
    public struct DecoderEntry: Sendable {
        /// MIME type hint used for ranking (e.g., `"image/webp"`).
        public let mimeHint: String?

        /// Returns decoder-specific confidence score for this data.
        /// Values should be 0–1.
        public let confidence: @Sendable (Data) -> Float

        /// Performs the actual decode. Returns `Any?`:
        /// - `UIImage`
        /// - `AIAnimatedImage`
        /// - nil if decode failed
        public let decode: @Sendable (Data) async -> Any?

        public init(
            mimeHint: String?,
            confidence: @Sendable @escaping (Data) -> Float,
            decode: @Sendable @escaping (Data) async -> Any?
        ) {
            self.mimeHint = mimeHint
            self.confidence = confidence
            self.decode = decode
        }
    }

    /// Box used to wrap dynamic decoded objects while preserving Sendable correctness.
    public struct AnySendableBox: @unchecked Sendable {
        public let value: Any
        public init(_ value: Any) { self.value = value }
    }


    // MARK: - Ranking Weights

    /// Weight configuration for decoder ranking.
    ///
    /// These weights are **relative**, not normalized.
    /// Increasing one increases its contribution to total score.
    public struct RankingWeights {
        /// Weight for magic-byte confidence.
        public var magicBytesWeight: Float = 0.6

        /// Weight for async classifier (CoreML/Vision).
        public var classifierWeight: Float = 0.3

        /// Weight for decoder's own heuristic logic.
        public var decoderHeuristicWeight: Float = 0.1
    }

    /// Current ranking weights.
    public var rankingWeights = RankingWeights()


    // MARK: - Internal Storage

    /// List of registered decoders.
    private var decoders: [DecoderEntry] = []

    /// Basic telemetry used for debugging: attempts vs hits.
    private var telemetry = (attempts: 0, hits: 0)

    /// Cache of magic-byte results (keyed by hash of Data).
    private var magicCache: [Int: (mime: String?, score: Float)] = [:]

    /// Cache of classifier results (mimeScore map).
    private var classifierCache: [Int: [String: Float]] = [:]

    /// Optional async classifier (CoreML/Vision/Server).
    ///
    /// Should return: `["image/webp": 0.85, "image/avif": 0.15]`
    private var formatClassifier: (@Sendable (Data) async -> [String: Float])?


    // MARK: - Init

    /// Private initializer registers built-in decoders.
    private init() {

        // Register built-in WebP + AVIF + fallback
        let list: [DecoderEntry] = [
            DecoderEntry(
                mimeHint: "image/webp",
                confidence: { data in Self.magicWebPConfidence(data) },
                decode: { data in await AIWebPCoder().decodeWebP(data: data, maxPixelSize: nil) }
            ),
            DecoderEntry(
                mimeHint: "image/avif",
                confidence: { data in Self.magicAVIFConfidence(data) },
                decode: { data in await AIAVIFCoder().decodeAVIF(data: data, maxPixelSize: nil) }
            ),
            DecoderEntry(
                mimeHint: nil,
                confidence: { _ in 0.05 },
                decode: { data in UIImage(data: data) }
            )
        ]

        self.decoders = list
    }


    // MARK: - Public API

    /// Registers a new custom decoder.
    ///
    /// - Parameters:
    ///   - mimeHint: MIME string such as `"image/webp"`. Optional.
    ///   - confidence: 0–1 confidence score.
    ///   - decode: Async decode function.
    public func register(
        mimeHint: String?,
        confidence: @Sendable @escaping (Data) -> Float,
        decode: @Sendable @escaping (Data) async -> Any?
    ) {
        let entry = DecoderEntry(mimeHint: mimeHint, confidence: confidence, decode: decode)
        decoders.append(entry)
    }

    /// Registers an async CoreML/Vision/remote classifier.
    ///
    /// The classifier:
    /// - Receives raw Data
    /// - Returns MIME probability map
    /// - Caches results internally
    public func registerFormatClassifier(
        _ classifier: @Sendable @escaping (Data) async -> [String: Float]
    ) {
        self.formatClassifier = classifier
        classifierCache.removeAll()
    }

    /// Main async decode entrypoint.
    ///
    /// - Parameter data: Raw image data.
    /// - Returns: Decoded object (`UIImage`, `AIAnimatedImage`, or nil).
    ///
    /// This function:
    /// 1. Ranks decoders using hybrid scoring
    /// 2. Attempts each decoder in order
    /// 3. Returns first successful decode
    public nonisolated func decode(data: Data) async -> Any? {
        await self._decodeImpl(data: data)?.value
    }


    // MARK: - Internal Decode Flow

    /// Actor-isolated decode implementation.
    private func _decodeImpl(data: Data) async -> AnySendableBox? {
        guard !data.isEmpty else { return nil }

        telemetry.attempts += 1

        let rankedDecoders = await computeDecoderScores(for: data)

        for entry in rankedDecoders {
            if let result = await entry.decode(data) {
                telemetry.hits += 1
                return AnySendableBox(result)
            }
        }

        return nil
    }


    // MARK: - Ranking Pipeline

    /// Computes ordered list of decoders sorted by descending confidence score.
    private func computeDecoderScores(for data: Data) async -> [DecoderEntry] {

        // ---------- 1) Magic-byte check ----------
        let key = data.hashValue
        let magic: (mime: String?, score: Float)
        if let cached = magicCache[key] {
            magic = cached
        } else {
            let (m, s) = Self.magicGuess(data)
            magic = (m, s)
            magicCache[key] = magic
        }

        // ---------- 2) Optional classifier (cached) ----------
        var classifierScores: [String: Float] = [:]
        if let cached = classifierCache[key] {
            classifierScores = cached
        } else if let classifier = formatClassifier {
            let result = await classifier(data)
            classifierScores = result
            classifierCache[key] = result
        }

        // ---------- 3) Combine scores ----------
        let w = rankingWeights

        let combined: [(DecoderEntry, Float)] = decoders.map { entry in

            // Magic-byte contribution
            let magicComponent: Float = {
                if let hint = entry.mimeHint {
                    return (hint == magic.mime) ? magic.score : 0
                } else {
                    return magic.score * 0.05
                }
            }()

            // Classifier contribution
            let classifierComponent: Float = {
                if let hint = entry.mimeHint,
                   let score = classifierScores[hint] { return score }
                return classifierScores.isEmpty ? 0 : 0.01
            }()

            // Decoder's own heuristic
            let heuristic = entry.confidence(data)

            // Weighted score
            let total =
                w.magicBytesWeight * magicComponent +
                w.classifierWeight * classifierComponent +
                w.decoderHeuristicWeight * heuristic

            return (entry, total)
        }

        // Sort by descending score
        return combined.sorted { a, b in
            if a.1 == b.1 { return false }
            return a.1 > b.1
        }
        .map { $0.0 }
    }


    // MARK: - Magic-Byte Heuristics

    /// Fast MIME guess using header signatures.
    private static func magicGuess(_ data: Data) -> (String?, Float) {

        guard data.count >= 12 else { return (nil, 0) }

        // WebP
        if let riff = String(bytes: data.prefix(4), encoding: .ascii),
           riff == "RIFF",
           let webp = String(bytes: data[8..<12], encoding: .ascii),
           webp == "WEBP" {
            return ("image/webp", 1.0)
        }

        // AVIF
        if let ftyp = String(bytes: data[4..<12], encoding: .ascii),
           (ftyp.contains("ftypavif") || ftyp.contains("ftypavis")) {
            return ("image/avif", 1.0)
        }

        // JPEG
        if data[0] == 0xFF && data[1] == 0xD8 {
            return ("image/jpeg", 1.0)
        }

        // PNG
        let pngSig: [UInt8] = [137,80,78,71,13,10,26,10]
        if Array(data.prefix(8)) == pngSig {
            return ("image/png", 1.0)
        }

        return (nil, 0)
    }

    /// Confidence helper for WebP magic bytes.
    static func magicWebPConfidence(_ data: Data) -> Float {
        guard data.count >= 12 else { return 0 }
        let r = String(bytes: data.prefix(4), encoding: .ascii)
        let w = String(bytes: data[8..<12], encoding: .ascii)
        return (r == "RIFF" && w == "WEBP") ? 1.0 : 0.0
    }

    /// Confidence helper for AVIF magic bytes.
    static func magicAVIFConfidence(_ data: Data) -> Float {
        guard data.count >= 12 else { return 0 }
        if let f =
            String(bytes: data[4..<12], encoding: .ascii),
           (f.contains("ftypavif") || f.contains("ftypavis")) {
            return 1.0
        }
        return 0.0
    }


    // MARK: - Telemetry & Diagnostics

    /// Returns current telemetry snapshot.
    /// - Returns: (attempts, successfulHits, numberOfDecoders)
    public func telemetrySnapshot() -> (attempts: Int, hits: Int, registeredDecoders: Int) {
        (telemetry.attempts, telemetry.hits, decoders.count)
    }

    /// Clears internal caches for:
    /// - magic-byte detection
    /// - classifier results
    public func clearCaches() {
        magicCache.removeAll()
        classifierCache.removeAll()
    }
}

//
//  TransformTypes.swift
//  AIAutoImageCore
//
//  Defines all public transformation types, style families,
//  quality hints, content categories, request contexts,
//  and serialization logic for AI-driven image processing.
//

import Foundation
import CoreGraphics

// MARK: - Style Types (Neural Style Transfer)

/// Supported neural style-transfer modes for `AITransformation.styleTransfer`.
///
/// These correspond to CoreML models such as:
/// - `AIStyle_cinematic.mlmodelc`
/// - `AIStyle_watercolor.mlmodelc`
///
/// The raw values match model suffixes so they can be used
/// directly inside model naming conventions.
public enum AIStyleType: String, Sendable, Codable {

    /// Filmic, high-contrast movie look (teal/orange, HDR-like)
    case cinematic

    /// Soft watercolor wash with muted edges
    case watercolor

    /// Classic oil-painting texture with stronger strokes
    case oilPainting = "oil_painting"

    /// Glow-heavy neon aesthetic with saturated futuristic colors
    case neon

    /// Pencil sketch line-art style
    case pencil

    /// Anime-style flat-color shading and outlines
    case anime

    /// Hand-drawn sketch with visible pencil textures
    case sketch

    /// Futuristic neon + cyberpunk palette
    case cyberpunk

    /// Retro/vintage tone with muted film colors
    case vintage
}

// MARK: - Main Transformation Enum (Public API)

/// Represents a single transformation step in the AIAutoImage pipeline.
///
/// Transformations are:
/// - Fully async-capable
/// - Executed in order
/// - Cacheable via `cacheIdentifier`
///
/// Example:
/// ```swift
/// let transforms: [AITransformation] = [
///     .backgroundRemoval,
///     .superResolution(scale: 2.0),
///     .styleTransfer(style: .cinematic)
/// ]
/// ```
public enum AITransformation: Sendable, Equatable {

    /// AI background removal (CoreML → Vision → fallback pipeline)
    case backgroundRemoval

    /// Smart cropping using saliency or layout heuristics.
    case contentAwareCrop(CropStyle)

    /// Scene enhancement (vibrance + small contrast lift)
    case enhanceScene

    /// Auto contrast adjustment
    case autoContrast

    /// Auto white balance correction
    case autoWhiteBalance

    /// Auto exposure boost
    case autoExposure

    /// ML Super Resolution (fallback: CI Lanczos upscale)
    case superResolution(scale: Double)

    /// Resize with optional aspect preservation
    case resize(to: CGSize, preserveAspect: Bool)

    /// Noise reduction
    case denoise(level: Double)

    /// Neural style transfer
    case styleTransfer(style: AIStyleType)

    /// Cartoon/comic effect
    case cartoonize

    /// Depth-like texture enhancement
    case depthEnhance

    /// Apple’s full CI auto-enhance pipeline
    case autoEnhance

    /// Fully custom CI/ML transform (`ci:blur` / `ml:ModelName`)
    case custom(id: String, params: [String: String]?)

    /// Crop modes for `.contentAwareCrop`
    public enum CropStyle: String, Sendable, Codable {
        /// Square crop centered on important content
        case square

        /// Portrait-oriented crop (vertical emphasis)
        case portrait

        /// Landscape crop (horizontal emphasis)
        case landscape

        /// Simple centered rectangle crop
        case centered

        /// Vision-based saliency smart crop
        case saliency
    }
}

// MARK: - Codable Conformance
// Enables AITransformation arrays to be saved,
// transmitted over network, and cached reliably.

extension AITransformation: Codable {

    private enum CodingKeys: String, CodingKey {
        case caseName
        case payload
    }

    /// Internal identifiers for the enum cases.
    private enum CaseName: String, Codable {
        case backgroundRemoval
        case contentAwareCrop
        case enhanceScene
        case autoContrast
        case autoWhiteBalance
        case autoExposure
        case superResolution
        case resize
        case denoise
        case styleTransfer
        case cartoonize
        case depthEnhance
        case autoEnhance
        case custom
    }

    /// Payload container holding case-specific parameters.
    private enum Payload: Codable {
        case crop(style: AITransformation.CropStyle)
        case superResolution(scale: Double)
        case resize(width: Double, height: Double, preserve: Bool)
        case denoise(level: Double)
        case style(style: AIStyleType)
        case custom(id: String, params: [String: String]?)
        case none

        private enum Keys: String, CodingKey {
            case type, width, height, preserve, level, style, id, params
        }

        // MARK: Decode
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            let type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""

            switch type {

            case "crop":
                let raw = try container.decodeIfPresent(String.self, forKey: .style)
                let style = AITransformation.CropStyle(rawValue: raw ?? "") ?? .centered
                self = .crop(style: style)

            case "sr":
                let scale = try container.decodeIfPresent(Double.self, forKey: .width) ?? 2
                self = .superResolution(scale: scale)

            case "resize":
                let w = try container.decodeIfPresent(Double.self, forKey: .width) ?? 100
                let h = try container.decodeIfPresent(Double.self, forKey: .height) ?? 100
                let preserve = try container.decodeIfPresent(Bool.self, forKey: .preserve) ?? true
                self = .resize(width: w, height: h, preserve: preserve)

            case "denoise":
                let lvl = try container.decodeIfPresent(Double.self, forKey: .level) ?? 0.5
                self = .denoise(level: lvl)

            case "style":
                let s = try container.decodeIfPresent(String.self, forKey: .style)
                let style = AIStyleType(rawValue: s ?? "") ?? .cinematic
                self = .style(style: style)

            case "custom":
                let id = try container.decodeIfPresent(String.self, forKey: .id) ?? "custom"
                let params = try container.decodeIfPresent([String: String].self, forKey: .params)
                self = .custom(id: id, params: params)

            default:
                self = .none
            }
        }

        // MARK: Encode
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)

            switch self {

            case .crop(let style):
                try container.encode("crop", forKey: .type)
                try container.encode(style.rawValue, forKey: .style)

            case .superResolution(let scale):
                try container.encode("sr", forKey: .type)
                try container.encode(scale, forKey: .width)

            case .resize(let w, let h, let preserve):
                try container.encode("resize", forKey: .type)
                try container.encode(w, forKey: .width)
                try container.encode(h, forKey: .height)
                try container.encode(preserve, forKey: .preserve)

            case .denoise(let level):
                try container.encode("denoise", forKey: .type)
                try container.encode(level, forKey: .level)

            case .style(let style):
                try container.encode("style", forKey: .type)
                try container.encode(style.rawValue, forKey: .style)

            case .custom(let id, let params):
                try container.encode("custom", forKey: .type)
                try container.encode(id, forKey: .id)
                try container.encodeIfPresent(params, forKey: .params)

            case .none:
                try container.encode("none", forKey: .type)
            }
        }
    }

    // MARK: Decode AITransformation

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let caseName = try c.decode(CaseName.self, forKey: .caseName)

        switch caseName {

        case .backgroundRemoval:
            self = .backgroundRemoval

        case .enhanceScene:
            self = .enhanceScene

        case .autoContrast:
            self = .autoContrast

        case .autoWhiteBalance:
            self = .autoWhiteBalance

        case .autoExposure:
            self = .autoExposure

        case .cartoonize:
            self = .cartoonize

        case .depthEnhance:
            self = .depthEnhance

        case .autoEnhance:
            self = .autoEnhance

        case .contentAwareCrop:
            if case .crop(let style) = try c.decode(Payload.self, forKey: .payload) {
                self = .contentAwareCrop(style)
            } else {
                self = .contentAwareCrop(.centered)
            }

        case .superResolution:
            if case .superResolution(let s) = try c.decode(Payload.self, forKey: .payload) {
                self = .superResolution(scale: s)
            } else {
                self = .superResolution(scale: 2)
            }

        case .resize:
            if case .resize(let w, let h, let p) = try c.decode(Payload.self, forKey: .payload) {
                self = .resize(to: CGSize(width: w, height: h), preserveAspect: p)
            } else {
                self = .resize(to: CGSize(width: 100, height: 100), preserveAspect: true)
            }

        case .denoise:
            if case .denoise(let lvl) = try c.decode(Payload.self, forKey: .payload) {
                self = .denoise(level: lvl)
            } else {
                self = .denoise(level: 0.5)
            }

        case .styleTransfer:
            if case .style(let style) = try c.decode(Payload.self, forKey: .payload) {
                self = .styleTransfer(style: style)
            } else {
                self = .styleTransfer(style: .cinematic)
            }

        case .custom:
            if case .custom(let id, let params) = try c.decode(Payload.self, forKey: .payload) {
                self = .custom(id: id, params: params)
            } else {
                self = .custom(id: "custom", params: nil)
            }
        }
    }

    // MARK: Encode AITransformation

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)

        switch self {

        case .backgroundRemoval:
            try c.encode(CaseName.backgroundRemoval, forKey: .caseName)
            try c.encode(Payload.none, forKey: .payload)

        case .contentAwareCrop(let style):
            try c.encode(CaseName.contentAwareCrop, forKey: .caseName)
            try c.encode(Payload.crop(style: style), forKey: .payload)

        case .enhanceScene:
            try c.encode(CaseName.enhanceScene, forKey: .caseName)
            try c.encode(Payload.none, forKey: .payload)

        case .autoContrast:
            try c.encode(CaseName.autoContrast, forKey: .caseName)
            try c.encode(Payload.none, forKey: .payload)

        case .autoWhiteBalance:
            try c.encode(CaseName.autoWhiteBalance, forKey: .caseName)
            try c.encode(Payload.none, forKey: .payload)

        case .autoExposure:
            try c.encode(CaseName.autoExposure, forKey: .caseName)
            try c.encode(Payload.none, forKey: .payload)

        case .superResolution(let scale):
            try c.encode(CaseName.superResolution, forKey: .caseName)
            try c.encode(Payload.superResolution(scale: scale), forKey: .payload)

        case .resize(let size, let preserve):
            try c.encode(CaseName.resize, forKey: .caseName)
            try c.encode(Payload.resize(width: size.width, height: size.height, preserve: preserve), forKey: .payload)

        case .denoise(let level):
            try c.encode(CaseName.denoise, forKey: .caseName)
            try c.encode(Payload.denoise(level: level), forKey: .payload)

        case .styleTransfer(let style):
            try c.encode(CaseName.styleTransfer, forKey: .caseName)
            try c.encode(Payload.style(style: style), forKey: .payload)

        case .cartoonize:
            try c.encode(CaseName.cartoonize, forKey: .caseName)
            try c.encode(Payload.none, forKey: .payload)

        case .depthEnhance:
            try c.encode(CaseName.depthEnhance, forKey: .caseName)
            try c.encode(Payload.none, forKey: .payload)

        case .autoEnhance:
            try c.encode(CaseName.autoEnhance, forKey: .caseName)
            try c.encode(Payload.none, forKey: .payload)

        case .custom(let id, let params):
            try c.encode(CaseName.custom, forKey: .caseName)
            try c.encode(Payload.custom(id: id, params: params), forKey: .payload)
        }
    }
}

// MARK: - Image Quality

/// Preferred output quality hint for rendering and decoding.
public enum AIQuality: String, Sendable, Codable {

    /// Automatically adjusts quality based on content and context
    case adaptive

    /// High-quality output (preferred for detail screens)
    case high

    /// Lower quality for fast loading (thumbnails)
    case low

    /// Medium balance between quality and speed
    case medium

    /// Exact lossless mode (if format supports it)
    case lossless
}

// MARK: - Image Format

/// Target/expected output format for rendering or disk caching.
public enum AIImageFormat: String, Sendable, Codable {
    case auto
    case jpeg
    case png
    case webp
    case heic
    case avif
    case unknown
}

// MARK: - Image Category & Request Context

/// High-level semantic category for ML and prioritization.
public enum AIImageCategory: String, Sendable, Codable {
    case product, portrait, fashion, food, scene, text, art, unknown, people
}

/// Identifies where an image is being used in UI flow.
public enum AIRequestContext: String, Sendable, Codable {
    case prefetch, gallery, detail, background, normal, thumbnail, listItem
}

// MARK: - Priority

/// Load priority for image requests, mapped to Swift Concurrency priorities.
public enum AILoadPriority: String, Sendable, Codable {
    case low, normal, high
}

public extension AILoadPriority {
    /// Swift concurrency `TaskPriority` mapping.
    var taskPriority: TaskPriority {
        switch self {
        case .low: return .low
        case .normal: return .medium
        case .high: return .high
        }
    }
}

// MARK: - Cache Key (Critical for Caching System)

public extension AITransformation {

    /// Unique stable identifier used for caching transformation outputs.
    ///
    /// Example:
    /// ```
    /// .resize(to: CGSize(width: 300, height: 200), preserveAspect: true)
    /// → "resize:300x200_preserve=true"
    /// ```
    var cacheIdentifier: String {
        switch self {

        case .backgroundRemoval:
            return "bgremove"

        case .contentAwareCrop(let style):
            return "crop:\(style.rawValue)"

        case .enhanceScene:
            return "enhanceScene"

        case .autoContrast:
            return "autoContrast"

        case .autoWhiteBalance:
            return "autoWhiteBalance"

        case .autoExposure:
            return "autoExposure"

        case .superResolution(let scale):
            return "superRes:scale=\(scale)"

        case .resize(let size, let preserve):
            return "resize:\(Int(size.width))x\(Int(size.height))_preserve=\(preserve)"

        case .denoise(let level):
            return "denoise:level=\(level)"

        case .styleTransfer(let style):
            return "style:\(style.rawValue)"

        case .cartoonize:
            return "cartoonize"

        case .depthEnhance:
            return "depthEnhance"

        case .autoEnhance:
            return "autoEnhance"

        case .custom(let id, let params):
            let p = params?
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "&") ?? ""
            return "custom:\(id)?\(p)"
        }
    }
}

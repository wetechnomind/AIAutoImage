//
//  AIMetadataBox.swift
//  AIAutoImageCore
//
//  A lightweight Sendable wrapper used to safely transport arbitrary
//  metadata dictionaries across actor boundaries.
//
//  Because `[String: Any]` is not Sendable by default, this wrapper allows
//  metadata to be transferred between async contexts without compiler errors.
//  Use responsibly, and avoid passing large or UI-bound objects.
//

import Foundation

/// A Sendable-safe wrapper for arbitrary metadata dictionaries.
///
/// Swift concurrency prevents non-Sendable types—such as `[String: Any]`—
/// from crossing actor boundaries. `AIMetadataBox` provides a controlled,
/// opt-in way to transport such metadata.
///
/// ### Why `@unchecked Sendable`?
/// - The contents of `[String: Any]` cannot be guaranteed to be Sendable.
/// - We explicitly mark this wrapper as `@unchecked Sendable` because we,
///   the framework author, acknowledge this risk and take responsibility.
///
/// ### Recommended Usage
/// - Prefer storing only lightweight, value-like metadata inside the box.
/// - Avoid placing UIKit/AppKit/Core Graphics objects in the dictionary.
/// - Use primarily for analytics, debugging metadata, or small user info payloads.
///
/// ### Example:
/// ```swift
/// let box = AIMetadataBox(["EXIF": ["iso": 200, "exposure": 0.01]])
/// await AIAnalytics.shared.recordMetadata(for: url, metadata: box)
/// ```
///
/// - Note: This wrapper should only be used when strictly required.
///   For long-lived data transfer, consider defining a strongly typed,
///   Sendable struct instead.
public struct AIMetadataBox: @unchecked Sendable {

    /// The underlying metadata dictionary.
    ///
    /// Contents may be non-Sendable, so avoid storing large or
    /// thread-unsafe objects inside.
    public let value: [String: Any]

    /// Creates a metadata container.
    ///
    /// - Parameter value: Metadata dictionary to encapsulate.
    public init(_ value: [String: Any]) {
        self.value = value
    }
}

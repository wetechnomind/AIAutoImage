//
//  UIImageView+AI.swift
//  AIAutoImage
//

import UIKit
import ObjectiveC
import AIAutoImageCore

// MARK: - Concurrency-safe Associated Object Key

/// Internal associated-object storage keys used for extending `UIImageView`.
///
/// Keys are stored as stable, immutable pointers wrapped via `Unmanaged`,
/// making them safe for cross-actor usage while avoiding string lookups.
private enum AIAssociatedKeys {
    /// Tracks the currently requested URL for async loading.
    ///
    /// Used to prevent image mismatch during table/collection view cell reuse.
    @MainActor static let currentURL =
        Unmanaged.passUnretained("ai_current_url_key" as NSString).toOpaque()
}

public extension UIImageView {

    // MARK: - Current URL Tracking

    /// The last URL requested by this image view.
    ///
    /// Used to safely cancel previous tasks and prevent race conditions,
    /// especially during fast scrolling or cell reuse.
    ///
    /// - Important:
    ///   This value updates automatically when `ai_setImage(with:)` is called.
    var ai_currentURL: URL? {
        get {
            objc_getAssociatedObject(self, AIAssociatedKeys.currentURL) as? URL
        }
        set {
            objc_setAssociatedObject(
                self,
                AIAssociatedKeys.currentURL,
                newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    /// Manually sets the currently tracked URL.
    ///
    /// - Parameter url: URL to store, or `nil` to clear.
    ///
    /// Typically used internally by `ai_setImage`. You may call it manually
    /// if implementing custom loading flows.
    func ai_setCurrentURL(_ url: URL?) {
        ai_currentURL = url
    }

    // MARK: - Image Loading

    /// Asynchronously loads, AI-processes, and displays an image from a URL.
    ///
    /// This method:
    /// - Shows a placeholder immediately
    /// - Cancels any in-progress load for this view
    /// - Assigns the new URL for cell-reuse safety
    /// - Runs AIAutoImage’s ML pipeline in the background
    /// - Updates the image only if the request still matches the tracked URL
    ///
    /// - Parameters:
    ///   - url: Remote image URL to load.
    ///   - placeholder: A placeholder image displayed during loading.
    ///   - request: Optional `AIImageRequest` specifying custom ML transforms,
    ///              priority, caching rules, etc.
    ///
    /// ```swift
    /// // Simple usage
    /// imageView.ai_setImage(
    ///     with: product.imageURL,
    ///     placeholder: UIImage(named: "ph")
    /// )
    ///
    /// // Advanced usage with custom pipeline
    /// let req = AIImageRequest(url: url, transformations: [.autoEnhance, .superResolution()])
    /// imageView.ai_setImage(with: url, request: req)
    /// ```
    func ai_setImage(
        with url: URL,
        placeholder: UIImage? = nil,
        request: AIImageRequest? = nil
    ) {
        // Display placeholder
        if let ph = placeholder { self.image = ph }

        // Cancel any ongoing load tied to this view
        ai_cancelLoad()

        // Track URL for cell-reuse / async safety
        ai_setCurrentURL(url)

        // Build default request if none provided
        let req = request ?? AIImageRequest(url: url)

        // Perform async load
        Task { [weak self] in
            guard let self else { return }

            do {
                let image = try await AIAutoImage.shared.image(for: req)

                // Ensure URL hasn't changed (important for reusable cells)
                if self.ai_currentURL == url {
                    self.image = image
                }

            } catch {
                // Log error from correct actor
                await AILog.shared.error("ai_setImage failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Cancellation

    /// Cancels any active AI-powered image request associated with the view.
    ///
    /// Automatically invoked by `ai_setImage(with:)`, but can also be called manually
    /// during cell reuse or when removing the view from the hierarchy.
    ///
    /// ```
    /// override func prepareForReuse() {
    ///     super.prepareForReuse()
    ///     imageView.ai_cancelLoad()
    /// }
    /// ```
    func ai_cancelLoad() {
        if let url = ai_currentURL {
            AIAutoImage.shared.cancel(url)
        }
        ai_currentURL = nil
    }
}

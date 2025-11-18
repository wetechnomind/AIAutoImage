//
//  SwiftUI+AIImage.swift
//  AIAutoImage
//

import SwiftUI
import AIAutoImageCore

/// A SwiftUI view that asynchronously loads, processes, and displays an AI-enhanced image.
///
/// `AIImage` automatically:
/// - Downloads a remote image (with caching handled by AIAutoImage)
/// - Applies AI/ML transformations (Super-Resolution, Auto Enhance, Matting, etc.)
/// - Displays a custom placeholder during loading
/// - Provides automatic transition animation
/// - Generates AI-powered accessibility descriptions (if enabled)
///
/// This is the low-level version of the component used internally by `AIAsyncImage`.
///
/// - Note: This view is `@MainActor` safe — UI updates run on the main thread.
/// - Tip: Use with custom placeholders for skeleton, shimmer, or progressive previews.
public struct AIImage<Placeholder: View>: View {

    // MARK: - Stored Properties

    /// The image URL to load and process.
    private let url: URL

    /// The placeholder view displayed while the image loads.
    private let placeholder: Placeholder

    /// The view transition applied when the image appears.
    private var transition: AnyTransition = .opacity.animation(.easeIn(duration: 0.25))

    /// The fully processed AI-enhanced image once loaded.
    @State private var uiImage: UIImage?

    /// Loading state for triggering placeholder opacity behavior.
    @State private var isLoading = false

    /// Active asynchronous loading task. Used for cancellation.
    @State private var task: Task<Void, Never>?

    // MARK: - Initializers

    /// Creates an `AIImage` instance with a custom placeholder.
    ///
    /// - Parameters:
    ///   - url: The remote image resource URL.
    ///   - placeholder: A closure returning a SwiftUI view used while loading.
    public init(
        _ url: URL,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        self.url = url
        self.placeholder = placeholder()
    }

    /// Creates an `AIImage` without any placeholder.
    ///
    /// - Parameter url: The remote image URL.
    ///
    /// - Important: If no placeholder is provided, the view will be empty until the image loads.
    public init(_ url: URL) where Placeholder == EmptyView {
        self.url = url
        self.placeholder = EmptyView()
    }

    // MARK: - Body

    /// The visual hierarchy for the view, including:
    /// - Placeholder display
    /// - AI-enhanced loaded image
    /// - Accessibility metadata
    /// - Load/cancel lifecycle hooks
    public var body: some View {
        ZStack {
            if uiImage == nil {
                placeholder
                    .opacity(isLoading ? 0.5 : 1.0)
            }

            if let img = uiImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .transition(transition)
                    .accessibilityLabel(accessibilityDescription)
            }
        }
        .onAppear { loadOnAppear() }
        .onChange(of: url.absoluteString) { _ in loadOnAppear() }   // Ensures reload on URL change (iOS 14 safe)
        .onDisappear { cancelTask() }
    }

    // MARK: - View Lifecycle

    /// Triggers image loading when the view appears.
    ///
    /// Wrapped in a `Task` to allow for structured concurrency cancellation.
    private func loadOnAppear() {
        Task {
            await loadImage()
        }
    }

    // MARK: - Image Loading Logic

    /// Asynchronously loads and AI-processes the image.
    ///
    /// Steps:
    /// 1. Cancels any existing load task.
    /// 2. Starts a new Task using AIAutoImage’s async pipeline.
    /// 3. Updates UI on the main actor.
    /// 4. Logs failure using the async-safe AILog actor.
    ///
    /// This method is safe to call multiple times due to cancellation logic.
    private func loadImage() async {
        cancelTask()

        isLoading = true

        task = Task {
            defer { isLoading = false }

            do {
                /// Perform AI-enhanced processing (SuperRes, Enhance, Matting, etc.)
                let img = try await AIAutoImage.shared.image(for: url)

                if !Task.isCancelled {
                    await MainActor.run {
                        self.uiImage = img
                    }
                }

            } catch {
                // Log from any actor (AILog is an actor → requires await)
                await AILog.shared.error("AIImage load failed: \(error.localizedDescription)")

                // Reset UI safely
                await MainActor.run {
                    self.uiImage = nil
                }
            }
        }
    }

    /// Cancels the active loading task.
    ///
    /// This is important when:
    /// - Navigating away from the view
    /// - Replacing the URL source
    /// - Preventing wasted work during scroll performance
    private func cancelTask() {
        task?.cancel()
        task = nil
    }

    // MARK: - Accessibility

    /// AI-generated accessibility label for the loaded image.
    ///
    /// If `enableAIAccessibility` is enabled:
    /// - Uses AIAccessibility’s ML model to describe the image.
    ///
    /// Otherwise:
    /// - Defaults to `"image"`.
    private var accessibilityDescription: String {
        guard let img = uiImage else { return "image" }

        if AIImageConfig.shared.enableAIAccessibility {
            return AIAccessibility.shared.descriptionSync(for: img)
        }

        return "image"
    }
}

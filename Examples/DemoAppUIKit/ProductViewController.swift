//
//  ProductViewController.swift
//  AIAutoImageDemo
//

import UIKit
import AIAutoImage
internal import AIAutoImageCore

/// A view controller that displays a single AI-enhanced product image.
///
/// This screen performs high-quality image processing using AIAutoImage,
/// including:
/// - Super Resolution (upscaling via CoreML)
/// - Background Removal (ML Matting)
/// - Auto Enhancement (color, tone & contrast)
///
/// The result is presented full-screen with smooth scaling and resizing.
class ProductViewController: UIViewController {

    /// The remote image URL selected from the gallery.
    ///
    /// This value is passed during initialization and used by `loadImage()`
    /// to fetch, process, and display the enhanced image.
    let url: URL

    /// Initializes the product view with the selected image URL.
    ///
    /// - Parameter url: The remote URL of the image to display and enhance.
    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
    }

    /// Required initializer (unused for programmatic UI).
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The image view responsible for rendering the processed image.
    ///
    /// Configured for full-screen scaling and flexible layout on rotation.
    private let imageView = UIImageView()

    /// Called after the view has been loaded into memory.
    ///
    /// Sets up the UI, applies layout configuration, and triggers the
    /// asynchronous AI-enhanced image loading pipeline.
    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground
        title = "AI Enhanced"

        /// Configure the full-screen image view.
        imageView.frame = view.bounds
        imageView.contentMode = .scaleAspectFit
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        view.addSubview(imageView)

        /// Begin loading and processing the image.
        loadImage()
    }

    /// Loads and enhances the image using AIAutoImage's ML-powered transformations.
    ///
    /// This method performs:
    /// - **Super Resolution (2× upscale)** for sharper details.
    /// - **Background Removal** using ML matting.
    /// - **Auto Enhancement** for improved tone, contrast, and color balance.
    ///
    /// The resulting image is rendered asynchronously into the `imageView`.
    private func loadImage() {
        imageView.ai_setImage(
            url: url,

            /// Placeholder shown while downloading & processing.
            placeholder: UIImage(systemName: "photo"),

            /// Advanced image transformations.
            transformations: [
                .superResolution(scale: 2.0),  // ML-based upscaling
                .backgroundRemoval,            // Background segmentation
                .autoEnhance                   // Smart visual optimization
            ],

            /// Context hint: full-screen detail view.
            context: .detail
        )
    }
}

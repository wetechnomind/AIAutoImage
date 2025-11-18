//
//  ProductView.swift
//  AIAutoImageDemo
//

import SwiftUI
import AIAutoImage

/// A SwiftUI view that displays a single AI-enhanced product image.
///
/// This screen showcases advanced AIAutoImage transformations such as:
/// - Background removal (ML-based matting)
/// - Super resolution upscaling (CoreML 2× enhancement)
/// - Auto enhancement (tone, contrast, and color correction)
///
/// The result is rendered using `AIAsyncImage`, which automatically
/// handles downloading, caching, and applying ML transformations.
struct ProductView: View {

    /// The remote image URL selected from the gallery.
    ///
    /// This value is used by `AIAsyncImage` to fetch and process the image.
    let url: URL

    /// The main view hierarchy.
    ///
    /// Displays the enhanced product image with proper scaling, padding,
    /// and navigation handling.
    var body: some View {
        VStack {

            /// Loads and displays the image using AIAutoImage’s ML pipeline.
            AIAsyncImage(
                url: url,

                /// A progress indicator shown while the image is loading
                /// or being processed by the ML engine.
                placeholder: {
                    ProgressView().scaleEffect(1.4)
                },

                /// A set of advanced AI transformations applied sequentially.
                transformations: [

                    /// Removes background using semantic ML segmentation.
                    .backgroundRemoval,

                    /// Upscales the image to 2× resolution using CoreML super-resolution.
                    .superResolution(scale: 2.0),

                    /// Improves tone, contrast, clarity, and color balance.
                    .autoEnhance
                ],

                /// Context hint indicating this image is used in a detail view,
                /// allowing AIAutoImage to optimize quality and threading.
                context: .detail
            )
            .scaledToFit()               // Preserve the original aspect ratio
            .padding(.horizontal, 16)    // Add spacing from screen edges
        }
        .navigationTitle("Product")               // Title for navigation bar
        .navigationBarTitleDisplayMode(.inline)   // Keep title compact
    }
}

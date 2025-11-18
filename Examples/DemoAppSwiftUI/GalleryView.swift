//
//  GalleryView.swift
//  AIAutoImageDemo
//

import SwiftUI
import AIAutoImage

/// A SwiftUI view that displays a grid-based gallery of remote images.
///
/// Each image is processed using AIAutoImage with lightweight transformations,
/// and tapping an image navigates to a detailed product view.
/// The grid is rendered using a two-column flexible layout.
struct GalleryView: View {

    /// A collection of sample remote image URLs displayed in the gallery.
    ///
    /// These images demonstrate AIAutoImage’s capabilities for
    /// downloading, transforming, and rendering images efficiently.
    let urls = [
        URL(string: "https://picsum.photos/id/1011/800/800")!,
        URL(string: "https://picsum.photos/id/1015/800/800")!,
        URL(string: "https://picsum.photos/id/1021/800/800")!,
        URL(string: "https://picsum.photos/id/1031/800/800")!,
        URL(string: "https://picsum.photos/id/1043/800/800")!,
    ]

    /// The two-column grid layout configuration for the gallery.
    ///
    /// Using `.flexible()` ensures items resize proportionally
    /// to available horizontal space.
    private let columns = [
        GridItem(.flexible()),
        GridItem(.flexible())
    ]

    /// The main view hierarchy that contains the gallery UI.
    ///
    /// Includes:
    /// - A navigation container
    /// - A vertical scroll view
    /// - A lazy grid for efficient image rendering
    var body: some View {
        NavigationView {
            ScrollView {

                /// LazyVGrid efficiently loads each cell only when needed,
                /// improving memory use and scrolling performance.
                LazyVGrid(columns: columns, spacing: 12) {

                    ForEach(urls, id: \.self) { url in

                        /// A tappable navigation link leading to the product detail screen.
                        NavigationLink {
                            ProductView(url: url)
                        } label: {

                            /// Loads and displays the thumbnail using AIAutoImage.
                            AIAsyncImage(
                                url: url,

                                /// A placeholder while the image is loading or processing.
                                placeholder: {
                                    Color.gray.opacity(0.15)
                                        .frame(height: 200)
                                        .cornerRadius(12)
                                },

                                /// Lightweight transformations applied to grid thumbnails.
                                transformations: [
                                    .contentAwareCrop(.saliency),  // Smart subject-aware cropping
                                    .autoEnhance                    // Basic tone + color optimization
                                ],

                                /// Context hint indicating grid/list usage for optimization.
                                context: .listItem
                            )
                            .frame(height: 200)
                            .cornerRadius(12)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("AI Gallery")   // Navigation bar title
        }
    }
}

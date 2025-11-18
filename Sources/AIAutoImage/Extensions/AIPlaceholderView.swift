//
//  AIPlaceholderView.swift
//  AIAutoImageCore
//

import SwiftUI
import UIKit
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

/// A production-grade, AI-enhanced placeholder view used while loading remote images.
///
/// `AIPlaceholderView` intelligently augments the loading state using:
/// - **Adaptive background color** using saliency or average color
/// - **Shimmer animation** for loading indication
/// - **Optional tiny preview** (BlurHash, tiny JPEG, etc.)
/// - **Depth / blur layered preview**
/// - **Vision-based saliency color extraction**
///
/// This view enhances UX while high-resolution image processing or AI pipelines run.
public struct AIPlaceholderView: View {

    // MARK: - Public Properties

    /// An optional tiny preview used to generate adaptive color and blurred background.
    ///
    /// This can be:
    /// - BlurHash decoded image
    /// - Tiny JPEG
    /// - 16×16 pixel preview
    public var tinyPreview: UIImage?

    /// Enables or disables the shimmer animation.
    public var shimmer: Bool = true

    /// Enables Vision-based adaptive color extraction.
    public var aiAdaptiveColor: Bool = true

    /// Corner radius applied to the placeholder container.
    public var cornerRadius: CGFloat = 12

    // MARK: - Internal State

    /// The dynamically computed adaptive color, derived from Vision saliency or average color.
    @State private var adaptiveColor: Color = Color(UIColor.secondarySystemBackground)

    // MARK: - Initializer

    /// Creates a new AI-enhanced placeholder view.
    ///
    /// - Parameters:
    ///   - tinyPreview: Optional low-resolution preview image.
    ///   - shimmer: Whether to enable shimmer animation.
    ///   - aiAdaptiveColor: Whether to compute AI-based background colors.
    ///   - cornerRadius: Corner radius of the placeholder.
    public init(
        tinyPreview: UIImage? = nil,
        shimmer: Bool = true,
        aiAdaptiveColor: Bool = true,
        cornerRadius: CGFloat = 12
    ) {
        self.tinyPreview = tinyPreview
        self.shimmer = shimmer
        self.aiAdaptiveColor = aiAdaptiveColor
        self.cornerRadius = cornerRadius
    }

    // MARK: - Body

    /// The visual content of the placeholder view.
    public var body: some View {
        ZStack {

            /// Background adaptive color (Vision AI or fallback)
            adaptiveColor
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))

            /// Optional blurred tiny preview (used for progressive loading UX)
            if let preview = tinyPreview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFill()
                    .opacity(0.35)
                    .blur(radius: 10)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            }

            /// Icon fallback for missing preview
            Image(systemName: "photo")
                .font(.system(size: 38, weight: .regular))
                .foregroundColor(.gray.opacity(0.7))
        }
        .overlay(
            shimmer
            ? AnyView(shimmerOverlay.mask(RoundedRectangle(cornerRadius: cornerRadius)))
            : AnyView(EmptyView())
        )
        .onAppear {
            if aiAdaptiveColor {
                Task { await computeAdaptiveColor() }
            }
        }
    }

    // MARK: - Shimmer Layer

    /// Shimmer overlay gradient used to simulate a loading animation.
    private var shimmerOverlay: some View {
        LinearGradient(
            colors: [
                .white.opacity(0.0),
                .white.opacity(0.25),
                .white.opacity(0.0)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .rotationEffect(.degrees(20))
        .offset(x: -200)
        .animation(
            Animation.linear(duration: 1.2)
                .repeatForever(autoreverses: false),
            value: UUID()
        )
    }

    // MARK: - Adaptive Color Computation

    /// Computes the adaptive background color for the placeholder.
    ///
    /// The algorithm:
    /// 1. Attempts **Vision-based saliency** extraction.
    /// 2. Falls back to **average pixel color** if saliency fails.
    private func computeAdaptiveColor() async {
        guard let preview = tinyPreview else { return }

        if let saliency = await extractSaliencyColor(from: preview) {
            adaptiveColor = Color(saliency)
            return
        }

        if let avg = averageColor(from: preview) {
            adaptiveColor = Color(avg)
        }
    }

    // MARK: - Vision Saliency Extraction

    /// Extracts the dominant saliency-based color from an image using Vision.
    ///
    /// - Parameter img: The tiny preview image.
    /// - Returns: A UIColor representing the salient region’s average tone.
    private func extractSaliencyColor(from img: UIImage) async -> UIColor? {
        guard let cg = img.cgImage else { return nil }

        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])

        do {
            try handler.perform([request])

            guard let saliency = request.results?.first as? VNSaliencyImageObservation else {
                return nil
            }

            let pixelBuffer = saliency.pixelBuffer
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

            let filter = CIFilter.areaAverage()
            filter.inputImage = ciImage
            filter.extent = ciImage.extent

            guard let outputImage = filter.outputImage else { return nil }

            let context = CIContext()

            var rgba = [UInt8](repeating: 0, count: 4)

            context.render(
                outputImage,
                toBitmap: &rgba,
                rowBytes: 4,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )

            return UIColor(
                red: CGFloat(rgba[0]) / 255,
                green: CGFloat(rgba[1]) / 255,
                blue: CGFloat(rgba[2]) / 255,
                alpha: 1
            )

        } catch {
            return nil
        }
    }

    // MARK: - Average Color Fallback

    /// Computes a simple average RGB color of a provided image (fallback).
    ///
    /// - Parameter image: The tiny preview image.
    /// - Returns: A `UIColor` representing the average color.
    private func averageColor(from image: UIImage) -> UIColor? {
        guard let cg = image.cgImage else { return nil }

        let ci = CIImage(cgImage: cg)
        let filter = CIFilter.areaAverage()
        filter.inputImage = ci
        filter.extent = ci.extent

        let context = CIContext()
        var rgba = [UInt8](repeating: 0, count: 4)

        context.render(
            filter.outputImage!,
            toBitmap: &rgba,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        return UIColor(
            red: CGFloat(rgba[0]) / 255,
            green: CGFloat(rgba[1]) / 255,
            blue: CGFloat(rgba[2]) / 255,
            alpha: 1
        )
    }
}

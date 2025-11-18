//
//  AIAsyncImage.swift
//

import SwiftUI
import AIAutoImageCore
import AIAutoImage

public struct AIAsyncImage<Placeholder: View>: View {

    private let url: URL
    private let transformations: [AITransformation]
    private let context: AIRequestContext
    private let placeholder: Placeholder

    @State private var uiImage: UIImage?
    @State private var isLoading = false
    @State private var task: Task<Void, Never>?

    public init(
        url: URL,
        transformations: [AITransformation] = [],
        context: AIRequestContext = .normal,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        self.url = url
        self.transformations = transformations
        self.context = context
        self.placeholder = placeholder()
    }

    public var body: some View {
        ZStack {
            if uiImage == nil {
                placeholder.opacity(isLoading ? 0.5 : 1)
            }

            if let image = uiImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .transition(.opacity.animation(.easeIn(duration: 0.25)))
            }
        }
        .onAppear { load() }
        .onDisappear { cancel() }
        .onChange(of: url.absoluteString) { _ in load() }
    }

    private func load() {
        cancel()
        isLoading = true

        task = Task {
            do {
                /// Build a request using your updated API
                let request = AIImageRequest(
                    url: url,
                    transformations: transformations,
                    context: context
                )

                let img = try await AIAutoImage.shared.image(for: request)

                if !Task.isCancelled {
                    await MainActor.run { self.uiImage = img }
                }

            } catch {
                await AILog.shared.error("AIAsyncImage error: \(error.localizedDescription)")
            }

            await MainActor.run { isLoading = false }
        }
    }

    private func cancel() {
        task?.cancel()
        task = nil
    }
}

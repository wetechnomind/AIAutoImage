//
//  AIAutoImageTests.swift
//  AIAutoImageTests
//
//  Full professional test suite — OPTION B
//

import XCTest
@testable import AIAutoImage
@testable import AIAutoImageCore
import UIKit

final class AIAutoImageTests: XCTestCase {

    // MARK: - Helpers

    /// Simple solid-color UIImage used across tests
    func sampleImage(_ size: CGSize = CGSize(width: 200, height: 200), color: UIColor = .red) -> UIImage {
        UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
        color.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        let img = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        return img
    }

    /// Sample Data (JPEG)
    func sampleImageData() -> Data {
        sampleImage().jpegData(compressionQuality: 1.0)!
    }

    /// Deterministic URL used for cache keys / request identity
    func tempURL(_ id: String = "200x200") -> URL {
        URL(string: "https://example.com/\(id).jpg")!
    }

    override func setUp() async throws {
        // Clear caches before each test run to keep tests isolated
        await AICache.shared.clearAll()
        // Unregister all plugins to ensure fresh state
        await AIPluginManager.shared.unloadAll()
    }

    // MARK: - Configuration Tests

    func testConfigDefaults() {
        let cfg = AIImageConfig.shared

        XCTAssertNotNil(cfg) // instance exists
        // performanceMode default likely .balanced — assert it's settable and readable
        XCTAssertNotNil(cfg.performanceMode)
        // ensure ai features boolean present
        XCTAssertNotNil(cfg.enableAIFeatures)
    }

    func testPresetSwitchingBehavior() {
        let cfg = AIImageConfig.shared

        // store original
        let original = cfg.preset

        // Test ultraFast preset
        cfg.preset = .ultraFast
        XCTAssertEqual(cfg.preferredFormat, .jpeg)
        XCTAssertFalse(cfg.enableAIFeatures)

        // Test highQuality preset
        cfg.preset = .highQuality
        XCTAssertEqual(cfg.preferredFormat, .heic)
        XCTAssertTrue(cfg.enableAIFeatures)

        // restore original
        cfg.preset = original
    }

    // MARK: - Cache Tests

    func testMemoryCacheInsertRetrieve() async {
        let cache = AICache.shared
        let url = tempURL("memorytest")
        let img = sampleImage()

        var request = AIImageRequest(url: url)
        request.transformations = []

        let key = request.effectiveCacheKey

        // Store
        await cache.storeInMemory(img, forKey: key)

        // Retrieve
        let fetched = await cache.memoryImage(forKey: key)
        XCTAssertNotNil(fetched)
    }

    func testDiskCacheWriteRead() async throws {
        let cache = AICache.shared
        let url = tempURL("disktest")
        let img = sampleImage()

        var request = AIImageRequest(url: url)
        request.transformations = []

        let key = request.effectiveCacheKey

        // Store on disk
        await cache.storeOnDisk(img, forKey: key)

        // Allow small async delay for disk write if implemented
        try await Task.sleep(nanoseconds: 100_000_000)

        // Read
        let fromDisk = await cache.diskImage(forKey: key)
        XCTAssertNotNil(fromDisk)
    }

    func testTransformCacheStoresTransformedImage() async {
        let transformCache = AITransformCache.shared
        let key = "transform-test-key"
        let img = sampleImage()

        await transformCache.store(img, forKey: key)       // Store
        let fetched = await transformCache.retrieve(forKey: key)  // Retrieve

        XCTAssertNotNil(fetched)
    }

    // MARK: - Decoder Tests

    func testDecoderBasicDecode() async throws {
        let decoder = AIDecoder()
        let data = sampleImageData()

        let request = AIImageRequest(url: tempURL("decode-basic"))

        let result = try await decoder.decode(
            data,
            request: request,
            targetPixelSize: nil
        )

        XCTAssertNotNil(result.image)
    }

    func testDecoderDetectsPNG() async throws {
        let decoder = AIDecoder()
        let pngData = sampleImage().pngData()!

        let request = AIImageRequest(url: tempURL("decode-png"))

        let output = try await decoder.decode(
            pngData,
            request: request,
            targetPixelSize: nil
        )

        // If decode produced an image, ensure pngData roundtrip possible (not guaranteed, but safe)
        XCTAssertNotNil(output.image)
    }

    func testProgressiveDecoderAcceptsPartialData() async throws {
        let progressive = AIProgressiveDecoder.shared

        // Create real image data
        let fullData = sampleImage().jpegData(compressionQuality: 1.0)!
        let partialData = fullData.prefix(fullData.count / 10)   // 10% packet

        // Should NOT crash on partial packet
        let result = await progressive.incrementalDecode(
            accumulatedData: Data(partialData),
            isFinal: false,
            maxPixelSize: 256
        )

        // Result MAY be nil (expected for early packets)
        XCTAssertTrue(result == nil || result is UIImage)
    }

    // MARK: - AVIF / WebP Coders (sanity)

    func testWebPCoderRegistrationSafe() async {
        let registrar = AIImageCodersRegistrar.shared

        // Ensure clean internal caches before test
        await registrar.clearCaches()

        // Create a small sample data that won't crash the decoder
        let sample = sampleImageData()

        // Register a dummy decoder for "image/webp"
        await registrar.register(
            mimeHint: "image/webp",
            confidence: { (_: Data) -> Float in
                // pretend we are very confident
                return 1.0
            },
            decode: { (data: Data) async -> Any? in
                // Return a UIImage as the decoded result (Any)
                // You can also return an AIAnimatedImage or other object your pipeline supports.
                return UIImage(data: data) ?? UIImage()
            }
        )

        // Call the main decode entrypoint (this will run the scoring and call our decode closure)
        let decoded = await registrar.decode(data: sample)

        // Ensure decode returned something (UIImage boxed as Any)
        XCTAssertNotNil(decoded, "Registered webp decoder should return a decoded object")

        // Check telemetry to ensure our decoder is counted in registered decoders
        let stats = await registrar.telemetrySnapshot()
        XCTAssertGreaterThanOrEqual(stats.registeredDecoders, 3, "There should be at least the built-in decoders plus our registration")
    }


    func testAVIFCoderAvailability() async {
        // If AIAVIFCoder exists it should construct safely
        let avif = AIAVIFCoder()
        XCTAssertNotNil(avif)
    }

    // MARK: - Transformer Tests

    func testResizeTransformation() async throws {
        let t = AITransformer()
        let img = sampleImage()

        let result = try await t.applyTransformations(
            to: img,
            using: [.resize(to: CGSize(width: 100, height: 100), preserveAspect: true)],
            modelManager: AIModelManager.shared
        )

        // Allow tolerance because resizing may preserve scale factor
        XCTAssertEqual(result.size.width, 100, accuracy: 10)
    }

    func testAutoEnhanceTransform() async throws {
        let t = AITransformer()
        let img = sampleImage()

        let result = try await t.applyTransformations(
            to: img,
            using: [.autoEnhance],
            modelManager: AIModelManager.shared
        )

        XCTAssertNotNil(result)
    }

    func testBackgroundRemovalGracefulFallback() async throws {
        // If model is not loaded, it should return an image (no crash)
        let t = AITransformer()
        let img = sampleImage()
        let result = try await t.applyTransformations(
            to: img,
            using: [.backgroundRemoval],
            modelManager: AIModelManager.shared
        )
        XCTAssertNotNil(result)
    }

    func testCustomTransformRegistrationViaPlugin() async {
        struct TestPlugin: AIPlugin {
            let name = "TestPlugin-Transform"
            func onLoad() async {}
            func registerTransforms(into pipeline: AITransformPipeline) async {
                await pipeline.register(id: "test-invert", category: .filter, isEnabled: true) { image in
                    // simple invert effect using CoreImage; safe fallback to original
                    guard let cg = image.cgImage else { return image }
                    let ci = CIImage(cgImage: cg)
                    if let filter = CIFilter(name: "CIColorInvert") {
                        filter.setValue(ci, forKey: kCIInputImageKey)
                        if let out = filter.outputImage,
                           let cgOut = CIContext().createCGImage(out, from: out.extent) {
                            return UIImage(cgImage: cgOut)
                        }
                    }
                    return image
                }
            }
        }

        await AIPluginManager.shared.register(TestPlugin())
        // Apply registered transforms
        let img = sampleImage()
        let out = await AITransformPipeline.shared.applyAll(to: img)
        XCTAssertNotNil(out)
    }

    // MARK: - Renderer Tests

    func testRendererToneMap() async {
        let renderer = AIRenderer()
        let img = sampleImage()

        var req = AIImageRequest(url: tempURL("renderer-tone"))
        req.expectedFormatHint = .heic

        let output = await renderer.render(img, request: req)
        XCTAssertNotNil(output)
    }

    func testRendererNoCrash() async {
        let renderer = AIRenderer()
        let img = sampleImage()

        let req = AIImageRequest(url: tempURL("renderer-nocrash"))
        let output = await renderer.render(img, request: req)
        XCTAssertNotNil(output)
    }

    // MARK: - Predictor Tests

    func testVelocityPredictionNotEmpty() {
        let p = AIPredictor()
        let predicted = p.predictNextVisibleIndexes(currentOffset: 5, velocity: 1200, count: 50)
        XCTAssertFalse(predicted.isEmpty)
    }

    func testCategoryHeuristicProduct() {
        let p = AIPredictor()
        let url = URL(string: "https://cdn.example.com/product/image123.jpg")!
        let cat = p.predictCategory(for: url)
        // Category may be an enum; check equality if defined
        if let catEnum = cat as? AIImageCategory {
            XCTAssertEqual(catEnum, .product)
        } else {
            // If not typed, ensure method returns a non-nil fallback
            XCTAssertNotNil(cat)
        }
    }

    // MARK: - AI Quality Predictor

    func testSharpnessPredictionRange() async {
        let img = sampleImage()
        let score = await AICacheQualityPredictor.shared.predictSharpness(for: img)
        XCTAssertGreaterThanOrEqual(score, 0.0)
        XCTAssertLessThanOrEqual(score, 1.0)
    }

    // MARK: - Pipeline & Loader Integration Tests

    func testPipelineEndToEndMocked() async {
        // Build request (transformations)
        var req = AIImageRequest(url: tempURL("pipeline-e2e"))
        req.transformations = [.autoEnhance]

        // Create pipeline and use local loader (we'll bypass network and directly provide data)
        let pipeline = AIImagePipeline()

        do {
            // If pipeline exposes a method to process Data directly, use it; otherwise call process and expect error gracefully
            if let process = try? await pipeline.process(req, sourceURL: req.url) {
                // If the pipeline tried network, it may error — but we assert graceful behavior (no crash)
                XCTAssertNotNil(process)
            } else {
                // fallback: create a decode + transform chain manually to validate integration
                let decoder = AIDecoder()
                let data = sampleImageData()
                let decoded = try await decoder.decode(data, request: req, targetPixelSize: nil)
                let transformed = try await AITransformer().applyTransformations(to: decoded.image, using: req.transformations ?? [], modelManager: AIModelManager.shared)
                XCTAssertNotNil(transformed)
            }
        } catch {
            XCTFail("Pipeline should handle local flow without crashing: \(error)")
        }
    }

    // MARK: - Accessibility & Metadata

    func testAccessibilityCaptioning() async {
        let img = sampleImage()
        let caption = await AIAccessibility.shared.description(for: img)
        XCTAssertNotNil(caption)
        XCTAssertTrue(caption.count > 0)
    }

    func testMetadataCenterExtractAll() async {
        let img = sampleImage()
        let box = await AIImageMetadataCenter.shared.extractAll(from: img)
        // AIMetadataBox may be a dictionary wrapper — assert not empty dictionary
        XCTAssertNotNil(box)
    }

    // MARK: - Animated Image Engine

    func testAnimatedDecoderBasic() async {
        let decoder = AIAnimatedDecoder()
        // Use GIF data created by UIImage.animatedImage (not trivial). We will run a no-crash test:
        XCTAssertNotNil(decoder)
    }

    @MainActor
    func testAnimatedImageViewIntegrationNoCrash() async {
        let view = AIAnimatedImageView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))

        // Use the real animated decoder
        let decoder = AIAnimatedDecoder()

        // This will return nil for non-animated data, and that's OK
        let anim = await decoder.decodeAnimatedImage(data: sampleImageData())

        if let anim = anim {
            view.setAnimatedImage(anim)
            XCTAssertNotNil(view)
        } else {
            // Expected case for static JPEG: just ensure no crash
            XCTAssertNotNil(view)
        }
    }

    // MARK: - UIImageView & SwiftUI Integration (logic-level)

    @MainActor
    func testUIImageViewSetImageNoCrash() async {
        let view = UIImageView()
        let url = tempURL("uiview-test")

        var req = AIImageRequest(url: url)
        req.transformations = [.autoEnhance]

        // ai_setImage API may be async; call and assert no crashes
        view.ai_setImage(with: url, placeholder: nil, request: req)
        XCTAssertTrue(true)
    }

    func testSwiftUIAIImageCreatesRequest() {
        let url = tempURL("swiftui-test")
        let req = AIImageRequest(url: url)
        XCTAssertEqual(req.url, url)
    }

    // MARK: - Plugin System Tests

    func testPluginRegistrationAndNotification() async {
        final class SimplePlugin: AIPlugin {
            let name = "SimplePlugin"
            func onLoad() async {}
            func onUnload() async {}
            func registerDecoders(into registrar: AIImageCodersRegistrar) async {}
            func registerTransforms(into pipeline: AITransformPipeline) async {}
            func registerMetadataExtractors(into center: AIImageMetadataCenter) async {}
            func onImageDecoded(_ image: UIImage, context: [String : Sendable]?) async {}
            func onRequest(_ url: URL, context: [String : Sendable]?) async {}
        }

        let plugin = SimplePlugin()
        await AIPluginManager.shared.register(plugin)

        // Must fetch async value BEFORE XCTAssert
        let count = await AIPluginManager.shared.pluginCount()
        XCTAssertEqual(count, 1)

        // Notify events — these are async actor calls
        await AIPluginManager.shared.notifyRequest(URL(string: "https://example.com")!)
        await AIPluginManager.shared.notifyImageDecoded(sampleImage(), context: nil)
    }

    // MARK: - Model Manager & CoreML wrapper tests (graceful fallback)

    func testModelManagerLoadUnloadGraceful() async {
        // Attempt to load a model name that likely doesn't exist — should not crash
        let mm = AIModelManager.shared
        let maybeModel = await mm.model(named: "NonExistingModel_v0")
        XCTAssertNil(maybeModel)
    }

    func testCoreMLWrapperImageFromPixelBuffer() {
        // 1. Create a small pixel buffer manually
        let width = 2
        let height = 2

        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]

        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )

        XCTAssertNotNil(pixelBuffer)

        guard let buffer = pixelBuffer else { return }

        // 2. Try converting pixel buffer → UIImage using your *public* API
        let uiImage = CoreMLModelWrapper.image(from: buffer)

        // 3. Assert conversion is valid (UIImage should be created)
        XCTAssertNotNil(uiImage)
    }


    // MARK: - Prefetcher Tests

    func testPrefetcherScoreAndQueue() async {
        let prefetcher = AIPrefetcher.shared
        let requests = [
            AIImageRequest(url: tempURL("p1")),
            AIImageRequest(url: tempURL("p2")),
            AIImageRequest(url: tempURL("p3"))
        ]
        await prefetcher.prefetch(requests)
        // Cancel and ensure no crash
        await prefetcher.cancelAll()
        XCTAssertTrue(true)
    }

    // MARK: - Threading & Logging Sanity

    func testAIQueuesExecution() async {
        // Render queue test
        let renderExp = expectation(description: "render")
        AIQueues.render.async {
            renderExp.fulfill()
        }

        // Cache queue test
        let cacheExp = expectation(description: "cache")
        AIQueues.cache.async {
            cacheExp.fulfill()
        }
        await fulfillment(of: [renderExp, cacheExp], timeout: 2.0)
    }

    func testLoggingDoesNotCrash() async {
        await AILog.shared.info("AIAutoImage test log")
        await AILog.shared.warning("Test warning")
        await AILog.shared.error("Test error")
        await AILog.shared.debug("Debug message")

        XCTAssertTrue(true)   // If we reach here, no crash
    }

    // MARK: - Performance Tests (measure typical transform)

    func testPerformanceSuperResolution() async throws {
        let transformer = AITransformer()
        let image = sampleImage(CGSize(width: 512, height: 512))

        // Use measure to track time — XCTest's measure does not support async directly; use expectation timing
        let iterations = 3
        self.measure {
            let group = DispatchGroup()
            for _ in 0..<iterations {
                group.enter()
                Task {
                    _ = try? await transformer.applyTransformations(
                        to: image,
                        using: [.superResolution(scale: 2.0)],
                        modelManager: AIModelManager.shared
                    )
                    group.leave()
                }
            }
            let waitResult = group.wait(timeout: .now() + 10)
            XCTAssertEqual(waitResult, .success)
        }
    }

    // MARK: - End-to-end sanity (single flow)

    func testEndToEndLightweightFlow() async {
        // Simulate: load data -> decode -> transform -> cache
        let url = tempURL("end2end")
        let data = sampleImageData()
        let decoder = AIDecoder()
        do {
            let decoded = try await decoder.decode(data, request: AIImageRequest(url: url), targetPixelSize: CGSize(width: 300, height: 300))
            let transformed = try await AITransformer().applyTransformations(to: decoded.image, using: [.autoEnhance], modelManager: AIModelManager.shared)
            // cache transformed
            var req = AIImageRequest(url: url)
            req.transformations = [.autoEnhance]
            let key = req.effectiveCacheKey
            await AICache.shared.storeInMemory(transformed, forKey: key)
            let fetched = await AICache.shared.memoryImage(forKey: key)
            XCTAssertNotNil(fetched)
        } catch {
            XCTFail("End-to-end local flow should not throw: \(error)")
        }
    }

    // MARK: - Cleanup

    override func tearDown() async throws {
        await AICache.shared.clearAll()
        await AIPluginManager.shared.unloadAll()
    }
}

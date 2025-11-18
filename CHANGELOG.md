# AIAutoImage — Changelog
All notable changes to **AIAutoImage** will be documented in this file.

This project follows **Semantic Versioning (SemVer)**  
and the **Keep a Changelog** format.

---

## [1.0.0] - 2025-11-18
### First Public Release — Full AI-Powered Image Pipeline
The initial stable release of **AIAutoImage**, featuring a complete 46-file modular architecture including decoders, pipeline, AI transforms, metadata engine, animation engine, cache system, plugins, and more.

---

## Core Features
### Core System
- Introduced `AIAutoImageManager` — global orchestrator for the entire pipeline.
- Added `AIImageConfig` for global performance settings.
- Added `AIImageVariant` system for thumbnail/medium/full variants.

---

## Networking Layer
- Added `AINetwork` with async/await support.
- Added `AIRetryPolicy` with adaptive retry logic.
- Added `AIPrefetcher` with **ML-powered priority queue**.

---

## Image Pipeline
- Added `AIImagePipeline` (primary loader → decoder → transform → caching).
- Added `AIImageRequest` with quality, priority, cache options.
- Added `AILoader` for network loading + streaming.

---

## Decoding System
- Added `AIDecoder` (JPEG, PNG, HEIC, TIFF, BMP).
- Added `AIProgressiveDecoder` for progressive JPEG/HEIC.
- Added `AIWebPCoder` (WebP decode).
- Added `AIAVIFCoder` (AVIF decode).
- Added `AIAnimatedDecoder` (GIF, APNG, animated HEIC).
- Added `AIImageCodersRegistrar` for registering custom decoders.

---

## Performance & Cache Layer
- Added `AICache` — hybrid memory/disk cache with async actors.
- Added `AIDiskManifest` for crash-safe disk index.
- Added `AITransformCache` for caching ML transforms.
- Added `AICacheQualityPredictor` for AI-driven quality scoring.

---

## AI / CoreML Layer
- Added `AIModelManager` — CoreML loader with memory trimming.
- Added `CoreMLModelWrapper` — unified wrapper for ML models.
- Added `AIPredictor` — saliency, sharpness & metadata predictions.
- Added `AIModel` protocol for custom ML models.

---

## Transform Engine
- Added `AITransformer` — main transform API.
- Added `AITransformPipeline` — priority-ordered transform chain.
- Added transforms:
  - Super Resolution  
  - Auto Enhance  
  - Denoise  
  - Cartoonize  
  - Background Removal  
  - Style Transfer  
  - Content-Aware Crop  
  - Depth Enhance
- Added `AIRenderer` for CI/Vision/ML rendering operations.
- Added `TransformTypes` to unify transform identifiers.

---

## Metadata System
- Added `AIImageMetadataCenter` — unified metadata provider.
- Added `AIMetadataBox` — container for extracted metadata.
- Added `AIAccessibility` — color/contrast information.

Metadata extraction includes:
- Vision saliency maps  
- Sharpness  
- Face rectangles  
- Scene classification  
- EXIF fields  
- Colors & brightness  

---

## Animated Engine
- Added `AIAnimatedImage` model.
- Added `AIAnimatedImageView` (120 FPS CADisplayLink).
- Added features:
  - AI frame timing
  - AI frame skipping
  - Best-frame scoring
  - GPU warm-up
  - Perfect GIF/APNG/HEIC playback

---

## UIKit / SwiftUI Extensions
- Added `UIImage+AI` extension for transforms.
- Added `UIImageView+AI` async loader.
- Added `SwiftUI+AIImage` for native SwiftUI support.
- Added `AIPlaceholderView` for placeholders and fallback rendering.

---

## Plugin Architecture
- Added `AIPlugin` protocol for:
  - Custom decoders  
  - Custom transforms  
  - Metadata extractors  
  - Event hooks
- Added `AIPluginManager` for plugin registration.

---

## Utility Layer
- Added `AIThread` — async queue management.
- Added `Logging` — unified structured logging.

---

## Internal Improvements
- Actor-isolated pipeline for thread safety.
- Memory trimming for huge images.
- Improved multithread decoding performance.
- CoreML warm-up for faster first-run times.

---

## Documentation
- Added Quick Start guide.
- Added examples for SwiftUI & UIKit.
- Added plugin examples.
- Added metadata and transform examples.

---

## Roadmap (Coming Soon)
- macOS & visionOS support  
- tvOS support  
- OFFLINE CoreML transform packs  
- Realtime video frame transforms  
- Histogram-based smart cropping  
- ML-based color grading  
- Documentation website (GitHub Pages)  
- Benchmark suite  

---

## [Unreleased]
- Planned improvements and contributions will appear here.

---

## Contributors
- [Dhiiren Bharadava](https://github.com/dhiiren)
- [WeTechnoMind](https://www.wetechnomind.com)

---


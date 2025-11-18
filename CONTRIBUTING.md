# Contributing to AIAutoImage

Thank you for your interest in contributing to **AIAutoImage** — a next-generation AI-powered image pipeline for Swift 6.  
We welcome all contributions, including bug fixes, new features, documentation improvements, tests, and performance enhancements.

This document explains how to contribute effectively and consistently.

---

## Table of Contents
- [Code of Conduct](#code-of-conduct)
- [How to Contribute](#how-to-contribute)
- [Development Setup](#development-setup)
- [Project Structure](#project-structure)
- [Pull Request Guidelines](#pull-request-guidelines)
- [Coding Standards](#coding-standards)
- [Writing Tests](#writing-tests)
- [Reporting Issues](#reporting-issues)
- [Feature Requests](#feature-requests)
- [Plugin Contributions](#plugin-contributions)
- [License](#license)

---

## Code of Conduct
By participating in this project, you agree to uphold our community values of:
- Respect  
- Transparency  
- Constructive feedback  
- Inclusivity  

Be kind, collaborative, and helpful.

---

## How to Contribute

1. **Fork** the repository  
2. **Create** a feature branch  
3. **Commit** your changes  
4. **Open a Pull Request (PR)**  
5. Make sure your PR:
   - Builds successfully
   - Follows coding guidelines
   - Includes tests (if applicable)
   - Passes linters/formatters

Example:

```
git checkout -b feature/my-awesome-feature
git commit -m "Add new AI transform"
git push origin feature/my-awesome-feature
```

---

## Development Setup

AIAutoImage requires:

- Xcode 16+
- Swift 6+
- iOS 15+ SDK
- macOS 13+ (for development)
- Command line tools installed

Clone the repo:

```
git clone https://github.com/yourname/AIAutoImage.git
```

Open in Xcode:

```
xed AIAutoImage
```

Or build with SwiftPM:

```
swift build
```

---

## Project Structure

AIAutoImage is organized into 46 files across key components:

### Core  
`AIAutoImage.swift`, `AIAutoImageManager.swift`, `AIImageConfig.swift`

### Pipeline  
`AIImagePipeline.swift`, `AIImageRequest.swift`, `AILoader.swift`

### Decoding  
`AIDecoder.swift`, `AIProgressiveDecoder.swift`, `AIAVIFCoder.swift`, `AIWebPCoder.swift`, `AIAnimatedDecoder.swift`

### Caching  
`AICache.swift`, `AIDiskManifest.swift`, `AITransformCache.swift`, `AICacheQualityPredictor.swift`

### AI / ML  
`AIModelManager.swift`, `AIPredictor.swift`, `CoreMLModelWrapper.swift`

### Transform Engine  
`AITransformer.swift`, `AITransformPipeline.swift`, `AIRenderer.swift`, `TransformTypes.swift`

### Metadata  
`AIImageMetadataCenter.swift`, `AIMetadataBox.swift`, `AIAccessibility.swift`

### Animation  
`AIAnimatedImage.swift`, `AIAnimatedImageView.swift`

### Extensions  
`UIImageView+AI.swift`, `UIImage+AI.swift`, `SwiftUI+AIImage.swift`, `AIPlaceholderView.swift`

### Plugins  
`AIPlugin.swift`, `AIPluginManager.swift`

### Utilities  
`AIThread.swift`, `Logging.swift`

Understanding this structure will help you contribute efficiently.

---

## Writing Tests

We encourage contributors to add or update tests related to their changes.

### What to test:
- Decoders (WebP, AVIF, GIF/APNG)
- AI transformations (super-resolution, enhance, denoise)
- Metadata extraction (saliency, sharpness, EXIF)
- Animation engine
- Cache system behavior
- Pipeline flow
- Plugin registration

Run tests using:

```
swift test
```

---

## Reporting Issues

Before submitting an issue:

1. Search existing issues  
2. Include steps to reproduce  
3. Include sample code  
4. Include system info: Xcode version, Swift version, iOS version

Please be clear and detailed — it helps resolve issues faster.

---

## Feature Requests

We welcome feature ideas!  
Good proposals include:

- Why the feature is needed  
- Real use cases  
- API design ideas  
- Benchmark or performance benefits  

Open a new issue labeled **Feature Request**.

---

## Plugin Contributions

AIAutoImage has a powerful plugin system.  
You can contribute:

- Custom decoders  
- Custom AI transforms  
- Metadata extractors  
- Event observers  
- Debugging plugins  

Plugins must follow:
- Async-safe design  
- Sendable requirements  
- Memory-efficient architecture  

---

## Pull Request Guidelines

A good PR should:

- Be focused (one feature/fix)
- Include a clear description
- Include tests (if possible)
- Follow project coding style
- Avoid unnecessary file changes
- Pass CI checks

Large PRs may be asked to split into smaller atomic pieces.

---

## Coding Standards

AIAutoImage follows:

- Swift 6 async/await conventions  
- Actor-isolated concurrency  
- “Prefer value types over classes”  
- No force-unwrapping unless safe  
- Extensions grouped by function  
- Document complex functions  
- Public API must include doc comments  

Formatting:

- 4-space indentation  
- 120-character line width preferred  
- One empty line between logical blocks  

---

## License

By contributing, you agree your contributions will be licensed under the **MIT License**, the same license as AIAutoImage.

---

## Thank You

Your contributions help make AIAutoImage the most advanced AI-driven image pipeline for iOS.

Let's build something amazing together. 
— **Dhiiren & WeTechnoMind**

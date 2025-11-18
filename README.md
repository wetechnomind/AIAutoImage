
<img width="1366" height="524" alt="img new" src="https://github.com/user-attachments/assets/cf122e76-3e7c-4931-8249-5bcf990fba39" />

# AIAutoImage — The Next-Gen AI Image Pipeline for iOS

![AIAutoImage](https://img.shields.io/badge/AIAutoImage-Next--Gen%20AI%20Image%20Pipeline%20for%20iOS-red)
![Swift 6](https://img.shields.io/badge/Swift-6.0-orange?style=flat-square)
![SPM Release](https://img.shields.io/github/v/release/Dhiiren/AIAutoImage?label=SPM&color=blue&style=flat-square)
![Platform iOS](https://img.shields.io/badge/platform-iOS%2015%2B-blue?style=flat-square)
![License](https://img.shields.io/badge/License-MIT-green.svg)
![Swift Package Manager](https://img.shields.io/badge/Swift%20Package%20Manager-compatible-orange?logo=swift)
![AI Powered](https://img.shields.io/badge/AI-Powered-red?style=flat-square)
![CoreML Supported](https://img.shields.io/badge/CoreML-supported-green?style=flat-square)
![Vision Supported](https://img.shields.io/badge/Vision-supported-green?style=flat-square)
![Image Formats](https://img.shields.io/badge/formats-JPEG%20%7C%20PNG%20%7C%20WEBP%20%7C%20AVIF-orange?style=flat-square)
![Animated Engine](https://img.shields.io/badge/Animated-GIF%20%7C%20APNG%20%7C%20HEIC-purple?style=flat-square)
![Plugins Supported](https://img.shields.io/badge/Plugins-supported-yellow?style=flat-square)
![Progressive Decoding](https://img.shields.io/badge/Progressive-Decoding-blueviolet?style=flat-square)

— with CoreML transforms, Vision-based metadata, progressive decoding, animated image engine, plugin system, and high-performance cache.

## Features 

| Category | Premium Capabilities |
|----------|-----------------------|
| **AI Intelligence** | • Smart Saliency Detection<br>• CoreML Sharpness AI<br>• Scene & Content Classification<br>• Automatic Image Variant Selection (thumb → full)<br>• Intelligent Prefetching (ML-based)<br>• AI-Optimized Progressive Decoding<br>• AI-Ranked Hybrid Caching |
| **Next-Gen Image Transformations** | • Super Resolution (ML Upscale)<br>• Auto-Enhance (Smart tuning)<br>• Artistic Cartoonize<br>• ML Background Removal<br>• Neural Denoise<br>• Neural Style Transfer<br>• Saliency-driven Smart Crop<br>• Depth-Aware Image Enhancement |
| **Pro-Level Animation Engine** | • GIF / APNG / Animated HEIC<br>• AI-Optimized Frame Timing<br>• Smart Frame Skipping for Smooth Playback<br>• Best-Frame Detection (saliency + clarity)<br>• 30–120 FPS CADisplayLink Engine<br>• Automatic GPU Warm-Up for Zero Jank |
| **Performance & Efficiency** | • Multi-Queue Hyper Parallel Pipeline<br>• Progressive Loading for Instant Previews<br>• High-Performance AVIF & WebP Decoders<br>• AI-Guided Memory & Disk Caching<br>• Transform Cache with AI Ranking<br>• CoreML Model Manager with Auto-Trim<br>• Ultra-Low Latency Transform Engine |
| **Extensible Plugin System** | • Register Custom Decoders (RAW, AVIF, etc.)<br>• Plug-In Custom ML Transforms<br>• Extend Metadata Extraction (Vision, EXIF, OCR)<br>• Full Lifecycle Event Hooks<br>• Async-Safe, Sendable Plugin Architecture |

## Installation

### Swift Package Manager (Recommended)

AIAutoImage supports **Swift 6** and **iOS 15+**.

You can install it using **Swift Package Manager** directly from GitHub.

#### Adding via Xcode

1. Open **Xcode > File > Add Packages…**
2. Enter the repository URL:
   ```swift
   https://github.com/yourname/AIAutoImage.git
   ```
   
3. Select **Version: 1.0.0**
4. Add the package to your app target

---

#### Add to `Package.swift`

If you’re using SPM manually:

```swift
dependencies: [
    .package(url: "https://github.com/yourname/AIAutoImage.git", from: "1.0.0")
]
 ```
## Quick Start

**Fully Featured, Beautiful, Expandable, and Developer-Friendly**

Below are essential examples to get you started with AIAutoImage.

---

## Basic Loading

**UIKit / Swift 6**

```swift
import AIAutoImage

let url = URL(string: "https://example.com/image.jpg")!

let imageView = UIImageView()
imageView.contentMode = .scaleAspectFill

imageView.ai_setImage(url: url)
```

## SwiftUI Support
**Native SwiftUI Component**

```swift
import SwiftUI
import AIAutoImage

struct ContentView: View {
    var body: some View {
        AIImage(
            url: URL(string: "https://example.com/photo.png")!,
            placeholder: {
                ProgressView()
            }
        )
        .frame(width: 200, height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
```

## UIKit Integration
**Simple, Drop-In Compatibility**

```swift
import UIKit
import AIAutoImage

class ViewController: UIViewController {
    let imageView = UIImageView()

    override func viewDidLoad() {
        super.viewDidLoad()

        imageView.frame = CGRect(x: 20, y: 100, width: 300, height: 200)
        view.addSubview(imageView)

        imageView.ai_setImage(
            url: URL(string: "https://example.com/landscape.jpg")!
        )
    }
}
```
## AI Transforms

**CoreML + Vision Powered Enhancements**

```swift
import AIAutoImage

let url = URL(string: "https://example.com/photo.jpg")!
let request = AIImageRequest(url: url)

Task {
    let data = try await AIImagePipeline.shared.fetchData(for: request)

    if let image = UIImage(data: data) {
        let transformer = AITransformer()

        let result = try await transformer.applyTransformations(
            to: image,
            using: [
                .superResolution(scale: 2.0),
                .autoEnhance,
                .denoise
            ],
            modelManager: AIModelManager.shared
        )

        print("Transformed Image:", result)
    }
}
```

## Animated Image

**GIF / APNG / Animated HEIC Engine**

```swift
import AIAutoImage
import UIKit

let animatedView = AIAnimatedImageView(frame: CGRect(x: 0, y: 0, width: 300, height: 220))

Task {
    let data = try await AIImagePipeline.shared.fetchData(
        for: AIImageRequest(url: URL(string: "https://example.com/sample.gif")!)
    )

    if let anim = await AIAnimatedDecoder().decodeAnimatedImage(data: data) {
        animatedView.setAnimatedImage(anim)
    }
}
```

## Extract Metadata

**Vision-Powered Insights**

```swift
import AIAutoImage

let url = URL(string: "https://example.com/city.jpg")!

Task {
    let data = try await AIImagePipeline.shared.fetchData(for: AIImageRequest(url: url))

    if let image = UIImage(data: data) {
        let metadata = await AIImageMetadataCenter.shared.extractAll(from: image)
        print("Metadata:", metadata)
    }
}
```

## Plugin Example

**Extend AIAutoImage With Custom Logic**

```swift
import AIAutoImage

struct InvertColorPlugin: AIPlugin {
    let name = "InvertColor"

    func registerTransforms(into pipeline: AITransformPipeline) async {
        await pipeline.register(id: "invert", category: .filter) { image in
            guard let cg = image.cgImage else { return image }
            let ci = CIImage(cgImage: cg)

            if let filter = CIFilter(name: "CIColorInvert") {
                filter.setValue(ci, forKey: kCIInputImageKey)
                if let output = filter.outputImage,
                   let cgOutput = CIContext().createCGImage(output, from: output.extent) {
                    return UIImage(cgImage: cgOutput)
                }
            }

            return image
        }
    }
}

Task {
    await AIPluginManager.shared.register(InvertColorPlugin())
}
```
##  Contributing

Contributions are welcome!  

Before contributing to AIAutoImage, please read the instructions detailed in our [contribution guide](CONTRIBUTING.md).
Whether it's bug reports, feature requests, performance improvements, or documentation updates — every contribution helps.

---

## Author

**AIAutoImage** is developed and maintained by:

- [WeTechnoMind](https://github.com/wetechnomind)
 & [Dhiiren Bharadava](https://github.com/dhiiren)

---

## License

All source code is licensed under the [MIT License](https://github.com/SDWebImage/SDWebImage/blob/master/LICENSE).

---

##  High Level Diagram

<img width="1024" height="1536" alt="High Level Diagram" src="https://github.com/user-attachments/assets/086f74b7-25fd-4ccb-b246-6668b43ff8f9" />






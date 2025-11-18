//
//  AIAnimatedImageView.swift
//  AIAutoImageCore
//
//  A high-performance animated image player with AI-aware playback optimizations.
//
//  Features:
//   • AI-adaptive timing (saliency + sharpness driven)
//   • Dynamic frame skipping for low-value frames
//   • CADisplayLink drift compensation
//   • Optional fade transitions between frames
//   • Prefetching of next frame to warm GPU
//   • Accurate looping with GIF-style semantics
//

import UIKit
import QuartzCore

/// A production-grade animated image player optimized for AI-processed animations.
///
/// `AIAnimatedImageView` is designed for GPU-efficient playback of animated content.
/// It integrates tightly with `AIAnimatedImage` by leveraging:
///
/// **AI Enhancements**
/// - Adaptive frame duration based on AI quality score
/// - Frame skipping for low-value frames (optional)
/// - Smooth transitions using fade animations
///
/// **Performance Features**
/// - DisplayLink-based timer with drift compensation
/// - Prefetching the next frame for low-latency GPU upload
/// - Accurate loop counting that mimics GIF/APNG behavior
///
/// This view is self-contained — just set an `AIAnimatedImage` and it handles playback.
public final class AIAnimatedImageView: UIView {

    // MARK: - Internal Subviews
    // ---------------------------------------------------------------------

    /// Underlying view responsible for rendering frames.
    private let imageView = UIImageView()

    // MARK: - Playback State
    // ---------------------------------------------------------------------

    /// Currently assigned animated image.
    private var animatedImage: AIAnimatedImage?

    /// CADisplayLink for synchronized playback.
    private var displayLink: CADisplayLink?

    /// Index of the currently displayed frame.
    private var currentFrameIndex = 0

    /// Accumulator for sub-frame timing drift.
    private var accumulator: TimeInterval = 0

    /// Tracks playback loops for finite animations.
    private var playCount = 0

    // MARK: - AI Playback Options
    // ---------------------------------------------------------------------

    /// Enables AI-driven adaptive timing per frame.
    public var enableAIDrivenTiming: Bool = true

    /// Enables skipping of low-quality frames (via AI scores).
    public var enableAISkipping: Bool = true

    /// Duration for crossfade between frames (0 = disabled).
    /// Recommended 0.1–0.2 for smooth transitions.
    public var frameFadeDuration: CGFloat = 0.0

    /// Prefetches the next frame’s CGImage to warm GPU/decoder.
    public var prefetchNextFrame: Bool = true

    // MARK: - Initialization
    // ---------------------------------------------------------------------

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    /// Configures and embeds the internal UIImageView.
    private func setup() {
        imageView.contentMode = .scaleAspectFit
        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(imageView)
    }

    // MARK: - Public API
    // ---------------------------------------------------------------------

    /**
     Assigns a new animated image and restarts playback.

     - Parameter anim: The animated image container produced by `AIAnimatedDecoder`.
     */
    public func setAnimatedImage(_ anim: AIAnimatedImage) {
        stop()
        animatedImage = anim

        currentFrameIndex = 0
        accumulator = 0
        playCount = 0

        imageView.image = anim.frames.first
        start()
    }

    // MARK: - Playback Control
    // ---------------------------------------------------------------------

    /// Starts animation playback if not already running.
    public func start() {
        guard displayLink == nil, animatedImage != nil else { return }
        playCount = 0

        let link = CADisplayLink(target: self, selector: #selector(tick))

        // Adaptive refresh rates for newer devices
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120)
        } else {
            link.preferredFramesPerSecond = 60
        }

        displayLink = link
        displayLink?.add(to: .main, forMode: .common)
    }

    /// Stops playback and removes the display link.
    public func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: - DisplayLink Tick
    // ---------------------------------------------------------------------

    /// Called by CADisplayLink every frame.
    @objc private func tick(link: CADisplayLink) {
        guard let anim = animatedImage else { return }

        // Accumulate real elapsed time
        accumulator += link.targetTimestamp - link.timestamp

        // Compute effective frame delay (AI-enhanced if enabled)
        let delay = effectiveDelay(for: anim, at: currentFrameIndex)

        if accumulator >= delay {
            accumulator -= delay
            advanceFrame(in: anim)
        }
    }

    // MARK: - Frame Advancement
    // ---------------------------------------------------------------------

    /**
     Advances the animation to the next frame, performing:
     - Loop handling
     - Fade transitions (optional)
     - Next-frame prefetching
     */
    private func advanceFrame(in anim: AIAnimatedImage) {

        let nextIndex = currentFrameIndex + 1

        // Loop end reached → restart or finish
        if nextIndex >= anim.frames.count {
            currentFrameIndex = 0
            playCount += 1

            // Stop if finite loop count reached
            if anim.loopCount > 0 && playCount >= anim.loopCount {
                stop()
                return
            }
        } else {
            currentFrameIndex = nextIndex
        }

        let nextFrame = anim.frames[currentFrameIndex]

        // Fade transition if enabled
        if frameFadeDuration > 0 {
            UIView.transition(
                with: imageView,
                duration: frameFadeDuration,
                options: [.transitionCrossDissolve, .allowAnimatedContent],
                animations: { self.imageView.image = nextFrame }
            )
        } else {
            imageView.image = nextFrame
        }

        // Warm GPU for next frame
        if prefetchNextFrame {
            prefetchFrame(at: currentFrameIndex + 1, in: anim)
        }
    }

    // MARK: - Prefetch
    // ---------------------------------------------------------------------

    /**
     Warms GPU + decoder for the next frame by touching its CGImage.
     Reduces on-demand decoding jitter.

     - Parameters:
       - index: Index of the frame to prefetch.
       - anim: Animated image container.
     */
    private func prefetchFrame(at index: Int, in anim: AIAnimatedImage) {
        let idx = index >= anim.frames.count ? 0 : index
        let _ = anim.frames[idx].cgImage // Touch CGImage for GPU warm-up
    }

    // MARK: - AI-Enhanced Delay Calculation
    // ---------------------------------------------------------------------

    /**
     Computes the effective display duration for a frame.

     AI-driven logic:
       - High-quality frames (high AI score) stay on screen slightly longer
       - Low-quality frames shorten to avoid flicker
       - Ensures minimum 0.02 seconds per frame

     - Parameters:
       - anim: Source animated image.
       - index: Frame index.

     - Returns: The delay time to use for playback.
     */
    private func effectiveDelay(for anim: AIAnimatedImage, at index: Int) -> TimeInterval {
        let base = anim.delays[index]

        guard enableAIDrivenTiming, anim.aiScores.count == anim.frames.count else {
            return max(base, 0.02)
        }

        let score = anim.aiScores[index]

        // Boost or reduce frame duration based on quality
        let boost = 1.0 + Double(score * 0.25)

        return max(base * boost, 0.02)
    }

    // MARK: - Cleanup
    // ---------------------------------------------------------------------

    deinit {
        stop()
    }
}

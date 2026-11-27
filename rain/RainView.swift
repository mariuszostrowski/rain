//
//  RainView.swift
//  rain
//
//  Screen saver entry point. Hosts a CAMetalLayer and drives RainRenderer.
//

import ScreenSaver
import QuartzCore
import Metal

@objc(RainView)
final class RainView: ScreenSaverView {

    /// legacyScreenSaver creates a new view on every activation without releasing
    /// the old ones, so live instances are tracked to shut stale ones down.
    private static let instances = NSHashTable<RainView>.weakObjects()

    private let metalLayer = CAMetalLayer()
    private var renderer: RainRenderer?
    private var lastTimestamp: CFTimeInterval = 0
    private var halted = false

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    private func commonInit() {
        animationTimeInterval = 1.0 / 60.0

        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm_srgb
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.maximumDrawableCount = 3
        metalLayer.backgroundColor = NSColor.black.cgColor
        wantsLayer = true
        updateDrawableSize()

        Self.instances.add(self)

        // legacyScreenSaver (macOS 14+) does not reliably call stopAnimation;
        // this notification is the dependable "dismissed" signal.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenSaverWillStop(_:)),
            name: Notification.Name("com.apple.screensaver.willstop"),
            object: nil)
    }

    // MARK: - Layer

    override func makeBackingLayer() -> CALayer { metalLayer }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { /* Metal renders into the layer */ }
    override func draw(_ rect: NSRect) { /* Metal renders into the layer */ }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: max(1, bounds.width * scale),
                                         height: max(1, bounds.height * scale))
    }

    // MARK: - Animation

    override func startAnimation() {
        super.startAnimation()
        // A fresh full-screen run makes every older full-screen instance stale.
        if !isPreview {
            for view in Self.instances.allObjects where view !== self && !view.isPreview {
                view.shutDown()
            }
        }
        halted = false
        lastTimestamp = 0
        ensureRenderer()
    }

    override func stopAnimation() {
        super.stopAnimation()
        shutDown()
    }

    override func animateOneFrame() {
        guard !halted else { return }
        ensureRenderer()
        guard let renderer else { return }
        let now = CACurrentMediaTime()
        let dt = lastTimestamp == 0 ? 1.0 / 60.0 : now - lastTimestamp
        lastTimestamp = now
        renderer.render(dt: Float(min(max(dt, 0.0), 0.1)))
    }

    /// A new renderer per run also means a new random street every time.
    private func ensureRenderer() {
        guard renderer == nil else { return }
        updateDrawableSize()
        renderer = RainRenderer(layer: metalLayer,
                                bundle: Bundle(for: RainView.self),
                                isPreview: isPreview)
    }

    /// Stops drawing and releases GPU resources; the view can be restarted later.
    private func shutDown() {
        halted = true
        renderer = nil
    }

    @objc private func screenSaverWillStop(_ note: Notification) {
        // The small thumbnail in System Settings keeps running.
        guard !isPreview else { return }
        shutDown()
    }

    // MARK: - Options

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
}

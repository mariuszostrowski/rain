//
//  RainRenderer.swift
//  rain
//
//  Frame pipeline:
//   1. scene     – night street (photo or procedural) + procedural bokeh   (½ res, HDR)
//   2. blur      – heavy gaussian of the scene, seen through condensation  (⅙ res, MPS)
//   3. water     – drops splatted as metaballs: R = height, G = height·radius (½ res)
//   4. fog       – persistent condensation map: R = fog, G = wetness       (½ res, ping-pong)
//   5. composite – refraction, fog, micro-beads, tonemap                   (full res)
//

import Foundation
import Metal
import MetalKit
import MetalPerformanceShaders
import QuartzCore
import simd

// Layouts must match Shaders.metal
struct RainUniforms {
    var a: SIMD4<Float> // aspect, time, dt, fogInit
    var b: SIMD4<Float> // drawableW, drawableH, waterW, waterH
    var c: SIMD4<Float> // photoAspect, hasPhoto, photoExposure, refraction
    var d: SIMD4<Float> // fogTau, wetTau, fogStrength, seed
    var e: SIMD4<Float> // vanishX fraction, horizon, haze warmth, skyline seed
    var f: SIMD4<Float> // parallax: street offset (uv), bokeh offset (glass units)
    var k: SIMD4<Float> // parallax: glass offset (uv), glass zoom, street zoom
}

struct GPUDrop {
    var a: SIMD4<Float> // x, y, radius, stretch
    var b: SIMD4<Float> // vx, vy, -, -
}

struct GPUBokeh {
    var a: SIMD4<Float> // x, y, radius, intensity
    var b: SIMD4<Float> // r, g, b, seed
}

private enum RendererError: Error { case missingFunction(String) }

final class RainRenderer {

    private static let maxDrops = 4096
    private static let maxLights = 512
    private static let framesInFlight = 3

    private let layer: CAMetalLayer
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let scenePipeline: MTLRenderPipelineState
    private let bokehPipeline: MTLRenderPipelineState
    private let dropPipeline: MTLRenderPipelineState
    private let fogPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let photo: MTLTexture
    private let hasPhoto: Bool
    private let photoAspect: Float
    private let scaler: MPSImageBilinearScale
    private let dropBuffers: [MTLBuffer]
    private let bokehBuffers: [MTLBuffer]
    private let simulation: DropSimulation
    private let bokeh: BokehField
    private let seed: Float
    private let inFlight = DispatchSemaphore(value: RainRenderer.framesInFlight)

    private var sceneTex: MTLTexture?
    private var smallTex: MTLTexture?
    private var blurTex: MTLTexture?
    private var waterTex: MTLTexture?
    private var fogTex: [MTLTexture] = []
    private var fogIndex = 0
    private var gaussian: MPSImageGaussianBlur?
    private var textureSize = (width: 0, height: 0)
    private var bufferIndex = 0
    private var time: Float = 0
    private var needsFogInit = true
    private let cameraPhase: SIMD4<Float>

    // Parallax: a slow, gentle camera drift. Nearer layers move further.
    private static let streetShift: Float = 0.006   // far street (uv)
    private static let bokehShift: Float = 0.016    // out-of-focus lights
    private static let glassShift: Float = 0.030    // the pane with its drops (nearest)

    init?(layer: CAMetalLayer, bundle: Bundle, isPreview: Bool) {
        guard let device = layer.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        layer.device = device

        let library: MTLLibrary
        do {
            library = try device.makeDefaultLibrary(bundle: bundle)
        } catch {
            NSLog("RainGlass: cannot load Metal library: \(error)")
            return nil
        }

        let scene, bokehP, drop, fog, composite: MTLRenderPipelineState
        do {
            scene = try Self.pipeline(device, library, "fullscreenVertex", "sceneFragment", .rgba16Float, additive: false)
            bokehP = try Self.pipeline(device, library, "bokehVertex", "bokehFragment", .rgba16Float, additive: true)
            drop = try Self.pipeline(device, library, "dropVertex", "dropFragment", .rg16Float, additive: true)
            fog = try Self.pipeline(device, library, "fullscreenVertex", "fogFragment", .rg16Float, additive: false)
            composite = try Self.pipeline(device, library, "fullscreenVertex", "compositeFragment", layer.pixelFormat, additive: false)
        } catch {
            NSLog("RainGlass: pipeline error: \(error)")
            return nil
        }

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.mipFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: sd) else { return nil }

        var dbs: [MTLBuffer] = []
        var bbs: [MTLBuffer] = []
        for _ in 0..<Self.framesInFlight {
            guard let db = device.makeBuffer(length: MemoryLayout<GPUDrop>.stride * Self.maxDrops, options: .storageModeShared),
                  let bb = device.makeBuffer(length: MemoryLayout<GPUBokeh>.stride * Self.maxLights, options: .storageModeShared)
            else { return nil }
            dbs.append(db)
            bbs.append(bb)
        }

        let loaded = Self.loadPhoto(device: device, bundle: bundle)
        guard let photoTexture = loaded ?? Self.placeholderTexture(device: device) else { return nil }

        let seed64 = UInt64(Date().timeIntervalSinceReferenceDate * 1000) | 1

        self.layer = layer
        self.device = device
        self.queue = queue
        self.scenePipeline = scene
        self.bokehPipeline = bokehP
        self.dropPipeline = drop
        self.fogPipeline = fog
        self.compositePipeline = composite
        self.sampler = sampler
        self.photo = photoTexture
        self.hasPhoto = loaded != nil
        self.photoAspect = Float(photoTexture.width) / Float(max(photoTexture.height, 1))
        self.scaler = MPSImageBilinearScale(device: device)
        self.dropBuffers = dbs
        self.bokehBuffers = bbs
        self.simulation = DropSimulation(seed: seed64, detail: isPreview ? 0.6 : 1.0)
        self.bokeh = BokehField(seed: seed64 &* 2_654_435_761)
        self.seed = Float(seed64 % 1000) / 1000.0
        var phaseRNG = RandomGenerator(seed: seed64 &* 0x9E37_79B9)
        self.cameraPhase = SIMD4(phaseRNG.range(0, 6.283), phaseRNG.range(0, 6.283),
                                 phaseRNG.range(0, 6.283), phaseRNG.range(0, 6.283))
    }

    deinit {
        // A DispatchSemaphore must not be released below its initial value,
        // so wait for frames still on the GPU before tearing down.
        for _ in 0..<Self.framesInFlight { _ = inFlight.wait(timeout: .now() + .seconds(1)) }
        for _ in 0..<Self.framesInFlight { inFlight.signal() }
    }

    // MARK: - Frame

    func render(dt: Float) {
        let size = layer.drawableSize
        let width = Int(size.width), height = Int(size.height)
        guard width > 8, height > 8 else { return }
        ensureTextures(width: width, height: height)
        guard let sceneTex, let smallTex, let blurTex, let waterTex, let gaussian, fogTex.count == 2 else { return }

        // Never block the host's main thread: if the GPU/compositor stops consuming
        // frames (window hidden, display asleep), skip this frame instead of hanging.
        guard inFlight.wait(timeout: .now() + .milliseconds(50)) == .success else { return }

        time += dt
        let aspect = Float(width) / Float(height)
        simulation.update(dt: dt, aspect: aspect)
        bokeh.update(dt: dt, aspect: aspect)

        let dropBuffer = dropBuffers[bufferIndex]
        let bokehBuffer = bokehBuffers[bufferIndex]
        let dropCount = simulation.write(
            into: dropBuffer.contents().bindMemory(to: GPUDrop.self, capacity: Self.maxDrops),
            capacity: Self.maxDrops)
        let lightCount = bokeh.write(
            into: bokehBuffer.contents().bindMemory(to: GPUBokeh.self, capacity: Self.maxLights),
            capacity: Self.maxLights)

        var u = RainUniforms(
            a: SIMD4(aspect, time, dt, needsFogInit ? 1 : 0),
            b: SIMD4(Float(width), Float(height), Float(waterTex.width), Float(waterTex.height)),
            c: SIMD4(photoAspect, hasPhoto ? 1 : 0, 0.8, 0.11),
            d: SIMD4(16.0, 7.0, 1.0, seed),
            e: bokeh.sceneParams,
            f: .zero,
            k: .zero)
        let cam = cameraPosition()
        let street = -cam * Self.streetShift
        let lights = -cam * Self.bokehShift
        let pane = -cam * Self.glassShift
        u.f = SIMD4(street.x, street.y, lights.x * aspect, lights.y)
        // Each layer is zoomed just enough that its edges never come into view
        u.k = SIMD4(pane.x, pane.y, 1 + 2.2 * Self.glassShift, 1 + 2.2 * Self.streetShift)
        needsFogInit = false
        let uSize = MemoryLayout<RainUniforms>.stride

        guard let drawable = layer.nextDrawable(), let cb = queue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        let semaphore = inFlight
        cb.addCompletedHandler { _ in semaphore.signal() }

        // 1. Scene behind the glass
        if let enc = beginPass(cb, sceneTex, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)) {
            enc.setRenderPipelineState(scenePipeline)
            enc.setFragmentBytes(&u, length: uSize, index: 0)
            enc.setFragmentTexture(photo, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            if lightCount > 0 {
                enc.setRenderPipelineState(bokehPipeline)
                enc.setVertexBuffer(bokehBuffer, offset: 0, index: 0)
                enc.setVertexBytes(&u, length: uSize, index: 1)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: lightCount)
            }
            enc.endEncoding()
        }

        // 2. Heavy blur for the condensation layer
        scaler.encode(commandBuffer: cb, sourceTexture: sceneTex, destinationTexture: smallTex)
        gaussian.encode(commandBuffer: cb, sourceTexture: smallTex, destinationTexture: blurTex)

        // 3. Water height field
        if let enc = beginPass(cb, waterTex, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)) {
            if dropCount > 0 {
                enc.setRenderPipelineState(dropPipeline)
                enc.setVertexBuffer(dropBuffer, offset: 0, index: 0)
                enc.setVertexBytes(&u, length: uSize, index: 1)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: dropCount)
            }
            enc.endEncoding()
        }

        // 4. Condensation / wetness memory
        let fogSrc = fogTex[fogIndex]
        let fogDst = fogTex[1 - fogIndex]
        fogIndex = 1 - fogIndex
        if let enc = beginPass(cb, fogDst, clear: nil) {
            enc.setRenderPipelineState(fogPipeline)
            enc.setFragmentBytes(&u, length: uSize, index: 0)
            enc.setFragmentTexture(fogSrc, index: 0)
            enc.setFragmentTexture(waterTex, index: 1)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        // 5. Composite to screen
        if let enc = beginPass(cb, drawable.texture, clear: nil) {
            enc.setRenderPipelineState(compositePipeline)
            enc.setFragmentBytes(&u, length: uSize, index: 0)
            enc.setFragmentTexture(sceneTex, index: 0)
            enc.setFragmentTexture(blurTex, index: 1)
            enc.setFragmentTexture(waterTex, index: 2)
            enc.setFragmentTexture(fogDst, index: 3)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        cb.present(drawable)
        cb.commit()
        bufferIndex = (bufferIndex + 1) % Self.framesInFlight
    }

    /// Smooth, never-repeating drift in −1…1, like a camera held by a calm hand.
    private func cameraPosition() -> SIMD2<Float> {
        let t = time
        let p = cameraPhase
        let x = 0.6 * sin(t * 0.31 + p.x) + 0.4 * sin(t * 0.19 + p.y)
        let y = 0.55 * sin(t * 0.23 + p.z) + 0.3 * sin(t * 0.13 + p.w)
        return SIMD2(x, y * 0.7)
    }

    // MARK: - Resources

    private func beginPass(_ cb: MTLCommandBuffer, _ texture: MTLTexture, clear: MTLClearColor?) -> MTLRenderCommandEncoder? {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = texture
        if let clear {
            rp.colorAttachments[0].loadAction = .clear
            rp.colorAttachments[0].clearColor = clear
        } else {
            rp.colorAttachments[0].loadAction = .dontCare
        }
        rp.colorAttachments[0].storeAction = .store
        return cb.makeRenderCommandEncoder(descriptor: rp)
    }

    private func ensureTextures(width: Int, height: Int) {
        guard width != textureSize.width || height != textureSize.height else { return }
        textureSize = (width, height)

        let hw = max(1, width / 2), hh = max(1, height / 2)
        let sw = max(1, width / 6), sh = max(1, height / 6)

        sceneTex = makeTexture(.rgba16Float, hw, hh, [.renderTarget, .shaderRead])
        smallTex = makeTexture(.rgba16Float, sw, sh, [.shaderRead, .shaderWrite])
        blurTex = makeTexture(.rgba16Float, sw, sh, [.shaderRead, .shaderWrite])
        waterTex = makeTexture(.rg16Float, hw, hh, [.renderTarget, .shaderRead])
        fogTex = [makeTexture(.rg16Float, hw, hh, [.renderTarget, .shaderRead]),
                  makeTexture(.rg16Float, hw, hh, [.renderTarget, .shaderRead])].compactMap { $0 }
        fogIndex = 0
        needsFogInit = true

        let g = MPSImageGaussianBlur(device: device, sigma: max(2.0, Float(sh) * 0.03))
        g.edgeMode = .clamp
        gaussian = g
    }

    private func makeTexture(_ format: MTLPixelFormat, _ w: Int, _ h: Int, _ usage: MTLTextureUsage) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
        d.usage = usage
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    private static func pipeline(_ device: MTLDevice, _ lib: MTLLibrary, _ v: String, _ f: String,
                                 _ format: MTLPixelFormat, additive: Bool) throws -> MTLRenderPipelineState {
        guard let vf = lib.makeFunction(name: v) else { throw RendererError.missingFunction(v) }
        guard let ff = lib.makeFunction(name: f) else { throw RendererError.missingFunction(f) }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = vf
        d.fragmentFunction = ff
        d.colorAttachments[0].pixelFormat = format
        if additive, let ca = d.colorAttachments[0] {
            ca.isBlendingEnabled = true
            ca.rgbBlendOperation = .add
            ca.alphaBlendOperation = .add
            ca.sourceRGBBlendFactor = .one
            ca.destinationRGBBlendFactor = .one
            ca.sourceAlphaBlendFactor = .one
            ca.destinationAlphaBlendFactor = .one
        }
        return try device.makeRenderPipelineState(descriptor: d)
    }

    /// Picks a random `background*.(heic|jpg|jpeg|png)` from the .saver bundle
    /// (e.g. background.jpg, background-2.jpg, background_oslo.heic…).
    private static func loadPhoto(device: MTLDevice, bundle: Bundle) -> MTLTexture? {
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: true,
            .generateMipmaps: true,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue)
        ]
        var candidates: [URL] = []
        for ext in ["heic", "jpg", "jpeg", "png"] {
            candidates += (bundle.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? [])
                .filter { $0.lastPathComponent.lowercased().hasPrefix("background") }
        }
        for url in candidates.shuffled() {
            do {
                return try loader.newTexture(URL: url, options: options)
            } catch {
                NSLog("RainGlass: cannot load \(url.lastPathComponent): \(error)")
            }
        }
        return nil
    }

    private static func placeholderTexture(device: MTLDevice) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        var px: [UInt8] = [0, 0, 0, 255]
        t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
        return t
    }
}

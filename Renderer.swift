import MetalKit
import QuartzCore

struct Shared {
    var res = SIMD2<Float>.zero, sun = SIMD2<Float>.zero, moon = SIMD2<Float>.zero
    var originY: Float = 0, layerHeight: Float = 0, horizon = Float(horizonFraction)
    var sunUp: Float = 0, moonUp: Float = 0, night: Float = 0, lowSun: Float = 0
    var fog: Float = 0, rain: Float = 0, rainX: Float = 0
    var skyTop = SIMD3<Float>.zero, skyHor = SIMD3<Float>.zero, seaFar = SIMD3<Float>.zero
    var seaNear = SIMD3<Float>.zero, glow = SIMD3<Float>.zero, whale = SIMD3<Float>.zero, rainbow = SIMD3<Float>.zero
    var boats: Traffic = (.zero, .zero, .zero, .zero, .zero)
}

struct SkyParams {
    var cloudDrift = SIMD2<Float>.zero, layerSize = SIMD2<Float>.zero
    var cloudAmount: Float = 0
}

struct SeaParams {
    var scrollSwell = SIMD2<Float>.zero, scrollChop = SIMD2<Float>.zero, scrollRipple = SIMD2<Float>.zero
    var driftGust = SIMD2<Float>.zero, driftWind = SIMD2<Float>.zero
    var roughness: Float = 0
}

private struct Wave {
    var cycles: SIMD2<Float>
    var amplitude: Float
    var phase: Float
}

// The sky hardly changes and the sea never stops, so they are separate layers: the window server
// only recomposites the sea's part of the screen, and the sky is drawn every few seconds.
final class SceneRenderer: NSObject, MTKViewDelegate {
    private static let seaScale = 0.75
    private static let seaMaxWidth = 2560.0
    private static let starSeconds = 20.0
    private static let bakeSize = 1024
    // The soft-noise scales in the shaders repeat exactly over this many texture units.
    private static let fieldPeriod = 8000.0

    let skyView: MTKView
    let seaView: MTKView

    private let queue: MTLCommandQueue
    private let skyPipeline: MTLRenderPipelineState
    private let seaPipeline: MTLRenderPipelineState
    private let waveMap: MTLTexture
    private var starBuffer: MTLBuffer?
    private var starTexture: MTLTexture?
    private var starContext: CGContext?

    private var shared = Shared()
    private var sky = SkyParams()
    private var sceneHeight = 0.0
    private var wind = 0.5
    private var seaRenderScale = 0.75
    private var seaAnimating = false
    private var seaLink: CADisplayLink?
    private var seaTime = Double.random(in: 0..<4000)
    private var lastSeaDraw = CACurrentMediaTime()
    private var lastStars = -Double.infinity

    init?(device: MTLDevice) {
        guard
            let queue = device.makeCommandQueue(),
            // Compiled at launch, so building the app needs no Metal toolchain.
            let shaders = Bundle.main.url(forResource: "Shaders", withExtension: "metal"),
            let source = try? String(contentsOf: shaders, encoding: .utf8),
            let library = try? device.makeLibrary(source: source, options: nil)
        else { return nil }
        self.queue = queue

        let makePipeline = { (fragment: String, format: MTLPixelFormat) -> MTLRenderPipelineState? in
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "fullscreen")
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = format
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        guard
            let skyPipeline = makePipeline("drawSky", .bgra8Unorm),
            let seaPipeline = makePipeline("drawSea", .bgra8Unorm),
            let bakePipeline = makePipeline("bakeWaves", .rgba8Unorm),
            let waveMap = Self.bakeWaveMap(device: device, queue: queue, pipeline: bakePipeline)
        else { return nil }
        self.skyPipeline = skyPipeline
        self.seaPipeline = seaPipeline
        self.waveMap = waveMap

        let makeView = { () -> MTKView in
            let view = MTKView(frame: .zero, device: device)
            view.colorPixelFormat = .bgra8Unorm
            view.framebufferOnly = true
            view.autoResizeDrawable = false
            view.isPaused = true
            view.enableSetNeedsDisplay = false
            if let layer = view.layer as? CAMetalLayer {
                layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
                layer.maximumDrawableCount = 2
                layer.isOpaque = true
            }
            return view
        }
        skyView = makeView()
        seaView = makeView()
        super.init()
        skyView.delegate = self
        seaView.delegate = self
    }

    private static func bakeWaveMap(device: MTLDevice, queue: MTLCommandQueue, pipeline: MTLRenderPipelineState) -> MTLTexture? {
        var random = SeededRandom(11)
        let wave = { (cycles: Double, angle: Double, amplitude: Double) -> Wave in
            let x = (cycles * cos(angle)).rounded(), y = (cycles * sin(angle)).rounded()
            return Wave(cycles: SIMD2(Float(x == 0 ? 1 : x), Float(y)), amplitude: Float(amplitude), phase: Float(random.next() * 2 * .pi))
        }
        let normalised = { (waves: [Wave], target: Float) -> [Wave] in
            let rms = waves.reduce(Float(0)) { $0 + $1.amplitude * $1.amplitude / 2 }.squareRoot()
            return waves.map { var w = $0; w.amplitude *= target / rms; return w }
        }
        let slopeCount = 72, fieldCount = 40
        let slopeWaves = (0..<slopeCount).map { i -> Wave in
            let cycles = 3 * pow(60, Double(i) / Double(slopeCount - 1))
            let angle = 1.2 + 1.5 * (random.next() + random.next() - 1)
            return wave(cycles, angle, pow(cycles, -0.35))
        }
        let fieldWaves = (0..<fieldCount).map { i -> Wave in
            let cycles = pow(48, Double(i) / Double(fieldCount - 1))
            let angle = random.next() * 2 * .pi
            return wave(cycles, angle, 1 / cycles)
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: bakeSize, height: bakeSize, mipmapped: true)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let pass = MTLRenderPassDescriptor()
        guard let texture = device.makeTexture(descriptor: descriptor), let commands = queue.makeCommandBuffer() else { return nil }
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.setRenderPipelineState(pipeline)
        // Each axis of slope carries about half the power of the summed waves.
        let slope = normalised(slopeWaves, 0.12 * Float(2).squareRoot()), field = normalised(fieldWaves, 0.12)
        var slopeTotal = UInt32(slope.count), fieldTotal = UInt32(field.count), size = Float(bakeSize)
        encoder.setFragmentBytes(slope, length: MemoryLayout<Wave>.stride * slope.count, index: 0)
        encoder.setFragmentBytes(&slopeTotal, length: MemoryLayout<UInt32>.size, index: 1)
        encoder.setFragmentBytes(field, length: MemoryLayout<Wave>.stride * field.count, index: 2)
        encoder.setFragmentBytes(&fieldTotal, length: MemoryLayout<UInt32>.size, index: 3)
        encoder.setFragmentBytes(&size, length: MemoryLayout<Float>.size, index: 4)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        guard let blit = commands.makeBlitCommandEncoder() else { return nil }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        commands.commit()
        return texture
    }

    // The sky is drawn so rarely that it can use every pixel. The sea is capped, because its cost
    // follows its pixel count on every frame and soft water looks no worse at this distance.
    func layout(sceneSize: CGSize, scale: CGFloat) {
        let seaHeight = (sceneSize.height * horizonFraction).rounded()
        let skyHeight = sceneSize.height - seaHeight
        sceneHeight = sceneSize.height * scale
        seaView.frame = CGRect(x: 0, y: 0, width: sceneSize.width, height: seaHeight)
        skyView.frame = CGRect(x: 0, y: seaHeight, width: sceneSize.width, height: skyHeight)
        let skyPixels = CGSize(width: sceneSize.width * scale, height: skyHeight * scale)
        skyView.drawableSize = skyPixels
        seaRenderScale = min(Self.seaScale, Self.seaMaxWidth / skyPixels.width)
        seaView.drawableSize = CGSize(width: (skyPixels.width * seaRenderScale).rounded(), height: (seaHeight * scale * seaRenderScale).rounded())
        sky.layerSize = SIMD2(Float(skyPixels.width), Float(skyPixels.height))
        makeStarLayer(width: Int(skyPixels.width), height: Int(skyPixels.height))
        lastStars = -.infinity
        update()
    }

    // The bitmap and the texture share one block of memory, so painting needs no upload or copy.
    private func makeStarLayer(width: Int, height: Int) {
        guard let device = skyView.device, width > 0, height > 0 else { return }
        let alignment = device.minimumLinearTextureAlignment(for: .bgra8Unorm)
        let bytesPerRow = (width * 4 + alignment - 1) / alignment * alignment
        guard let buffer = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared) else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        starBuffer = buffer
        starTexture = buffer.makeTexture(descriptor: descriptor, offset: 0, bytesPerRow: bytesPerRow)
        starContext = CGContext(
            data: buffer.contents(), width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
    }

    // Everything that follows the real sky changes too slowly to need more than this.
    func update() {
        let date = Date(), d = daysSinceJ2000(date)
        let sunEq = sunEquatorial(d), moonEq = moonEquatorial(d)
        let sunPos = horizontal(sunEq, d), moonPos = horizontal(moonEq, d)
        let sunDegrees = sunPos.alt * 180 / .pi
        let night = smooth(-4, -14, sunDegrees)
        let sunY = skyY(sunPos.alt)

        let weather = Weather.at(date)
        wind = weather.wind
        // Broken cloud keeps the day's colour; only a thick overcast greys it.
        let overcast = Float(smooth(0.5, 1, weather.cover))
        let fog = Float(weather.fog), rain = Float(weather.rain)
        let muted = { (colour: SIMD3<Float>, amount: Float, dim: Float) -> SIMD3<Float> in
            let grey = SIMD3<Float>(repeating: simd_dot(colour, SIMD3(0.3, 0.59, 0.11)))
            return (colour + (grey - colour) * amount) * dim
        }
        let colours = paletteAt(altitude: sunDegrees)
        let horizonColour = muted(colours[1], 0.35 * overcast, 1 - 0.1 * overcast - 0.12 * rain)
        let farColour = muted(colours[2], 0.3 * overcast, 1 - 0.1 * overcast - 0.1 * rain)
        let haze = (horizonColour + farColour) * 0.5
        shared.skyTop = muted(colours[0], 0.3 * overcast, 1 - 0.14 * overcast - 0.12 * rain)
        shared.skyHor = horizonColour + (haze * 1.05 - horizonColour) * 0.7 * fog
        shared.seaFar = farColour + (haze - farColour) * 0.8 * fog
        shared.seaNear = muted(colours[3], 0.25 * overcast, 1 - 0.1 * overcast)
        // Fades before the sun wraps from one side of the view to the other, behind the viewer.
        shared.glow = colours[4] * (1 - 0.72 * overcast) * Float(1 - smooth(0.55, 0.72, abs(skyX(sunPos.az) - 0.5)))
        shared.fog = fog
        shared.rain = rain
        shared.rainX = Float(weather.rainX)
        shared.night = Float(night)
        shared.sun = SIMD2(Float(skyX(sunPos.az)), Float(sunY))
        shared.sunUp = Float(smooth(-0.01, 0.03, sunPos.alt)) * (1 - 0.72 * overcast) * (1 - 0.45 * fog)
        shared.lowSun = Float(1 - smooth(0, 0.3, sunY - horizonFraction))
        shared.moon = SIMD2(Float(skyX(moonPos.az)), Float(skyY(moonPos.alt)))
        shared.moonUp = Float(smooth(-0.01, 0.06, moonPos.alt) * moonIllumination(sun: sunEq, moon: moonEq) * (0.2 + 0.8 * night)) * (1 - 0.8 * overcast) * (1 - 0.5 * fog)

        let now = CACurrentMediaTime()
        if now - lastStars > Self.starSeconds, let context = starContext {
            lastStars = now
            paintStarLayer(context, sceneHeight: sceneHeight, date: date, night: night, sunPosition: sunPos, moonPosition: moonPos, sun: sunEq, moon: moonEq)
        }

        let t = date.timeIntervalSince1970
        sky.cloudDrift = SIMD2(wrapped(t * 0.0016, Self.fieldPeriod), wrapped(t * 0.0003, Self.fieldPeriod))
        sky.cloudAmount = Float(0.05 * sin(t * 0.00021) + (weather.cover - 0.45) * 0.4)

        shared.boats = boats(at: date)
        shared.whale = whale(at: date)
        shared.whale.z *= Float(1 - night) * (1 - fog)
        shared.rainbow = SIMD3(Float(skyX(sunPos.az + .pi)), Float(-sunPos.alt), Float(rainbowStrength(weather, sunAltitude: sunPos.alt, date: date)))

        skyView.draw()
        if !seaAnimating { seaView.draw() }
    }

    func setSeaAnimating(_ animating: Bool) {
        guard animating != seaAnimating else { return }
        seaAnimating = animating
        lastSeaDraw = CACurrentMediaTime()
        seaLink?.invalidate()
        seaLink = nil
        guard animating else { return }
        // A link from the view follows the screen it is on. A timer running off another display's
        // refresh would land frames unevenly here. The range lets macOS pick a whole divisor of
        // this screen's rate, so every frame stays up for the same time.
        let link = seaView.displayLink(target: self, selector: #selector(seaTick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 40, preferred: 33)
        link.add(to: .main, forMode: .common)
        seaLink = link
    }

    @objc private func seaTick() {
        seaView.draw()
    }

    // Offsets wrap here, in doubles. Left to grow, a 32-bit float in the shader would lose enough
    // precision over weeks of running to make the waves jitter.
    private func wrapped(_ value: Double, _ period: Double) -> Float {
        Float(value - (value / period).rounded(.down) * period)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard
            let pass = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable,
            let commands = queue.makeCommandBuffer()
        else { return }
        pass.colorAttachments[0].loadAction = .dontCare
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encode(view === seaView ? .sea : .sky, drawableHeight: Float(view.drawableSize.height), into: encoder)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }

    private enum Layer { case sky, sea }

    private func encode(_ layer: Layer, drawableHeight: Float, into encoder: MTLRenderCommandEncoder) {
        var uniforms = shared
        uniforms.layerHeight = drawableHeight
        encoder.setFragmentTexture(waveMap, index: 0)
        switch layer {
        case .sky:
            uniforms.res = SIMD2(sky.layerSize.x, Float(sceneHeight))
            uniforms.originY = Float(sceneHeight) - sky.layerSize.y
            encoder.setRenderPipelineState(skyPipeline)
            encoder.setFragmentTexture(starTexture, index: 1)
            encoder.setFragmentBytes(&sky, length: MemoryLayout<SkyParams>.stride, index: 1)
        case .sea:
            let scale = Float(seaRenderScale)
            uniforms.res = SIMD2(sky.layerSize.x, Float(sceneHeight)) * scale
            uniforms.originY = 0
            if seaAnimating {
                let now = CACurrentMediaTime()
                // A long gap means the display slept; the sea carries on from where it was.
                // Integrated, because scaling the clock itself would make the waves jump as the wind changes.
                seaTime += min(now - lastSeaDraw, 0.2) * (0.75 + 0.5 * wind)
                lastSeaDraw = now
            }
            var params = SeaParams(
                scrollSwell: SIMD2(wrapped(seaTime * 0.0011, 1), wrapped(seaTime * -0.0019, 1)),
                scrollChop: SIMD2(wrapped(seaTime * -0.0031, 1), wrapped(seaTime * 0.0046, 1)),
                scrollRipple: SIMD2(wrapped(seaTime * 0.0072, 1), wrapped(seaTime * 0.0098, 1)),
                driftGust: SIMD2(wrapped(seaTime * 0.0012, Self.fieldPeriod), wrapped(seaTime * -0.0007, Self.fieldPeriod)),
                driftWind: SIMD2(wrapped(seaTime * 0.0012, Self.fieldPeriod), wrapped(seaTime * -0.002, Self.fieldPeriod)),
                roughness: Float(wind)
            )
            encoder.setRenderPipelineState(seaPipeline)
            encoder.setFragmentBytes(&params, length: MemoryLayout<SeaParams>.stride, index: 1)
        }
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Shared>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}

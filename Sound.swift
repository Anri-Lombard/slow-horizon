import AVFoundation

// One overlapping swell. Each wave gets its own length, size and position, so the sum never
// settles into a rhythm that the ear could start following.
private struct Swell {
    var phase: Float
    var step: Float = 0
    var size: Float = 0
    var pan: Float = 0.5
}

// Noise shaped by slowly moving filters. It holds no recording, so there is no loop to notice.
final class SeaVoice {
    private static let controlFrames = 256
    private static let fadeInSeconds: Float = 4
    private static let fadeOutSeconds: Float = 1
    private static let level: Float = 0.95

    // Set from the main thread and read once per block by the audio thread. Each is a single
    // aligned float that only steers a slow fade, so a stale read does no harm.
    var wind: Float = 0.5
    var audible = false

    private let sampleRate: Float
    private let swells: UnsafeMutablePointer<Swell>
    private let swellCount = 6
    private var randomState = UInt32.random(in: 1...UInt32.max)
    private var noiseL: UInt32 = 0x2545_F491
    private var noiseR: UInt32 = 0x6C07_8965
    private var gain: Float = 0
    private var framesToControl = 0

    private var rumbleL1: Float = 0, rumbleL2: Float = 0, rumbleR1: Float = 0, rumbleR2: Float = 0
    private var washL1: Float = 0, washL2: Float = 0, washR1: Float = 0, washR2: Float = 0
    private var hissL1: Float = 0, hissL2: Float = 0, hissR1: Float = 0, hissR2: Float = 0
    private var subL: Float = 0, subR: Float = 0

    private var rumbleGainL: Float = 0, rumbleGainR: Float = 0, hissGainL: Float = 0, hissGainR: Float = 0
    private var washGainL: Float = 0, washGainR: Float = 0
    private var washCutL: Float = 0.05, washCutR: Float = 0.05

    private let rumbleCut: Float, hissLowCut: Float, hissHighCut: Float, subCut: Float

    init(sampleRate: Double) {
        self.sampleRate = Float(sampleRate)
        rumbleCut = Self.coefficient(170, Float(sampleRate))
        hissLowCut = Self.coefficient(2600, Float(sampleRate))
        hissHighCut = Self.coefficient(7000, Float(sampleRate))
        subCut = Self.coefficient(30, Float(sampleRate))
        swells = .allocate(capacity: swellCount)
        for i in 0..<swellCount {
            swells[i] = Swell(phase: Float(i) / Float(swellCount))
            startWave(&swells[i])
        }
    }

    deinit { swells.deallocate() }

    private static func coefficient(_ hertz: Float, _ sampleRate: Float) -> Float {
        1 - exp(-2 * .pi * hertz / sampleRate)
    }

    private func nextRandom() -> Float {
        randomState ^= randomState << 13
        randomState ^= randomState >> 17
        randomState ^= randomState << 5
        return Float(randomState) / Float(UInt32.max)
    }

    private func startWave(_ swell: inout Swell) {
        let seconds = 10 + 18 * nextRandom()
        swell.step = Float(Self.controlFrames) / (seconds * sampleRate)
        swell.size = 0.4 + 0.6 * nextRandom()
        swell.pan = 0.15 + 0.7 * nextRandom()
    }

    private func updateControls() {
        var left: Float = 0, right: Float = 0
        for i in 0..<swellCount {
            swells[i].phase += swells[i].step
            if swells[i].phase >= 1 {
                swells[i].phase -= 1
                startWave(&swells[i])
            }
            let hump = sin(.pi * swells[i].phase)
            let amount = hump * hump * swells[i].size
            left += amount * (1 - swells[i].pan)
            right += amount * swells[i].pan
        }
        // Six swells at average size and pan sum to about 1 on each side. A soft ceiling keeps
        // the moments when several crest together from standing out as a pulse.
        left = 1.5 * (1 - exp(-left))
        right = 1.5 * (1 - exp(-right))

        let w = wind
        let depth = 0.45 + 0.55 * w
        washGainL = 0.06 + 0.42 * depth * left
        washGainR = 0.06 + 0.42 * depth * right
        washCutL = Self.coefficient(300 + 1400 * depth * left, sampleRate)
        washCutR = Self.coefficient(300 + 1400 * depth * right, sampleRate)
        rumbleGainL = 0.4 + 0.25 * w + 0.15 * left
        rumbleGainR = 0.4 + 0.25 * w + 0.15 * right
        hissGainL = (0.006 + 0.03 * w * w) * (0.5 + left)
        hissGainR = (0.006 + 0.03 * w * w) * (0.5 + right)

        let block = Float(Self.controlFrames) / sampleRate
        if audible {
            gain = min(1, gain + block / Self.fadeInSeconds)
        } else {
            gain = max(0, gain - block / Self.fadeOutSeconds)
        }
    }

    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        for i in 0..<frames {
            if framesToControl == 0 {
                updateControls()
                framesToControl = Self.controlFrames
            }
            framesToControl -= 1

            noiseL ^= noiseL << 13; noiseL ^= noiseL >> 17; noiseL ^= noiseL << 5
            noiseR ^= noiseR << 13; noiseR ^= noiseR >> 17; noiseR ^= noiseR << 5
            let whiteL = Float(Int32(bitPattern: noiseL)) * 4.656e-10
            let whiteR = Float(Int32(bitPattern: noiseR)) * 4.656e-10

            rumbleL1 += rumbleCut * (whiteL - rumbleL1); rumbleL2 += rumbleCut * (rumbleL1 - rumbleL2)
            rumbleR1 += rumbleCut * (whiteR - rumbleR1); rumbleR2 += rumbleCut * (rumbleR1 - rumbleR2)
            washL1 += washCutL * (whiteL - washL1); washL2 += washCutL * (washL1 - washL2)
            washR1 += washCutR * (whiteR - washR1); washR2 += washCutR * (washR1 - washR2)
            hissL1 += hissLowCut * (whiteL - hissL1); hissL2 += hissHighCut * (whiteL - hissL2)
            hissR1 += hissLowCut * (whiteR - hissR1); hissR2 += hissHighCut * (whiteR - hissR2)

            let dryL = rumbleGainL * rumbleL2 + washGainL * washL2 + hissGainL * (hissL2 - hissL1)
            let dryR = rumbleGainR * rumbleR2 + washGainR * washR2 + hissGainR * (hissR2 - hissR1)
            // Sound below about 30 Hz is barely heard and only uses up headroom.
            subL += subCut * (dryL - subL)
            subR += subCut * (dryR - subR)
            left[i] = Self.level * gain * (dryL - subL)
            right[i] = Self.level * gain * (dryR - subR)
        }
    }
}

// The engine only runs while the sound can be heard. A running audio output holds off idle sleep
// and costs CPU, so it stops once the fade has finished.
final class SeaSound {
    private static let stopDelay = 1.2

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var voice: SeaVoice?
    private var wanted = false
    private var wind: Float = 0.5

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(outputChanged), name: .AVAudioEngineConfigurationChange, object: engine
        )
    }

    var isRunning: Bool { engine.isRunning }

    func setWind(_ value: Double) {
        wind = Float(value)
        voice?.wind = wind
    }

    func setPlaying(_ playing: Bool) {
        guard playing != wanted else { return }
        wanted = playing
        voice?.audible = playing
        if playing {
            start()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.stopDelay) { [weak self] in
                guard let self, !self.wanted else { return }
                self.engine.stop()
            }
        }
    }

    // Waits out a short fade, because cutting noise off mid-wave is an audible click.
    func stopForQuit() {
        guard wanted else { return }
        wanted = false
        voice?.audible = false
        Thread.sleep(forTimeInterval: Self.stopDelay)
        engine.stop()
    }

    private func start() {
        if source == nil { connect() }
        guard !engine.isRunning else { return }
        try? engine.start()
    }

    // Plugging in headphones can change the sample rate and stops the engine, so the graph is rebuilt.
    @objc private func outputChanged() {
        if let source { engine.detach(source) }
        source = nil
        if wanted { start() }
    }

    private func connect() {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard rate > 0, let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }
        let voice = SeaVoice(sampleRate: rate)
        voice.wind = wind
        voice.audible = wanted
        let source = AVAudioSourceNode(format: format) { _, _, frames, buffers in
            let list = UnsafeMutableAudioBufferListPointer(buffers)
            guard
                list.count >= 2,
                let left = list[0].mData?.assumingMemoryBound(to: Float.self),
                let right = list[1].mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }
            voice.render(left: left, right: right, frames: Int(frames))
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        self.source = source
        self.voice = voice
    }
}

import AVFoundation
import simd

/// Procedural game audio: no sample files. Ball hits, bounces, net, crowd bed and cheers are synthesised at start-up and played
/// through a small pool of player nodes (panned by court position); the umpire's calls use the system speech synthesiser.
final class GameAudio {
    static let sampleRate: Double = 44100

    // MARK: Synthesis (pure functions: unit-testable without an audio device)
    private struct Noise { var s: UInt32 = 0x1234ABCD; mutating func next() -> Float { s ^= s << 13; s ^= s >> 17; s ^= s << 5; return Float(s % 20000) / 10000 - 1 } }

    static func synthesize(duration: Double, _ f: (Float, inout Float) -> Float) -> [Float] {
        let n = Int(duration * sampleRate)
        var out = [Float](repeating: 0, count: n)
        var state: Float = 0
        for i in 0..<n { out[i] = f(Float(i) / Float(sampleRate), &state) }
        return out
    }

    /// Racket on ball: a sharp filtered noise crack, a pitched "pop" and a short body thump. `hardness` 0…1 brightens and loudens it.
    static func hitSamples(hardness: Float, seed: UInt32) -> [Float] {
        var noise = Noise(s: seed)
        var lp: Float = 0
        return synthesize(duration: 0.22) { t, _ in
            let crack = noise.next(); lp += (crack - lp) * (0.35 + 0.5 * hardness)
            let hp = crack - lp
            let pop = sinf(2 * .pi * (520 + 380 * hardness) * t) * expf(-t * 90)
            let thump = sinf(2 * .pi * 160 * t) * expf(-t * 38)
            return tanhf((hp * expf(-t * 260) * 1.6 + pop * 0.6 + thump * 0.9) * (0.7 + 0.5 * hardness)) * 0.9
        }
    }
    /// Ball on court: a soft low thud with a tiny felt tick.
    static func bounceSamples() -> [Float] {
        var noise = Noise(s: 99)
        return synthesize(duration: 0.14) { t, _ in sinf(2 * .pi * 105 * t) * expf(-t * 42) * 0.8 + noise.next() * expf(-t * 380) * 0.25 }
    }
    /// Ball in the net: a dull cord/tape "thup".
    static func netSamples() -> [Float] {
        var noise = Noise(s: 7); var lp: Float = 0
        return synthesize(duration: 0.28) { t, _ in lp += (noise.next() - lp) * 0.08; return (sinf(2 * .pi * 78 * t) * expf(-t * 16) * 0.7 + lp * expf(-t * 30) * 1.4) * 0.8 }
    }
    /// Applause + cheer: a swarm of individual hand-claps (short resonant bursts at random pitches and times) over a soft,
    /// low-passed "roar" of voices. Dense at the start, thinning out; no pitched buzz or harsh hiss.
    static func cheerSamples(duration: Double = 3.2) -> [Float] {
        var noise = Noise(s: 4242)
        let n = Int(duration * sampleRate)
        var out = [Float](repeating: 0, count: n)
        // Claps: rate follows a quick swell then a long decay (claps per second).
        var t = 0.0
        while t < duration {
            let swell = min(t / 0.25, 1) * exp(-max(t - 0.5, 0) * 0.85)
            let rate = 5 + 150 * swell
            t += -log(max(Double((noise.next() + 1) / 2), 1e-4)) / rate          // exponential inter-arrival time
            let start = Int(t * sampleRate), len = Int(0.03 * sampleRate)
            if start + len >= n { break }
            let amp = (0.25 + 0.75 * (noise.next() + 1) / 2) * Float(0.35 + 0.65 * swell)
            let f = 1200 + 1300 * (noise.next() + 1) / 2                            // 1.2–2.5 kHz: palm clap, not sizzle
            let w = 2 * Float.pi * f / Float(sampleRate), r: Float = 0.93
            var y1: Float = 0, y2: Float = 0
            for i in 0..<len {                                                      // two-pole resonator excited by a noise burst
                let x = noise.next() * expf(-Float(i) / Float(sampleRate) * 220)
                let y = x + 2 * r * cosf(w) * y1 - r * r * y2
                y2 = y1; y1 = y
                out[start + i] += y * amp * 0.07
            }
        }
        // Voices: slow-swelling, heavily low-passed noise (~300–700 Hz) with a gentle wobble.
        var lo: Float = 0, hi: Float = 0
        for i in 0..<n {
            let tt = Float(i) / Float(sampleRate)
            let x = noise.next(); lo += (x - lo) * 0.07; hi += (x - hi) * 0.025
            let env = min(tt / 0.4, 1) * expf(-max(tt - 0.5, 0) * 0.7)
            out[i] += (lo - hi) * env * (0.85 + 0.15 * sinf(2 * .pi * 3.1 * tt)) * 0.9
        }
        // Soften everything above ~5 kHz, fade the tail, normalise.
        var lp: Float = 0
        let tail = Int(0.4 * sampleRate)
        for i in 0..<n {
            lp += (out[i] - lp) * 0.55
            out[i] = lp * (i > n - tail ? Float(n - i) / Float(tail) : 1)
        }
        let peak = max(out.map { abs($0) }.max() ?? 1, 1e-4)
        return out.map { $0 / peak * 0.8 }
    }
    /// Seamless crowd murmur loop.
    static func crowdLoopSamples() -> [Float] {
        var noise = Noise(s: 31337); var a: Float = 0, b: Float = 0
        let n = Int(4.0 * sampleRate)
        var raw = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let x = noise.next(); a += (x - a) * 0.12; b += (x - b) * 0.015
            raw[i] = (a - b) * (0.7 + 0.3 * sinf(2 * .pi * 0.5 * Float(i) / Float(sampleRate)))
        }
        let fade = Int(0.25 * sampleRate)                                       // cross-fade the tail into the head so the loop has no click
        for i in 0..<fade { let w = Float(i) / Float(fade); raw[i] = raw[i] * w + raw[n - fade + i] * (1 - w) }
        return Array(raw[0..<(n - fade)])
    }

    // MARK: Engine
    private let engine = AVAudioEngine()
    private var pool: [AVAudioPlayerNode] = []
    private var next = 0
    private let crowdNode = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: GameAudio.sampleRate, channels: 1)!
    private var hits: [AVAudioPCMBuffer] = [], bounce: AVAudioPCMBuffer?, net: AVAudioPCMBuffer?, cheer: AVAudioPCMBuffer?, crowd: AVAudioPCMBuffer?
    private let speech = AVSpeechSynthesizer()
    private(set) var running = false
    var muted = false { didSet { engine.mainMixerNode.outputVolume = muted ? 0 : 1 } }

    private func buffer(_ s: [Float]) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(s.count))!
        b.frameLength = AVAudioFrameCount(s.count)
        s.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: s.count) }
        return b
    }

    init() {
        hits = [buffer(Self.hitSamples(hardness: 0.2, seed: 11)), buffer(Self.hitSamples(hardness: 0.6, seed: 12)), buffer(Self.hitSamples(hardness: 1.0, seed: 13))]
        bounce = buffer(Self.bounceSamples()); net = buffer(Self.netSamples()); cheer = buffer(Self.cheerSamples()); crowd = buffer(Self.crowdLoopSamples())
        for _ in 0..<10 {
            let n = AVAudioPlayerNode(); engine.attach(n); engine.connect(n, to: engine.mainMixerNode, format: format); pool.append(n)
        }
        engine.attach(crowdNode); engine.connect(crowdNode, to: engine.mainMixerNode, format: format)
        do {
            try engine.start(); running = true
            crowdNode.volume = 0.12
            if let c = crowd { crowdNode.scheduleBuffer(c, at: nil, options: .loops); crowdNode.play() }
        } catch { NSLog("Audio engine unavailable: \(error)") }
    }

    private func play(_ buf: AVAudioPCMBuffer?, volume: Float, pan: Float = 0) {
        guard running, !muted, let buf else { return }
        let node = pool[next]; next = (next + 1) % pool.count
        node.volume = volume; node.pan = simd_clamp(pan, -1, 1)
        node.scheduleBuffer(buf, at: nil, options: .interrupts)
        if !node.isPlaying { node.play() }
    }

    /// Reacts to a gameplay event.
    func handle(_ e: GameEvent) {
        switch e {
        case .hit(_, let speed, let quality, let shot, let pos):
            let hardness = simd_clamp((speed - 60) / 100, 0, 1)
            let idx = hardness < 0.33 ? 0 : (hardness < 0.66 ? 1 : 2)
            let soft: Float = (shot == .drop || shot == .slice) ? 0.75 : 1
            play(hits[idx], volume: (0.55 + 0.45 * hardness) * (0.8 + 0.2 * quality) * soft, pan: pos.x / 7)
        case .bounce(let pos, let speed): play(bounce, volume: simd_clamp(speed / 22, 0.15, 0.8), pan: pos.x / 7)
        case .net: play(net, volume: 0.6)
        case .netCord: play(net, volume: 0.35)
        case .point(let side): play(cheer, volume: side > 0 ? 0.8 : 0.55)
        case .fault, .letCall: break
        }
    }

    /// Crowd bed volume follows excitement (0…1).
    func setCrowd(level: Float) { crowdNode.volume = 0.06 + 0.5 * simd_clamp(level, 0, 1) * (muted ? 0 : 1) }

    /// The umpire's call.
    func speak(_ text: String) {
        guard !muted else { return }
        let u = AVSpeechUtterance(string: text)
        u.rate = 0.47; u.pitchMultiplier = 0.9; u.volume = 0.9
        speech.stopSpeaking(at: .word)
        speech.speak(u)
    }
}

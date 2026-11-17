import AVFoundation

/// Synthesised sound: a looping fire bed (rumble, hiss, crackle) and plucked-string cues.
/// The engine only runs while something is audible.
final class FireAudio {
    enum Cue { case focusEnded, breakEnded, allDone }

    private let engine = AVAudioEngine()
    private let fire = AVAudioPlayerNode()
    private let cue = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    private lazy var fireLoop = Self.makeFireLoop(format: format)
    private var wired = false
    private var fireOn = false
    private var cuesPlaying = 0
    var volume: Double = 0.6

    /// `level` 0…1 follows the flame so the fire quiets as it dies.
    func setFire(on: Bool, level: Double) {
        if on {
            guard start() else { return }
            if !fireOn {
                fireOn = true
                fire.scheduleBuffer(fireLoop, at: nil, options: .loops)
                fire.play()
            }
            fire.volume = Float(volume * (0.18 + 0.82 * min(1, max(0, level))))
        } else if fireOn {
            fireOn = false
            fire.stop()
            stopIfSilent()
        }
    }

    func play(_ c: Cue) {
        guard start() else { return }
        let buffer = Self.makeCue(c, format: format)
        cue.volume = Float(min(1, volume * 1.25))
        cuesPlaying += 1
        cue.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let self else { return }
                self.cuesPlaying -= 1
                self.stopIfSilent()
            }
        }
        cue.play()
    }

    private func start() -> Bool {
        if !wired {
            wired = true
            engine.attach(fire); engine.attach(cue)
            engine.connect(fire, to: engine.mainMixerNode, format: format)
            engine.connect(cue, to: engine.mainMixerNode, format: format)
        }
        if engine.isRunning { return true }
        do { try engine.start(); return true } catch {
            NSLog("Frontier: audio engine failed to start: \(error.localizedDescription)")
            return false
        }
    }

    private func stopIfSilent() {
        guard !fireOn, cuesPlaying <= 0, engine.isRunning else { return }
        cuesPlaying = 0
        engine.stop()
    }

    // MARK: Synthesis

    static func makeFireLoop(format: AVAudioFormat, seconds: Double = 14) -> AVAudioPCMBuffer {
        let sr = format.sampleRate
        let n = Int(sr * seconds), fade = Int(sr * 0.8)
        var rng = SeededRNG(seed: 0xF1AE)
        func white() -> Float { Float.random(in: -1...1, using: &rng) }
        var left = [Float](repeating: 0, count: n + fade), right = left

        // Bed: brown-noise rumble plus a breathing band of hiss.
        var brown: Float = 0, lp: Float = 0, breath: Float = 0.5
        for i in 0..<(n + fade) {
            let w = white()
            brown = (brown + 0.02 * w) / 1.02
            lp += 0.35 * (w - lp)
            if i % 2048 == 0 { breath = 0.92 * breath + 0.08 * Float.random(in: 0.2...1, using: &rng) }
            let s = brown * 2.6 + (w - lp) * 0.035 * (0.5 + breath)
            left[i] = s
            right[i] = s * 0.9 + brown * 0.3 * white() * 0.2
        }
        // Crackle: short bursts of filtered noise, mostly faint with the odd sharp pop.
        var t = 0.0
        while t < seconds + 0.5 {
            t += -log(Double.random(in: 0.0001...1, using: &rng)) / 11
            let start = Int(t * sr)
            let power = pow(Float.random(in: 0...1, using: &rng), 3.2)
            let pop = Float.random(in: 0...1, using: &rng) < 0.06
            let amp = (pop ? 0.55 : 0.05) + power * 0.38
            let decay = Float(sr) * (pop ? Float.random(in: 0.012...0.03, using: &rng) : Float.random(in: 0.0015...0.008, using: &rng))
            let len = Int(decay * 6), pan = Float.random(in: 0.15...0.85, using: &rng)
            let colour = Float.random(in: 0.25...0.9, using: &rng)
            var f: Float = 0
            for j in 0..<len where start + j < n + fade {
                f += colour * (white() - f)
                let s = (pop ? f : white() - f) * amp * exp(-Float(j) / decay)
                left[start + j] += s * (1 - pan)
                right[start + j] += s * pan
            }
        }
        // Crossfade the tail into the head so the loop has no seam.
        for i in 0..<fade {
            let a = Float(i) / Float(fade)
            left[i] = left[i] * a + left[n + i] * (1 - a)
            right[i] = right[i] * a + right[n + i] * (1 - a)
        }
        return buffer(left: left, right: right, count: n, format: format, gain: 0.5)
    }

    /// Karplus–Strong plucked string.
    static func pluck(_ freq: Double, seconds: Double, sr: Double, rng: inout SeededRNG) -> [Float] {
        let period = max(2, Int(sr / freq))
        var ring = (0..<period).map { _ in Float.random(in: -1...1, using: &rng) }
        // Soften the pick so it sounds like gut and wood, not wire.
        for i in 1..<period { ring[i] = 0.55 * ring[i] + 0.45 * ring[i - 1] }
        var out = [Float](repeating: 0, count: Int(sr * seconds))
        var idx = 0
        for i in 0..<out.count {
            let nxt = (idx + 1) % period
            out[i] = ring[idx]
            ring[idx] = 0.4985 * (ring[idx] + ring[nxt])
            idx = nxt
        }
        return out
    }

    static func makeCue(_ c: Cue, format: AVAudioFormat) -> AVAudioPCMBuffer {
        let sr = format.sampleRate
        // (frequency Hz, start s, gain, pan)
        let e2 = 82.41, b2 = 123.47, e3 = 164.81, g3 = 196.0, a3 = 220.0, b3 = 246.94, d4 = 293.66, e4 = 329.63, g4 = 392.0
        let notes: [(Double, Double, Float, Float)]
        switch c {
        case .focusEnded:   // a slow E-minor strum that settles down to the root
            notes = [(e2, 0, 0.9, 0.4), (b2, 0.09, 0.7, 0.45), (e3, 0.18, 0.7, 0.5), (g3, 0.27, 0.65, 0.55),
                     (b3, 0.36, 0.6, 0.6), (e4, 0.45, 0.6, 0.62), (d4, 1.45, 0.55, 0.55), (b3, 2.05, 0.55, 0.5),
                     (e3, 2.75, 0.7, 0.45), (e2, 2.78, 0.8, 0.4)]
        case .breakEnded:   // two rising notes: back in the saddle
            notes = [(e3, 0, 0.75, 0.45), (b3, 0.22, 0.7, 0.55), (e4, 0.44, 0.75, 0.55), (e2, 0.44, 0.6, 0.4)]
        case .allDone:      // longer, resolving phrase for the end of the day's work
            notes = [(e2, 0, 0.9, 0.4), (e3, 0.1, 0.7, 0.5), (g3, 0.5, 0.65, 0.55), (b3, 0.9, 0.65, 0.6),
                     (e4, 1.3, 0.7, 0.6), (g4, 1.9, 0.6, 0.62), (e4, 2.5, 0.6, 0.58), (d4, 2.9, 0.55, 0.52),
                     (b3, 3.3, 0.6, 0.5), (a3, 3.9, 0.55, 0.48), (b3, 4.3, 0.6, 0.5),
                     (e2, 5.1, 0.9, 0.4), (b2, 5.2, 0.7, 0.45), (e3, 5.3, 0.7, 0.5), (g3, 5.4, 0.6, 0.55), (e4, 5.5, 0.6, 0.6)]
        }
        let total = (notes.map { $0.1 }.max() ?? 0) + 4.5
        let n = Int(sr * total)
        var left = [Float](repeating: 0, count: n), right = left
        var rng = SeededRNG(seed: 0x6A17)
        for (freq, at, gain, pan) in notes {
            let s = pluck(freq, seconds: 4.2, sr: sr, rng: &rng)
            let off = Int(at * sr)
            for i in 0..<s.count where off + i < n {
                left[off + i] += s[i] * gain * (1 - pan)
                right[off + i] += s[i] * gain * pan
            }
        }
        // Room: a few cross-fed, darkening echoes baked into the buffer, so no live effect node
        // has to keep running (a reverb unit costs CPU even when it is fed silence).
        for (delay, fb) in [(0.137, Float(0.30)), (0.211, Float(0.24)), (0.331, Float(0.18))] {
            let d = Int(delay * sr)
            var lpL: Float = 0, lpR: Float = 0
            for i in d..<n {
                lpL += 0.35 * (right[i - d] - lpL)
                lpR += 0.35 * (left[i - d] - lpR)
                left[i] += lpL * fb
                right[i] += lpR * fb
            }
        }
        return buffer(left: left, right: right, count: n, format: format, gain: 0.5)
    }

    private static func buffer(left: [Float], right: [Float], count: Int, format: AVAudioFormat, gain: Float) -> AVAudioPCMBuffer {
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buf.frameLength = AVAudioFrameCount(count)
        let l = buf.floatChannelData![0], r = buf.floatChannelData![1]
        for i in 0..<count {
            l[i] = max(-1, min(1, left[i] * gain))
            r[i] = max(-1, min(1, right[i] * gain))
        }
        return buf
    }
}

import Accelerate
import CoreAudio
import Foundation
import os

/// Turns captured audio into 19 spectrum bars (with falling peaks) and a 76-point oscilloscope.
/// `ingest` runs on the audio IO queue; everything else runs on the main thread.
final class Analyzer: @unchecked Sendable {
    static let fftSize = 2048
    static let bandCount = 19
    static let oscPoints = 76

    // Shared with the IO queue (guarded by `lock`).
    private let capacity = 8192
    private let ring: UnsafeMutablePointer<Float>
    private var writePos = 0
    private var lastInputNs: UInt64 = 0
    private var lastSignalNs: UInt64 = 0
    private var acceptsFloat = true
    private let lock = OSAllocatedUnfairLock()

    // Main-thread state.
    private(set) var sampleRate: Double = 44_100
    private let log2n: vDSP_Length = 11
    private let fft: FFTSetup
    private var window: [Float]
    private var frame: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var mags: [Float]
    private var dbs = [Float](repeating: -200, count: Analyzer.bandCount)
    private var agcRef: Float = -30
    private var oscGain: Float = 2
    private var peakHold = [Double](repeating: 0, count: Analyzer.bandCount)
    private(set) var bars = [Double](repeating: 0, count: Analyzer.bandCount)
    private(set) var peaks = [Double](repeating: 0, count: Analyzer.bandCount)
    private(set) var osc = [Int](repeating: 8, count: Analyzer.oscPoints)

    /// Log-spaced band edges, 40 Hz … 16 kHz.
    private static let edges: [Double] = (0...bandCount).map { 40 * pow(400, Double($0) / Double(bandCount)) }
    /// Treble boost so typical music fills the display evenly (≈2.5 dB per octave).
    private static let tilt: [Float] = (0..<bandCount).map { b in
        Float(2.5 * log2(sqrt(edges[b] * edges[b + 1]) / 40))
    }

    init() {
        ring = .allocate(capacity: capacity)
        ring.initialize(repeating: 0, count: capacity)
        fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        let n = Self.fftSize
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        frame = [Float](repeating: 0, count: n)
        windowed = [Float](repeating: 0, count: n)
        real = [Float](repeating: 0, count: n / 2)
        imag = [Float](repeating: 0, count: n / 2)
        mags = [Float](repeating: 0, count: n / 2)
    }

    deinit {
        ring.deallocate()
        vDSP_destroy_fftsetup(fft)
    }

    private static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    func configure(sampleRate: Double, isFloat: Bool) {
        if sampleRate > 0 { self.sampleRate = sampleRate }
        lock.lock(); acceptsFloat = isFloat; lock.unlock()
    }

    func resetInputClock() {
        lock.lock()
        lastInputNs = Self.now()
        lastSignalNs = lastInputNs
        lock.unlock()
    }

    /// Seconds since the IO block last delivered a buffer (0 if capture never started).
    var secondsSinceInput: Double {
        lock.lock(); defer { lock.unlock() }
        return lastInputNs == 0 ? 0 : Double(Self.now() &- lastInputNs) / 1e9
    }

    /// Seconds since a buffer that wasn't pure digital silence.
    var secondsSinceSignal: Double {
        lock.lock(); defer { lock.unlock() }
        return lastSignalNs == 0 ? 0 : Double(Self.now() &- lastSignalNs) / 1e9
    }

    // MARK: IO queue

    func ingest(_ list: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard buffers.count > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard acceptsFloat else { return }
        let mask = capacity - 1
        var loud = false
        if buffers.count == 1 {
            // Interleaved: average all channels.
            let b = buffers[0]
            guard let raw = b.mData else { return }
            let data = raw.assumingMemoryBound(to: Float.self)
            let ch = max(1, Int(b.mNumberChannels))
            let frames = Int(b.mDataByteSize) / (MemoryLayout<Float>.size * ch)
            let scale = 1 / Float(ch)
            for f in 0..<frames {
                var s: Float = 0
                for c in 0..<ch { s += data[f * ch + c] }
                s *= scale
                if s > 1e-5 || s < -1e-5 { loud = true }
                ring[writePos] = s
                writePos = (writePos + 1) & mask
            }
        } else {
            // Non-interleaved: average the first two channel buffers.
            let a = buffers[0], b = buffers[1]
            guard let ra = a.mData, let rb = b.mData else { return }
            let da = ra.assumingMemoryBound(to: Float.self), db = rb.assumingMemoryBound(to: Float.self)
            let frames = Int(min(a.mDataByteSize, b.mDataByteSize)) / MemoryLayout<Float>.size
            for f in 0..<frames {
                let s = (da[f] + db[f]) * 0.5
                if s > 1e-5 || s < -1e-5 { loud = true }
                ring[writePos] = s
                writePos = (writePos + 1) & mask
            }
        }
        let t = Self.now()
        lastInputNs = t
        if loud { lastSignalNs = t }
    }

    // MARK: Main thread

    /// Advances the display by `dt` seconds using the newest audio.
    func update(dt: Double) {
        let n = Self.fftSize
        var fresh = false
        lock.lock()
        if lastInputNs != 0, Self.now() &- lastInputNs < 150_000_000 {
            fresh = true
            var idx = (writePos - n) & (capacity - 1)
            for i in 0..<n {
                frame[i] = ring[idx]
                idx = (idx + 1) & (capacity - 1)
            }
        }
        lock.unlock()
        if !fresh { vDSP_vclr(&frame, 1, vDSP_Length(n)) }
        updateBars(dt: dt)
        updateOscilloscope()
    }

    private func updateBars(dt: Double) {
        let n = Self.fftSize
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(n))
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                ip[0] = 0  // packed Nyquist term
                mags.withUnsafeMutableBufferPointer { mp in
                    vDSP_zvabs(&split, 1, mp.baseAddress!, 1, vDSP_Length(n / 2))
                }
            }
        }

        // vDSP's real FFT is scaled by 2, and the Hann window has a coherent gain of 0.5,
        // so |Z| / (N/2) is the amplitude of a sine (1.0 = full scale).
        let norm = Float(n) / 2
        let binHz = sampleRate / Double(n)
        var loudest: Float = -200
        for b in 0..<Self.bandCount {
            let kLo = max(1, Int(Self.edges[b] / binHz))
            let kHi = min(n / 2 - 1, max(kLo, Int(Self.edges[b + 1] / binHz)))
            var amp: Float = 0
            for k in kLo...kHi { amp = max(amp, mags[k]) }
            let db = 20 * log10f(max(amp / norm, 1e-7)) + Self.tilt[b]
            dbs[b] = db
            loudest = max(loudest, db)
        }
        // Slow automatic gain so the display works at any Spotify volume.
        agcRef = min(12, max(-38, max(loudest, agcRef - Float(3 * dt))))
        let range: Float = 48
        for b in 0..<Self.bandCount {
            let target = Double(max(0, min(16, 16 * (dbs[b] - (agcRef - range)) / range)))
            bars[b] = target > bars[b] ? target : max(target, bars[b] - 40 * dt)
            if bars[b] >= peaks[b] {
                peaks[b] = bars[b]
                peakHold[b] = 0.4
            } else if peakHold[b] > 0 {
                peakHold[b] -= dt
            } else {
                peaks[b] = max(0, peaks[b] - 12 * dt)
            }
        }
    }

    private func updateOscilloscope() {
        let n = Self.fftSize, count = 576
        var maxAbs: Float = 0
        frame.withUnsafeBufferPointer { p in
            vDSP_maxmgv(p.baseAddress! + (n - count), 1, &maxAbs, vDSP_Length(count))
        }
        let target = min(8, 0.9 / max(0.08, maxAbs))
        oscGain += (target - oscGain) * 0.2
        for x in 0..<Self.oscPoints {
            let s = frame[n - count + x * count / Self.oscPoints]
            osc[x] = max(0, min(15, Int((7.5 - s * oscGain * 7.5).rounded())))
        }
    }

    /// Fixed, good-looking frame for headless snapshots.
    func loadDemo() {
        for i in 0..<Self.bandCount {
            let x = Double(i)
            bars[i] = max(1, min(16, 9 + 5 * sin(x * 0.9) + 3 * cos(x * 0.37) - x * 0.2))
            peaks[i] = min(16, bars[i] + 1 + Double(i % 3))
        }
        for x in 0..<Self.oscPoints {
            let t = Double(x) / Double(Self.oscPoints) * 2 * .pi
            osc[x] = Int((7.5 - 6 * sin(t * 2) * (0.6 + 0.4 * cos(t * 5))).rounded())
        }
    }
}

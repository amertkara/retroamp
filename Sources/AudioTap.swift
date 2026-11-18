import CoreAudio
import Foundation

/// Captures Spotify's audio output with a Core Audio process tap (macOS 14.2+) and feeds the
/// analyzer. Uses a private, tap-only aggregate device (no microphone or output sub-device).
/// macOS asks for "System Audio Recording" permission the first time capture starts.
///
/// Not main-actor isolated on purpose: the IO block runs on `ioQueue`. `maintain()`,
/// `start()` and `stop()` must be called from the main thread.
final class AudioTap: @unchecked Sendable {
    enum Status: Equatable { case idle, waitingForSpotify, running, failed(OSStatus) }

    let analyzer: Analyzer
    private(set) var status: Status = .idle
    private(set) var sampleRate: Double = 0

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tappedProcesses: [AudioObjectID] = []
    private var nextAttempt: TimeInterval = 0
    private var lastStart: TimeInterval = 0
    private var silentRestarts = 0
    private let ioQueue = DispatchQueue(label: "local.retroamp.audiotap", qos: .userInteractive)

    init(analyzer: Analyzer) { self.analyzer = analyzer }

    /// Call about once a second: starts the tap when Spotify shows up and rebuilds it when
    /// Spotify's audio processes change or the stream stalls during playback.
    func maintain(spotifyRunning: Bool, playing: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard spotifyRunning else {
            if status == .running { stop() }
            status = .waitingForSpotify
            return
        }
        if status == .running {
            let current = Self.spotifyProcesses()
            if !current.isEmpty, Set(current) != Set(tappedProcesses) { start(); return }
            guard playing else { return }
            if analyzer.secondsSinceSignal < 1 { silentRestarts = 0; return }
            // No callbacks at all, or only silence (e.g. the permission prompt was answered after
            // capture started). Rebuild, but not over and over if permission was denied.
            let stalled = analyzer.secondsSinceInput > 3
            let silent = analyzer.secondsSinceSignal > 8 && silentRestarts < 2
            if stalled || silent, now - lastStart > 15 {
                if !stalled { silentRestarts += 1 }
                start()
            }
            return
        }
        guard now >= nextAttempt else { return }
        nextAttempt = now + 2
        start()
    }

    func start() {
        stop()
        lastStart = ProcessInfo.processInfo.systemUptime
        let processes = Self.spotifyProcesses()
        guard !processes.isEmpty else { status = .waitingForSpotify; return }

        let desc = CATapDescription(stereoMixdownOfProcesses: processes)
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        desc.name = "Retroamp visualizer"

        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(desc, &tap)
        guard err == noErr else { fail(err); return }
        tapID = tap

        let tapUID = Self.string(tap, kAudioTapPropertyUID) ?? desc.uuid.uuidString
        if let fmt = Self.tapFormat(tap) {
            sampleRate = fmt.mSampleRate
            analyzer.configure(sampleRate: fmt.mSampleRate, isFloat: fmt.mFormatFlags & kAudioFormatFlagIsFloat != 0)
        }

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Retroamp Tap",
            kAudioAggregateDeviceUIDKey: "local.retroamp.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &agg)
        guard err == noErr else { fail(err); return }
        aggregateID = agg

        // Attach the tap (Apple's "Capturing system audio with Core Audio taps" approach).
        var address = AudioObjectPropertyAddress(mSelector: kAudioAggregateDevicePropertyTapList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var tapList = [tapUID] as CFArray
        err = withUnsafeMutablePointer(to: &tapList) {
            AudioObjectSetPropertyData(agg, &address, 0, nil, UInt32(MemoryLayout<CFArray>.size), $0)
        }
        guard err == noErr else { fail(err); return }

        let analyzer = self.analyzer
        var proc: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, ioQueue) { _, input, _, _, _ in
            analyzer.ingest(input)
        }
        guard err == noErr, let proc else { fail(err); return }
        procID = proc

        analyzer.resetInputClock()
        err = AudioDeviceStart(agg, proc)
        guard err == noErr else { fail(err); return }
        tappedProcesses = processes
        status = .running
    }

    func stop() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        tappedProcesses = []
        if status == .running { status = .idle }
    }

    private func fail(_ err: OSStatus) {
        NSLog("Retroamp audio tap failed: %d", err)
        stop()
        status = .failed(err)
        nextAttempt = ProcessInfo.processInfo.systemUptime + 10
    }

    // MARK: HAL helpers

    /// Audio process objects whose bundle ID starts with com.spotify.client (app and helpers).
    static func spotifyProcesses() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { (string($0, kAudioProcessPropertyBundleID) ?? "").hasPrefix(SpotifyBridgeID.bundleID) }
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    static func tapFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var fmt = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &fmt) == noErr else { return nil }
        return fmt
    }
}

/// Bundle ID shared with non-main-actor code.
enum SpotifyBridgeID { static let bundleID = "com.spotify.client" }

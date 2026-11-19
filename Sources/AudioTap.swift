import CoreAudio
import Foundation

/// Captures Spotify's audio output with a Core Audio process tap (macOS 14.2+) and feeds the
/// analyzer. macOS asks for "System Audio Recording" permission the first time capture starts.
///
/// The tap sits in a private aggregate device that a real output device clocks, as in Apple's
/// sample code. On macOS 26 an aggregate device that holds only the tap fails to start:
/// coreaudiod logs "no master engine info" and AudioDeviceStart returns 'nope'. The clock is
/// always an output-only device, because a headset would bring its microphone along, and a
/// Bluetooth headset would drop into its call profile. If there is no such device, or the
/// clocked device won't start, the tap-only layout is tried as well.
///
/// Capture runs only while Spotify is sending audio, so the clock device can sleep otherwise.
///
/// Not main-actor isolated on purpose: the IO block runs on `ioQueue`. `maintain()`,
/// `start()` and `stop()` must be called from the main thread.
final class AudioTap: @unchecked Sendable {
    enum Status: Equatable { case idle, waitingForSpotify, running, failed(OSStatus) }

    /// An audio device, as far as choosing a clock goes.
    struct Device: Equatable {
        var id: AudioObjectID
        var uid: String
        var inputs = 0
        var outputs = 0
        var transport: UInt32 = 0
        var alive = true
        var hidden = false
    }

    /// Seconds of quiet from Spotify before capture stops.
    static let idleStop: TimeInterval = 20

    let analyzer: Analyzer
    private(set) var status: Status = .idle
    /// Sample rate of the captured audio (kept after capture stops, for the kHz display).
    private(set) var sampleRate: Double = 0
    /// Whether one of Spotify's audio processes is playing to an output (polled by `maintain`).
    private(set) var spotifyOutputActive = false
    /// Starts that failed in a row.
    private(set) var failedStarts = 0
    /// The device clocking the running capture, or nil when the aggregate holds only the tap.
    private(set) var clock: Device?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tappedProcesses: [AudioObjectID] = []
    private var defaultOutputAtStart = AudioObjectID(kAudioObjectUnknown)
    private var preferTapOnly = false
    private var nextAttempt: TimeInterval = 0
    private var lastStart: TimeInterval = 0
    private var lastOutput: TimeInterval = 0
    private var silentRestarts = 0
    private var isSpotify: [AudioObjectID: Bool] = [:]  // process object → bundle ID matches
    private let ioQueue = DispatchQueue(label: "local.retroamp.audiotap", qos: .userInteractive)

    init(analyzer: Analyzer) { self.analyzer = analyzer }

    /// Call about once a second. Starts capture when Spotify starts sending audio and stops it
    /// once Spotify has been quiet for `idleStop` seconds. Rebuilds it when Spotify's audio
    /// processes or the default output device change, or when the stream stalls during playback.
    func maintain(spotifyRunning: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard spotifyRunning else {
            stop()
            spotifyOutputActive = false
            status = .waitingForSpotify
            return
        }
        let processes = spotifyProcesses()
        spotifyOutputActive = processes.contains { Self.uint32($0, kAudioProcessPropertyIsRunningOutput) == 1 }
        if spotifyOutputActive { lastOutput = now }

        if status == .running {
            if now - lastOutput > Self.idleStop { stop(); return }
            if !processes.isEmpty, Set(processes) != Set(tappedProcesses) { start(processes); return }
            if Self.defaultOutputDevice() != defaultOutputAtStart { start(processes); return }
            guard spotifyOutputActive else { return }
            if analyzer.secondsSinceSignal < 1 { silentRestarts = 0; return }
            // No callbacks at all, or only silence (e.g. the permission prompt was answered after
            // capture started). Rebuild, but not over and over if permission was denied. A layout
            // that started but never called back is tried second next time.
            let stalled = analyzer.secondsSinceInput > 3
            let silent = analyzer.secondsSinceSignal > 8 && silentRestarts < 2
            if stalled || silent, now - lastStart > 15 {
                if stalled { preferTapOnly = clock != nil } else { silentRestarts += 1 }
                start(processes)
            }
            return
        }
        guard spotifyOutputActive, now >= nextAttempt else { return }
        nextAttempt = now + 2
        start(processes)
    }

    func start(_ processes: [AudioObjectID]? = nil) {
        stop()
        lastStart = ProcessInfo.processInfo.systemUptime
        let processes = processes ?? spotifyProcesses()
        guard !processes.isEmpty else { status = .waitingForSpotify; return }

        // Clocked by an output device first, then tap-only. The order flips once tap-only has
        // worked where the clocked layout failed.
        defaultOutputAtStart = Self.defaultOutputDevice()
        let candidate = Self.clockDevice()
        var layouts: [Device?] = candidate == nil ? [nil] : [candidate, nil]
        if preferTapOnly { layouts.reverse() }
        var err: OSStatus = noErr
        for layout in layouts {
            let name = layout.map { "clocked by \($0.uid)" } ?? "tap only"
            err = open(processes, clock: layout)
            if err == noErr {
                preferTapOnly = layout == nil && candidate != nil
                tappedProcesses = processes
                clock = layout
                failedStarts = 0
                status = .running
                NSLog("%@", "Retroamp audio tap running, \(name), \(Int(sampleRate)) Hz")
                return
            }
            NSLog("%@", "Retroamp audio tap failed to start, \(name): \(Self.describe(err))")
            teardown()
        }
        failedStarts += 1
        status = .failed(err)
        nextAttempt = ProcessInfo.processInfo.systemUptime + 10
    }

    func stop() {
        teardown()
        tappedProcesses = []
        clock = nil
        if status == .running { status = .idle }
    }

    /// Creates the tap, an aggregate device around it and an IO proc, and starts the device.
    private func open(_ processes: [AudioObjectID], clock: Device?) -> OSStatus {
        let desc = CATapDescription(stereoMixdownOfProcesses: processes)
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        desc.name = "Retroamp visualizer"

        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(desc, &tap)
        guard err == noErr else { return err }
        tapID = tap

        let description = Self.aggregateDescription(tapUID: desc.uuid.uuidString, clock: clock)
        var agg = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &agg)
        guard err == noErr else { return err }
        aggregateID = agg

        // The IO proc gets the aggregate device's format, whose rate follows the clock device.
        let tapFormat = Self.tapFormat(tap)
        let streamFormat = Self.inputFormat(agg)
        let rate = [streamFormat?.mSampleRate, Self.float64(agg, kAudioDevicePropertyNominalSampleRate), tapFormat?.mSampleRate]
            .compactMap { $0 }.first { $0 > 0 } ?? 0
        let flags = (streamFormat ?? tapFormat)?.mFormatFlags ?? kAudioFormatFlagIsFloat
        analyzer.configure(sampleRate: rate, isFloat: flags & kAudioFormatFlagIsFloat != 0)

        let analyzer = self.analyzer
        var proc: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, ioQueue) { _, input, _, _, _ in
            analyzer.ingest(input)
        }
        guard err == noErr, let proc else { return err == noErr ? kAudioHardwareUnspecifiedError : err }
        procID = proc

        analyzer.resetInputClock()
        err = AudioDeviceStart(agg, proc)
        if err == noErr { sampleRate = rate }
        return err
    }

    /// Destroys whatever `open` created, newest first.
    private func teardown() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// The aggregate device's composition. The tap is part of it, so the device is complete
    /// when it's created; attaching the tap afterwards (kAudioAggregateDevicePropertyTapList)
    /// races the start.
    static func aggregateDescription(tapUID: String, clock: Device?) -> [String: Any] {
        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Retroamp Tap",
            kAudioAggregateDeviceUIDKey: "local.retroamp.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true] as [String: Any]],
        ]
        if let clock {
            description[kAudioAggregateDeviceMainSubDeviceKey] = clock.uid
            description[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: clock.uid]]
        }
        return description
    }

    // MARK: Clock device

    /// The device to clock capture with: the default output device if it has no inputs, else an
    /// output-only built-in device, else any other output-only device. Never an aggregate device,
    /// and AirPlay only as the default output: starting it would connect to a receiver.
    static func pickClock(defaultOutput: AudioObjectID, devices: [Device]) -> Device? {
        let usable = devices.filter {
            $0.outputs > 0 && $0.inputs == 0 && $0.alive && !$0.hidden && !$0.uid.isEmpty
                && $0.transport != kAudioDeviceTransportTypeAggregate
        }
        if let device = usable.first(where: { $0.id == defaultOutput }) { return device }
        let others = usable.filter { $0.transport != kAudioDeviceTransportTypeAirPlay }
        return others.first { $0.transport == kAudioDeviceTransportTypeBuiltIn } ?? others.first
    }

    static func clockDevice() -> Device? {
        let devices = objectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).map { id in
            Device(id: id, uid: string(id, kAudioDevicePropertyDeviceUID) ?? "",
                   inputs: objectIDs(id, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput).count,
                   outputs: objectIDs(id, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput).count,
                   transport: uint32(id, kAudioDevicePropertyTransportType) ?? 0,
                   alive: uint32(id, kAudioDevicePropertyDeviceIsAlive) != 0,
                   hidden: uint32(id, kAudioDevicePropertyIsHidden) == 1)
        }
        return pickClock(defaultOutput: defaultOutputDevice(), devices: devices)
    }

    static func defaultOutputDevice() -> AudioObjectID {
        objectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice).first
            ?? AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: Spotify's processes

    /// Audio process objects whose bundle ID starts with com.spotify.client (app and helpers).
    /// Bundle IDs are cached per object, since this runs every second.
    private func spotifyProcesses() -> [AudioObjectID] {
        let all = Self.objectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        var known: [AudioObjectID: Bool] = [:]
        for id in all {
            if let cached = isSpotify[id] {
                known[id] = cached
            } else if let bundle = Self.string(id, kAudioProcessPropertyBundleID) {
                known[id] = bundle.hasPrefix(SpotifyBridgeID.bundleID)
            }
        }
        isSpotify = known
        return all.filter { known[$0] == true }
    }

    // MARK: HAL helpers

    /// An OSStatus as its four-character code, if it has one ('nope' for 1852797029).
    static func fourCC(_ err: OSStatus) -> String? {
        let bits = UInt32(bitPattern: err)
        let bytes = [24, 16, 8, 0].map { UInt8((bits >> UInt32($0)) & 0xff) }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func describe(_ err: OSStatus) -> String {
        fourCC(err).map { "'\($0)' (\(err))" } ?? String(err)
    }

    static func objectIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func float64(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Double? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
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
        format(tap, kAudioTapPropertyFormat)
    }

    /// The format of a device's first input stream: the tap's, since the clock has no inputs.
    static func inputFormat(_ device: AudioObjectID) -> AudioStreamBasicDescription? {
        objectIDs(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput).first
            .flatMap { format($0, kAudioStreamPropertyVirtualFormat) }
    }

    private static func format(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var fmt = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &fmt) == noErr else { return nil }
        return fmt
    }
}

/// Bundle ID shared with non-main-actor code.
enum SpotifyBridgeID { static let bundleID = "com.spotify.client" }

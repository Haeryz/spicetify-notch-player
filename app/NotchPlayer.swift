// Notch Player — native macOS companion for the "Notch Player" Spicetify extension.
// Draws a Dynamic-Island style player fused to the MacBook's physical notch.
// Data comes from the Spicetify extension over a local WebSocket (127.0.0.1:47823).

import AppKit
import SwiftUI
import Network
import CoreImage
import ServiceManagement
import AVFoundation
import Accelerate

let kPort: UInt16 = 47823

// MARK: - Model

struct LyricLine: Decodable, Equatable { let t: Double; let w: String }

struct NextTrack: Decodable, Equatable { let title: String; let artist: String; let art: String? }

/// Spotify audio analysis, compacted by the extension and sent once per track.
/// segs: [startMs, durMs, loudnessStart, loudnessMax, loudnessMaxTimeMs, band0…band3]; beats: [startMs].
struct Viz: Decodable, Equatable {
    let uri: String
    let segs: [[Double]]
    let beats: [Double]

    private static func last(_ xs: [Double], _ pos: Double) -> Int {
        var lo = 0, hi = xs.count - 1
        guard hi >= 0, xs[0] <= pos else { return -1 }
        while lo < hi { let mid = (lo + hi + 1) / 2; if xs[mid] <= pos { lo = mid } else { hi = mid - 1 } }
        return lo
    }

    /// Four bar levels (0…1) for the given playback position in ms.
    func levels(at pos: Double) -> [Double]? {
        guard !segs.isEmpty else { return nil }
        var lo = 0, hi = segs.count - 1
        while lo < hi { let mid = (lo + hi + 1) / 2; if segs[mid][0] <= pos { lo = mid } else { hi = mid - 1 } }
        let sg = segs[lo]
        guard sg.count >= 9 else { return nil }
        let local = max(0, pos - sg[0]), peakAt = max(1, sg[4]), dur = max(peakAt + 1, sg[1])
        let nextStart = lo + 1 < segs.count ? segs[lo + 1][2] : -60
        // loudness envelope: rise to the segment's peak, then decay toward the next segment's start
        let loud = local < peakAt ? sg[2] + (sg[3] - sg[2]) * local / peakAt
                                  : sg[3] + (nextStart - sg[3]) * min(1, (local - peakAt) / (dur - peakAt))
        let level = pow(min(1, max(0, (loud + 35) / 30)), 1.3)
        let b = Self.last(beats, pos)
        let pulse = b >= 0 ? exp(-(pos - beats[b]) / 150) : 0
        return (0..<4).map { k in min(1, 0.12 + 0.88 * level * (0.55 + 0.45 * sg[5 + k]) * (0.6 + 0.6 * pulse)) }
    }
}

struct PlayerState: Decodable, Equatable {
    var uri: String = ""
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var art: String? = nil
    var albumUri: String? = nil
    var artistUri: String? = nil
    var duration: Double = 0      // ms
    var position: Double = 0      // ms at `ts`
    var ts: Double = 0            // JS epoch ms when position was sampled
    var playing: Bool = false
    var shuffle: Bool = false
    var repeatMode: Int = 0
    var liked: Bool = false
    var volume: Double = 1
    var device: String = ""
    var next: NextTrack? = nil
    var lyrics: [LyricLine]? = nil
    var viz: Viz? = nil
}

final class NotchModel: ObservableObject {
    @Published var state = PlayerState()
    @Published var connected = false
    @Published var expanded = false {
        didSet {
            guard expanded != oldValue else { return }
            unmountWork?.cancel()
            if expanded { contentMounted = true; return }
            // Keep the expanded content in the tree while the island closes so it can fade out
            // on the same spring as the shape (a removal transition here was dropped instantly).
            let w = DispatchWorkItem { [weak self] in self?.contentMounted = false }
            unmountWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
        }
    }
    @Published var contentMounted = false
    let audio = AudioLevels()                   // live spectrum from the Spotify audio tap
    private var unmountWork: DispatchWorkItem?
    @Published var artwork: NSImage? = nil
    @Published var nextArtwork: NSImage? = nil
    @Published var accent: Color = Color(red: 0.12, green: 0.84, blue: 0.38)
    @Published var seekDrag: Double? = nil
    @Published var ambient: NSImage? = nil      // blurred, saturated art for the expanded backdrop
    @Published var artKey = ""                  // changes when new artwork has actually loaded
    @Published var flash = false                // brief title pulse in the compact pill on song change
    private var flashWork: DispatchWorkItem?
    var deviceOverride: String?                 // --snap: keep personal device names out of screenshots

    var send: (([String: Any]) -> Void)?
    private var artURL: String?
    private var nextArtURL: String?

    var hasTrack: Bool { connected && !state.title.isEmpty }

    /// Exact height of the expanded content (every row has a fixed height), so the island's
    /// shape and its content animate in one pass instead of resizing again after layout.
    var openBodyH: CGFloat {
        var h = kRowTop + kGap + kRowSeek + kGap + kRowCtrl + kPadBottom
        if state.lyrics?.isEmpty == false { h += kRowLyrics + kGap }
        if state.next != nil { h += kRowNext + kGap }
        return h
    }

    func currentPosition(at date: Date = Date()) -> Double {
        guard state.playing else { return state.position }
        let now = date.timeIntervalSince1970 * 1000
        return min(state.duration, state.position + max(0, now - state.ts))
    }

    func apply(_ incoming: PlayerState) {
        var s = incoming
        let songChanged = !state.uri.isEmpty && s.uri != state.uri
        if s.viz == nil && s.uri == state.uri { s.viz = state.viz }   // analysis is only sent once per track
        state = s
        if let d = deviceOverride { state.device = d }
        if s.art != artURL { artURL = s.art; let url = s.art ?? ""; load(s.art) { [weak self] img in
            guard let self, self.artURL ?? "" == url else { return }
            self.artwork = img
            self.ambient = img.flatMap(Self.ambient(of:))
            if let img { self.accent = Self.accent(of: img) }
            self.artKey = url
        } }
        if s.next?.art != nextArtURL { nextArtURL = s.next?.art; load(s.next?.art) { [weak self] in self?.nextArtwork = $0 } }
        // Song change only pulses the compact pill — it never opens the full player.
        if songChanged && !expanded { flashTitle() }
    }

    func flashTitle() {
        flashWork?.cancel()
        flash = true
        let w = DispatchWorkItem { [weak self] in self?.flash = false }
        flashWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8, execute: w)
    }

    /// Tiny, heavily blurred and saturated copy of the artwork for the ambient glow.
    static func ambient(of image: NSImage) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var ci = CIImage(cgImage: cg)
        let scale = 64 / max(ci.extent.width, ci.extent.height, 1)
        ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let ext = ci.extent
        ci = ci.clampedToExtent()
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.7, kCIInputBrightnessKey: -0.08])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 9])
            .cropped(to: ext)
        guard let out = CIContext().createCGImage(ci, from: ext) else { return nil }
        return NSImage(cgImage: out, size: ext.size)
    }

    func command(_ cmd: String, _ extra: [String: Any] = [:]) {
        var m = extra; m["cmd"] = cmd
        send?(m)
    }

    private func load(_ url: String?, _ done: @escaping (NSImage?) -> Void) {
        guard let url, let u = URL(string: url) else { done(nil); return }
        URLSession.shared.dataTask(with: u) { data, _, _ in
            let img = data.flatMap { NSImage(data: $0) }
            DispatchQueue.main.async { done(img) }
        }.resume()
    }

    static func accent(of image: NSImage) -> Color {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .green }
        let ci = CIImage(cgImage: cg)
        let filter = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: ci.extent)])!
        var px = [UInt8](repeating: 0, count: 4)
        CIContext().render(filter.outputImage!, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let ns = NSColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.usingColorSpace(.deviceRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // Lift it so it reads well on black.
        return Color(hue: Double(h), saturation: Double(max(0.45, min(1, s * 1.6))), brightness: Double(max(0.8, b)))
    }
}

// MARK: - WebSocket bridge

final class Bridge {
    private var listener: NWListener?
    private var conns: [ObjectIdentifier: NWConnection] = [:]
    private let model: NotchModel
    private let q = DispatchQueue(label: "notch.bridge")

    init(model: NotchModel) {
        self.model = model
        model.send = { [weak self] msg in self?.broadcast(msg) }
    }

    func start() {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: kPort)!)
        params.allowLocalEndpointReuse = true
        do { listener = try NWListener(using: params) } catch { NSLog("NotchPlayer: listen failed \(error)"); return }
        listener?.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener?.start(queue: q)
    }

    private func accept(_ c: NWConnection) {
        let id = ObjectIdentifier(c)
        conns[id] = c
        c.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed, .cancelled: self?.drop(id)
            default: break
            }
        }
        c.start(queue: q)
        receive(c)
        DispatchQueue.main.async { self.model.connected = true }
    }

    private func drop(_ id: ObjectIdentifier) {
        conns[id] = nil
        let empty = conns.isEmpty
        DispatchQueue.main.async { if empty { self.model.connected = false } }
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, ctx, _, err in
            guard let self else { return }
            if err != nil { c.cancel(); return }
            if let meta = ctx?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata, meta.opcode == .close {
                c.cancel(); return
            }
            if let data, !data.isEmpty, let s = try? JSONDecoder().decode(PlayerState.self, from: data) {
                DispatchQueue.main.async { self.model.connected = true; self.model.apply(s) }
            }
            self.receive(c)
        }
    }

    func broadcast(_ msg: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        q.async {
            let meta = NWProtocolWebSocket.Metadata(opcode: .text)
            let ctx = NWConnection.ContentContext(identifier: "cmd", metadata: [meta])
            for c in self.conns.values { c.send(content: data, contentContext: ctx, isComplete: true, completion: .idempotent) }
        }
    }
}

// MARK: - Live audio (Core Audio process tap on Spotify → FFT → 4 frequency bands)

/// Band levels written from the audio thread, kept as a short timestamped history so the
/// visualizer can show the moment you actually *hear*: the tap sees audio before it leaves the
/// output device (Bluetooth headphones add ~150–350 ms), so reads are delayed by that latency.
final class AudioLevels {
    private let lock = NSLock()
    private static let size = 512   // ~5 s of callbacks
    private var times = [CFAbsoluteTime](repeating: 0, count: AudioLevels.size)
    private var bands = [SIMD4<Float>](repeating: .zero, count: AudioLevels.size)
    private var head = 0
    private var latency: Double = 0

    func set(_ b: SIMD4<Float>) {
        lock.lock()
        head = (head + 1) % Self.size
        times[head] = CFAbsoluteTimeGetCurrent(); bands[head] = b
        lock.unlock()
    }

    func setOutputLatency(_ seconds: Double) { lock.lock(); latency = seconds; lock.unlock() }
    var outputLatency: Double { lock.lock(); defer { lock.unlock() }; return latency }

    /// Levels for what is audible right now; nil when the tap isn't delivering audio.
    func current() -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - times[head] < 0.3 else { return nil }
        let target = now - latency
        var i = head
        for _ in 0..<Self.size {
            if times[i] <= target { let b = bands[i]; return [b[0], b[1], b[2], b[3]] }
            i = (i - 1 + Self.size) % Self.size
        }
        return nil
    }
}

/// Windowed FFT over the most recent 2048 mono samples, reduced to 4 log-spaced bands
/// (bass, low-mid, high-mid, treble) with fast attack / slower release, like a hardware meter.
final class Spectrum {
    static let n = 2048
    private let fft = vDSP.FFT(log2n: 11, radix: .radix2, ofType: DSPSplitComplex.self)!
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Spectrum.n, isHalfWindow: false)
    private var ring = [Float](repeating: 0, count: Spectrum.n)
    private var pos = 0
    private var frame = [Float](repeating: 0, count: Spectrum.n)
    private var re = [Float](repeating: 0, count: Spectrum.n / 2)
    private var im = [Float](repeating: 0, count: Spectrum.n / 2)
    private var mags = [Float](repeating: 0, count: Spectrum.n / 2)
    private var level = SIMD4<Float>.zero
    private var peak: [Float] = [-30, -30, -30, -30]
    private var bins: [Range<Int>] = []
    private let edges: [Double] = [30, 160, 650, 2600, 11000]   // Hz
    let out: AudioLevels

    init(out: AudioLevels) { self.out = out }

    func setSampleRate(_ sr: Double) {
        let hz = sr / Double(Spectrum.n)
        bins = (0..<4).map { b in
            let lo = max(1, Int(edges[b] / hz)), hi = max(lo + 1, Int(edges[b + 1] / hz))
            return lo..<min(hi, Spectrum.n / 2)
        }
    }

    /// Called on the audio thread with mono samples.
    func push(_ samples: UnsafeBufferPointer<Float>) {
        guard !bins.isEmpty else { return }
        for s in samples { ring[pos] = s; pos = (pos + 1) & (Spectrum.n - 1) }
        // unroll the ring (oldest first) and window it
        let head = Spectrum.n - pos
        frame.withUnsafeMutableBufferPointer { f in
            ring.withUnsafeBufferPointer { r in
                f.baseAddress!.update(from: r.baseAddress! + pos, count: head)
                (f.baseAddress! + head).update(from: r.baseAddress!, count: pos)
            }
        }
        let rms = vDSP.rootMeanSquare(frame)
        vDSP.multiply(frame, window, result: &frame)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBytes { vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &sc, 1, vDSP_Length(Spectrum.n / 2)) }
                fft.forward(input: sc, output: &sc)
                mags.withUnsafeMutableBufferPointer { vDSP_zvmags(&sc, 1, $0.baseAddress!, 1, vDSP_Length(Spectrum.n / 2)) }
            }
        }
        for b in 0..<4 {
            var target: Float = 0
            if rms > 1e-4 {   // silence gate (paused / between tracks)
                let r = bins[b]
                var sum: Float = 0
                mags.withUnsafeBufferPointer { vDSP_sve($0.baseAddress! + r.lowerBound, 1, &sum, vDSP_Length(r.count)) }
                let db = 10 * log10(sum / Float(r.count) + 1e-12)
                // adaptive ceiling per band: jumps up instantly, relaxes slowly, so quiet and loud
                // tracks both use the full bar height while relative dynamics stay intact
                peak[b] = max(db, peak[b] - 0.02)
                target = min(1, max(0, (db - (peak[b] - 36)) / 36))
                target = target * target
            }
            level[b] += (target - level[b]) * (target > level[b] ? 0.55 : 0.14)
        }
        out.set(level)
    }
}

/// Taps Spotify's audio output (macOS 14.2+). Needs the "System Audio Recording" permission;
/// playback itself is untouched (the tap is unmuted and private to this app).
@available(macOS 14.2, *)
final class SpotifyAudioTap {
    static let bundleID = "com.spotify.client"
    private let spectrum: Spectrum
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapped: [AudioObjectID] = []
    private let queue = DispatchQueue(label: "notch.audiotap", qos: .userInteractive)
    private var watchdog: Timer?

    private let levels: AudioLevels
    init(levels: AudioLevels) { self.levels = levels; spectrum = Spectrum(out: levels) }

    func start() {
        rebuild()
        levels.setOutputLatency(Self.outputLatency())
        // Before macOS 26 a tap can't follow an app across relaunches, so re-check periodically.
        watchdog = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.levels.setOutputLatency(Self.outputLatency())   // follows device switches (speakers ↔ Bluetooth)
            if #available(macOS 26.0, *) { if self.tapID != kAudioObjectUnknown { return } }
            if Self.spotifyProcesses() != self.tapped { self.rebuild() }
        }
    }

    private func rebuild() {
        stop()
        let procs = Self.spotifyProcesses()
        let desc: CATapDescription
        if #available(macOS 26.0, *) {
            desc = CATapDescription(stereoMixdownOfProcesses: procs)
            desc.bundleIDs = [Self.bundleID]
            desc.isProcessRestoreEnabled = true
        } else {
            guard !procs.isEmpty else { return }
            desc = CATapDescription(stereoMixdownOfProcesses: procs)
        }
        desc.name = "Notch Player visualizer"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr else { NSLog("NotchPlayer: tap failed"); return }
        tapID = tap
        tapped = procs

        guard let outUID = Self.defaultOutputUID() else { stop(); return }
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Notch Player Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        var dev = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(agg as CFDictionary, &dev) == noErr else { NSLog("NotchPlayer: aggregate failed"); stop(); return }
        aggID = dev

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var a = Self.addr(kAudioTapPropertyFormat)
        guard AudioObjectGetPropertyData(tapID, &a, 0, nil, &size, &asbd) == noErr,
              let format = AVAudioFormat(streamDescription: &asbd) else { stop(); return }
        spectrum.setSampleRate(format.sampleRate)
        let spectrum = self.spectrum
        var mono = [Float](repeating: 0, count: 8192)
        var pid: AudioDeviceIOProcID?
        let err = AudioDeviceCreateIOProcIDWithBlock(&pid, aggID, queue) { _, input, _, _, _ in
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
                  let ch = buf.floatChannelData else { return }
            let frames = min(Int(buf.frameLength), mono.count), chans = Int(format.channelCount)
            guard frames > 0, chans > 0 else { return }
            let stride = buf.stride
            mono.withUnsafeMutableBufferPointer { m in
                for i in 0..<frames {
                    var s: Float = 0
                    for c in 0..<chans { s += ch[c][i * stride] }
                    m[i] = s / Float(chans)
                }
                spectrum.push(UnsafeBufferPointer(rebasing: m[0..<frames]))
            }
        }
        guard err == noErr, let pid else { stop(); return }
        procID = pid
        if AudioDeviceStart(aggID, pid) != noErr { NSLog("NotchPlayer: device start failed"); stop() }
    }

    func stop() {
        if aggID != kAudioObjectUnknown, let procID {
            AudioDeviceStop(aggID, procID)
            AudioDeviceDestroyIOProcID(aggID, procID)
        }
        procID = nil
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID); aggID = AudioObjectID(kAudioObjectUnknown) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown) }
        tapped = []
    }

    // MARK: Core Audio helpers

    static func addr(_ s: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: s, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = addr(sel)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &ref) == noErr else { return nil }
        return ref?.takeRetainedValue() as String?
    }

    static func spotifyProcesses() -> [AudioObjectID] {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var a = addr(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { (string($0, kAudioProcessPropertyBundleID) ?? "").hasPrefix(bundleID) }.sorted()
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        var a = addr(kAudioHardwarePropertyDefaultSystemOutputDevice)
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev) == noErr else { return nil }
        return dev
    }

    static func defaultOutputUID() -> String? { defaultOutputDevice().flatMap { string($0, kAudioDevicePropertyDeviceUID) } }

    /// Seconds between a sample reaching the output device and it being heard
    /// (device + stream latency, safety offset and one IO buffer).
    static func outputLatency() -> Double {
        guard let dev = defaultOutputDevice() else { return 0 }
        func u32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32 {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var v: UInt32 = 0, size = UInt32(4)
            return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : 0
        }
        let out = kAudioObjectPropertyScopeOutput
        var frames = u32(dev, kAudioDevicePropertyLatency, out) + u32(dev, kAudioDevicePropertySafetyOffset, out)
            + u32(dev, kAudioDevicePropertyBufferFrameSize, out)
        var sa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: out, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(dev, &sa, 0, nil, &size) == noErr, size >= 4 {
            var streams = [AudioObjectID](repeating: 0, count: Int(size) / 4)
            if AudioObjectGetPropertyData(dev, &sa, 0, nil, &size, &streams) == noErr {
                frames += u32(streams[0], kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal)
            }
        }
        var ra = addr(kAudioDevicePropertyNominalSampleRate)
        var sr: Double = 0, rs = UInt32(8)
        guard AudioObjectGetPropertyData(dev, &ra, 0, nil, &rs, &sr) == noErr, sr > 0 else { return 0 }
        return min(1, Double(frames) / sr)
    }
}

// MARK: - Geometry

struct NotchGeometry {
    var width: CGFloat   // physical notch width
    var height: CGFloat  // physical notch / menu bar height
    var hasNotch: Bool

    static func of(_ screen: NSScreen) -> NotchGeometry {
        if #available(macOS 12.0, *), screen.safeAreaInsets.top > 0,
           let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            return NotchGeometry(width: screen.frame.width - l.width - r.width, height: screen.safeAreaInsets.top, hasNotch: true)
        }
        let menu = screen.frame.maxY - screen.visibleFrame.maxY
        return NotchGeometry(width: 190, height: max(24, menu), hasNotch: false)
    }
}

// MARK: - Shape (flush top, flared "ears", rounded bottom)

struct NotchShape: Shape {
    var ear: CGFloat
    var bottom: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, bottom) }
        set { ear = newValue.first; bottom = newValue.second }
    }
    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height, t = ear, b = min(bottom, (w - 2 * t) / 2, h)
        p.move(to: CGPoint(x: 0, y: 0))
        p.addQuadCurve(to: CGPoint(x: t, y: t), control: CGPoint(x: t, y: 0))
        p.addLine(to: CGPoint(x: t, y: h - b))
        p.addQuadCurve(to: CGPoint(x: t + b, y: h), control: CGPoint(x: t, y: h))
        p.addLine(to: CGPoint(x: w - t - b, y: h))
        p.addQuadCurve(to: CGPoint(x: w - t, y: h - b), control: CGPoint(x: w - t, y: h))
        p.addLine(to: CGPoint(x: w - t, y: t))
        p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - t, y: 0))
        p.closeSubpath()
        return p
    }
}

// MARK: - Views

let kExpandedW: CGFloat = 520
let kEar: CGFloat = 10
let kFlashW: CGFloat = 112   // extra width per wing while the compact pill shows the new title
let kRowTop: CGFloat = 72, kRowLyrics: CGFloat = 54, kRowSeek: CGFloat = 14, kRowCtrl: CGFloat = 51, kRowNext: CGFloat = 34
let kGap: CGFloat = 10, kPadBottom: CGFloat = 14
/// One spring for the island's shape and everything inside it, so they move together.
let kIslandSpring = Animation.spring(response: 0.5, dampingFraction: 0.82)

struct WidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension View {
    /// SF Symbol morph on macOS 14+, plain swap on 13.
    @ViewBuilder func symbolReplace() -> some View {
        if #available(macOS 14.0, *) { self.contentTransition(.symbolEffect(.replace)) } else { self }
    }

    @ViewBuilder func symbolBounce<V: Equatable>(_ value: V, enabled: Bool) -> some View {
        if enabled {
            if #available(macOS 14.0, *) { self.symbolEffect(.bounce, value: value) } else { self }
        } else { self }
    }
}

/// Bars show what Spotify is actually playing: bass → treble from a live FFT of its audio output.
/// Without audio-capture permission they fall back to Spotify's loudness/beat analysis, and
/// without that to a calm, clearly idle pulse (never random motion).
struct Visualizer: View {
    @ObservedObject var m: NotchModel
    var height: CGFloat = 14
    var body: some View {
        let playing = m.state.playing
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !playing)) { ctx in
            let lv = levels(ctx.date)
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule()
                        .fill(LinearGradient(colors: [m.accent, m.accent.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 3, height: playing ? max(3, height * lv[i]) : 3)
                        .opacity(playing ? 1 : 0.45)
                }
            }
            .frame(height: height)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: playing)
    }

    func levels(_ date: Date) -> [CGFloat] {
        if let live = m.audio.current() { return live.map { CGFloat(0.1 + 0.9 * $0) } }
        if let v = m.state.viz, v.uri == m.state.uri,
           let l = v.levels(at: m.currentPosition(at: date) - m.audio.outputLatency * 1000) {
            return l.map { CGFloat($0) }
        }
        let t = date.timeIntervalSinceReferenceDate
        return (0..<4).map { i in CGFloat(0.3 + 0.12 * sin(t * 2.4 - Double(i) * 0.6)) }
    }
}

struct Artwork: View {
    var image: NSImage?
    var size: CGFloat
    var radius: CGFloat
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.white.opacity(0.08))
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
    }
}

func fmt(_ ms: Double) -> String {
    let s = Int(max(0, ms) / 1000)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Circle().fill(Color.white.opacity(configuration.isPressed ? 0.14 : 0)))
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct IconButton: View {
    var name: String
    var size: CGFloat = 15
    var tint: Color = .white
    var dim = false
    var bounce = false
    var action: () -> Void
    // @State without the macro (Command Line Tools ship no SwiftUIMacros plugin)
    private let hoverS = State<Bool>(initialValue: false)
    private var hover: Bool { get { hoverS.wrappedValue } nonmutating set { hoverS.wrappedValue = newValue } }
    var body: some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: size, weight: .semibold))
                .symbolReplace()
                .symbolBounce(name, enabled: bounce)
                .foregroundColor(tint.opacity(dim ? (hover ? 0.75 : 0.45) : 1))
                .frame(width: size * 2.3, height: size * 2.3)
                .background(Circle().fill(Color.white.opacity(hover ? 0.09 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .scaleEffect(hover ? 1.06 : 1)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: name)
    }
}

/// Single-line text that scrolls (with a pause and soft edges) only when it doesn't fit.
struct Marquee: View {
    let text: Text
    var height: CGFloat
    var align: Alignment = .leading
    // @State without the macro (Command Line Tools ship no SwiftUIMacros plugin)
    private let textWS = State<CGFloat>(initialValue: 0)
    private var textW: CGFloat { get { textWS.wrappedValue } nonmutating set { textWS.wrappedValue = newValue } }
    // @State without the macro (Command Line Tools ship no SwiftUIMacros plugin)
    private let startS = State<Date>(initialValue: Date())
    private var start: Date { get { startS.wrappedValue } nonmutating set { startS.wrappedValue = newValue } }

    var body: some View {
        GeometryReader { g in
            let box = g.size.width
            if textW > box + 0.5 {
                TimelineView(.animation) { ctx in
                    let gap: CGFloat = 40, speed: CGFloat = 28, hold = 1.8
                    let cycle = hold + Double((textW + gap) / speed)
                    let tt = ctx.date.timeIntervalSince(start).truncatingRemainder(dividingBy: cycle)
                    HStack(spacing: gap) { text.fixedSize(); text.fixedSize() }
                        .offset(x: -CGFloat(max(0, tt - hold)) * speed)
                }
                .frame(width: box, height: g.size.height, alignment: .leading)
                .mask(LinearGradient(stops: [
                    .init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                    .init(color: .black, location: 0.88), .init(color: .clear, location: 1),
                ], startPoint: .leading, endPoint: .trailing))
            } else {
                text.lineLimit(1).frame(width: box, height: g.size.height, alignment: align)
            }
        }
        .frame(height: height)
        .clipped()
        .background(text.fixedSize().hidden().background(GeometryReader { p in
            Color.clear.preference(key: WidthKey.self, value: p.size.width)
        }))
        .onPreferenceChange(WidthKey.self) { w in
            if abs(w - textW) > 0.5 { textW = w; start = Date() }
        }
    }
}

/// Capsule scrubber shared by the seek bar and the volume bar.
struct ScrubBar: View {
    var value: Double
    var accent: Color
    var height: CGFloat = 5
    var onChange: (Double) -> Void
    var onCommit: (Double) -> Void
    // @State without the macro (Command Line Tools ship no SwiftUIMacros plugin)
    private let hoverS = State<Bool>(initialValue: false)
    private var hover: Bool { get { hoverS.wrappedValue } nonmutating set { hoverS.wrappedValue = newValue } }
    // @State without the macro (Command Line Tools ship no SwiftUIMacros plugin)
    private let draggingS = State<Bool>(initialValue: false)
    private var dragging: Bool { get { draggingS.wrappedValue } nonmutating set { draggingS.wrappedValue = newValue } }

    var body: some View {
        GeometryReader { g in
            let active = hover || dragging
            let clamp = { (x: CGFloat) in Double(min(1, max(0, x / max(1, g.size.width)))) }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.16))
                Capsule()
                    .fill(active ? accent : Color.white.opacity(0.92))
                    .frame(width: max(active ? height + 2 : height, g.size.width * CGFloat(min(1, max(0, value)))))
                    .shadow(color: active ? accent.opacity(0.6) : .clear, radius: 4)
            }
            .frame(height: active ? height + 2 : height)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in dragging = true; onChange(clamp(v.location.x)) }
                .onEnded { v in dragging = false; onCommit(clamp(v.location.x)) })
            .onHover { hover = $0 }
        }
        .frame(height: 14)
        .animation(.easeOut(duration: 0.15), value: hover || dragging)
    }
}

struct SeekBar: View {
    @ObservedObject var m: NotchModel
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let dur = max(1, m.state.duration)
            let pos = m.seekDrag.map { $0 * dur } ?? m.currentPosition(at: ctx.date)
            HStack(spacing: 10) {
                Text(fmt(pos)).frame(width: 40, alignment: .trailing)
                ScrubBar(value: pos / dur, accent: m.accent, onChange: { m.seekDrag = $0 }, onCommit: { r in
                    m.command("seek", ["ms": r * dur])
                    m.state.position = r * dur
                    m.state.ts = Date().timeIntervalSince1970 * 1000
                    m.seekDrag = nil
                })
                Text("-" + fmt(dur - pos)).frame(width: 46, alignment: .leading)
            }
            .font(.system(size: 10.5, weight: .medium, design: .rounded).monospacedDigit())
            .foregroundColor(.white.opacity(0.55))
        }
    }
}

/// Previous / current / next lyric lines; the current one is highlighted and lines roll upward.
struct LyricsView: View {
    @ObservedObject var m: NotchModel
    var body: some View {
        if let lines = m.state.lyrics, !lines.isEmpty {
            TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                let pos = m.currentPosition(at: ctx.date) + 250
                let idx = lines.lastIndex { $0.t <= pos } ?? -1
                VStack(spacing: 3) {
                    ForEach((idx - 1)...(idx + 1), id: \.self) { i in
                        let cur = i == idx
                        let raw = (i >= 0 && i < lines.count) ? lines[i].w : ""
                        Text(cur && raw.isEmpty ? "♪" : raw)
                            .font(.system(size: cur ? 13.5 : 11.5, weight: cur ? .bold : .medium, design: .rounded))
                            .foregroundColor(cur ? m.accent : .white.opacity(0.3))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, minHeight: cur ? 18 : 14)
                            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                    removal: .move(edge: .top).combined(with: .opacity)))
                    }
                }
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: idx)
            }
            .frame(height: kRowLyrics)
            .clipped()
        }
    }
}

struct UpNextRow: View {
    @ObservedObject var m: NotchModel
    let next: NextTrack
    // @State without the macro (Command Line Tools ship no SwiftUIMacros plugin)
    private let hoverS = State<Bool>(initialValue: false)
    private var hover: Bool { get { hoverS.wrappedValue } nonmutating set { hoverS.wrappedValue = newValue } }
    var body: some View {
        HStack(spacing: 9) {
            Artwork(image: m.nextArtwork, size: 24, radius: 6)
            Text("UP NEXT").font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundColor(.white.opacity(0.4))
            Marquee(text: Text(next.title).font(.system(size: 11.5, weight: .semibold)).foregroundColor(.white.opacity(0.88))
                        + Text("  ·  \(next.artist)").font(.system(size: 11.5)).foregroundColor(.white.opacity(0.45)),
                    height: 16)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white.opacity(hover ? 0.75 : 0.3))
                .offset(x: hover ? 2 : 0)
        }
        .padding(.vertical, 5)
        .padding(.leading, 5)
        .padding(.trailing, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(hover ? 0.1 : 0.05)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
        .onTapGesture { m.command("open", ["uri": "queue"]) }
    }
}

struct ExpandedView: View {
    @ObservedObject var m: NotchModel

    var volumeIcon: String {
        let v = m.state.volume
        return v == 0 ? "speaker.slash.fill" : v < 0.34 ? "speaker.wave.1.fill" : v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }

    var body: some View {
        let s = m.state
        VStack(spacing: kGap) {
            HStack(spacing: 14) {
                ZStack {
                    Artwork(image: m.artwork, size: 72, radius: 14)
                        .id(m.artKey)
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }
                .scaleEffect(s.playing ? 1 : 0.88)
                .shadow(color: m.accent.opacity(s.playing ? 0.45 : 0.18), radius: s.playing ? 14 : 6, y: s.playing ? 6 : 2)
                .animation(.spring(response: 0.5, dampingFraction: 0.7), value: s.playing)
                .onTapGesture { m.command("open", ["uri": s.albumUri ?? ""]) }

                VStack(alignment: .leading, spacing: 3) {
                    Marquee(text: Text(s.title).font(.system(size: 15, weight: .semibold, design: .rounded)), height: 20)
                        .onTapGesture { m.command("open", ["uri": s.albumUri ?? ""]) }
                    Text(s.artist)
                        .font(.system(size: 12.5, weight: .medium)).foregroundColor(.white.opacity(0.68)).lineLimit(1)
                        .onTapGesture { m.command("open", ["uri": s.artistUri ?? ""]) }
                    Text(s.album)
                        .font(.system(size: 9.5, weight: .semibold)).tracking(0.6).textCase(.uppercase)
                        .foregroundColor(.white.opacity(0.38)).lineLimit(1)
                        .padding(.top, 1)
                }
                .id(s.uri)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 12)), removal: .opacity))

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 10) {
                    Visualizer(m: m, height: 18)
                    HStack(spacing: 4) {
                        Image(systemName: "hifispeaker.fill").font(.system(size: 8.5))
                        Text(s.device.isEmpty ? "This Mac" : s.device).lineLimit(1)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .frame(maxWidth: 130, alignment: .trailing)
                }
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: m.artKey)
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: s.uri)
            .frame(height: kRowTop)

            LyricsView(m: m)
            SeekBar(m: m).frame(height: kRowSeek)

            HStack(spacing: 2) {
                IconButton(name: s.liked ? "heart.fill" : "heart", tint: s.liked ? m.accent : .white, bounce: true) {
                    m.state.liked.toggle(); m.command("like")
                }
                IconButton(name: "shuffle", tint: s.shuffle ? m.accent : .white, dim: !s.shuffle) {
                    m.state.shuffle.toggle(); m.command("shuffle")
                }
                Spacer()
                IconButton(name: "backward.fill", size: 17) { m.command("prev") }
                IconButton(name: s.playing ? "pause.fill" : "play.fill", size: 22) {
                    m.state.position = m.currentPosition(); m.state.ts = Date().timeIntervalSince1970 * 1000
                    m.state.playing.toggle(); m.command("toggle")
                }
                IconButton(name: "forward.fill", size: 17) { m.command("next") }
                Spacer()
                IconButton(name: s.repeatMode == 2 ? "repeat.1" : "repeat", tint: s.repeatMode > 0 ? m.accent : .white, dim: s.repeatMode == 0) {
                    m.state.repeatMode = (s.repeatMode + 1) % 3; m.command("repeat")
                }
                HStack(spacing: 6) {
                    Image(systemName: volumeIcon)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.65))
                        .symbolReplace()
                        .frame(width: 18)
                        .animation(.easeOut(duration: 0.2), value: volumeIcon)
                    ScrubBar(value: s.volume, accent: m.accent, height: 4,
                             onChange: { v in m.state.volume = v; m.command("volume", ["v": v]) },
                             onCommit: { v in m.state.volume = v; m.command("volume", ["v": v]) })
                        .frame(width: 70)
                }
            }
            .frame(height: kRowCtrl)

            if let n = s.next {
                UpNextRow(m: m, next: n).frame(height: kRowNext)
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 22)
        .padding(.bottom, kPadBottom)
    }
}

/// Compact artwork with a thin progress ring around it.
struct CompactArt: View {
    @ObservedObject var m: NotchModel
    var size: CGFloat
    var body: some View {
        let ring = RoundedRectangle(cornerRadius: 8.5, style: .continuous)
        ZStack {
            ring.stroke(Color.white.opacity(0.12), lineWidth: 1.6)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let p = m.state.duration > 0 ? m.currentPosition(at: ctx.date) / m.state.duration : 0
                ring.trim(from: 0, to: CGFloat(min(1, max(0, p))))
                    .stroke(m.accent, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .rotationEffect(.degrees(-90))   // start the ring at 12 o'clock
                    .animation(.linear(duration: 1), value: p)
            }
            Artwork(image: m.artwork, size: size, radius: 5.5)
                .id(m.artKey)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
                .scaleEffect(m.state.playing ? 1 : 0.86)
        }
        .frame(width: size + 7, height: size + 7)
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: m.artKey)
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: m.state.playing)
    }
}

struct NotchRoot: View {
    @ObservedObject var m: NotchModel
    let geo: NotchGeometry

    var open: Bool { m.hasTrack && m.expanded }
    var flashing: Bool { m.hasTrack && m.flash && !open }
    var wing: CGFloat { geo.height + 6 }
    var bottomR: CGFloat { open ? 30 : geo.height * 0.42 }

    var size: CGSize {
        if open { return CGSize(width: kExpandedW, height: geo.height + 4 + m.openBodyH) }
        if m.hasTrack { return CGSize(width: geo.width + (wing + (flashing ? kFlashW : 0)) * 2 + kEar * 2, height: geo.height) }
        return CGSize(width: geo.width + kEar * 2, height: geo.height)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(ear: kEar, bottom: bottomR).fill(Color.black)

                // ambient album-art glow — kept off the top so the island stays fused to the hardware notch
                if m.contentMounted && m.hasTrack, let amb = m.ambient {
                    Image(nsImage: amb).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: size.width, height: size.height)
                        .opacity(0.36)
                        .overlay(RadialGradient(colors: [.clear, .black.opacity(0.4)], center: .center, startRadius: 60, endRadius: kExpandedW * 0.6))
                        .mask(LinearGradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .clear, location: min(0.3, geo.height * 0.6 / max(1, size.height))),
                            .init(color: .black, location: 0.6),
                            .init(color: .black.opacity(0.75), location: 1),
                        ], startPoint: .top, endPoint: .bottom))
                        .id(m.artKey)
                        .opacity(open ? 1 : 0)
                        .transition(.asymmetric(insertion: .opacity, removal: .identity))
                        .allowsHitTesting(false)
                }

                // hairline rim light along the lower edge
                NotchShape(ear: kEar, bottom: bottomR)
                    .stroke(LinearGradient(stops: [
                        .init(color: .clear, location: 0), .init(color: .clear, location: 0.35),
                        .init(color: .white.opacity(open ? 0.16 : 0.07), location: 1),
                    ], startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
                    .allowsHitTesting(false)

                // compact wings
                HStack(spacing: 0) {
                    HStack(spacing: 0) {
                        CompactArt(m: m, size: geo.height - 14).frame(width: wing)
                        if flashing {
                            Marquee(text: Text(m.state.title).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(.white),
                                    height: 16)
                                .frame(width: kFlashW - 8)
                                .transition(.opacity)
                        }
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        if flashing {
                            Marquee(text: Text(m.state.artist).font(.system(size: 11.5, weight: .medium)).foregroundColor(.white.opacity(0.6)),
                                    height: 16, align: .trailing)
                                .frame(width: kFlashW - 8)
                                .transition(.opacity)
                        }
                        Visualizer(m: m, height: geo.height * 0.42)
                            .frame(width: wing)
                    }
                }
                .padding(.horizontal, kEar)
                .frame(height: geo.height)
                .opacity(m.hasTrack && !open ? 1 : 0)

                if m.contentMounted && m.hasTrack {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: geo.height + 4)
                        ExpandedView(m: m)
                    }
                    .padding(.horizontal, kEar)
                    // Opening: inserted with a transition. Closing: faded/scaled by these modifiers,
                    // both driven by kIslandSpring (below) — the same spring as the shape.
                    .opacity(open ? 1 : 0)
                    .scaleEffect(open ? 1 : 0.94, anchor: .top)
                    .allowsHitTesting(open)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.9, anchor: .top)), removal: .identity))
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipShape(NotchShape(ear: kEar, bottom: bottomR))
            .shadow(color: .black.opacity(open ? 0.55 : 0), radius: 8, y: 3)
            .shadow(color: m.accent.opacity(open ? 0.22 : 0), radius: 30, y: 10)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(kIslandSpring, value: open)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: flashing)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: m.hasTrack)
        .animation(kIslandSpring, value: m.openBodyH)
        .animation(.easeInOut(duration: 0.6), value: m.artKey)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Window

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = NotchModel()
    var bridge: Bridge!
    var panel: NotchPanel!
    var geo = NotchGeometry(width: 190, height: 32, hasNotch: false)
    var timer: Timer?
    var status: NSStatusItem!
    var leaveWork: DispatchWorkItem?
    var audioTap: AnyObject?
    let panelSize = NSSize(width: kExpandedW + 80, height: 420)

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        bridge = Bridge(model: model)
        bridge.start()
        if #available(macOS 14.2, *) {
            let tap = SpotifyAudioTap(levels: model.audio)
            tap.start()
            audioTap = tap
        }
        buildPanel()
        buildStatusItem()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // 30 Hz hover tracking — cheap, needs no accessibility permission.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.trackMouse() }
        RunLoop.main.add(timer!, forMode: .common)
        if let i = CommandLine.arguments.firstIndex(of: "--snap"), i + 1 < CommandLine.arguments.count {
            snapshotAndExit(dir: CommandLine.arguments[i + 1])
        }
    }

    /// Debug: renders the island collapsed and expanded to PNGs (no screen-recording permission needed).
    func snapshotAndExit(dir: String) {
        timer?.invalidate()
        panel.contentView?.layer?.backgroundColor = NSColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1).cgColor
        func snap(_ name: String) {
            guard let v = panel.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            self.model.deviceOverride = "MacBook Pro"
            self.model.state.device = "MacBook Pro"
            snap("collapsed.png")
            self.model.flash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                snap("flash.png")
                self.model.flash = false
            self.model.expanded = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                snap("expanded.png")
                NSApp.terminate(nil)
            }
            }
        }
    }

    var screen: NSScreen {
        if #available(macOS 12.0, *), let s = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) { return s }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    func buildPanel() {
        geo = NotchGeometry.of(screen)
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: NotchRoot(m: model, geo: geo))
        host.wantsLayer = true
        panel.contentView = host
        position()
        panel.orderFrontRegardless()
    }

    func position() {
        let f = screen.frame
        panel.setFrame(NSRect(x: f.midX - panelSize.width / 2, y: f.maxY - panelSize.height, width: panelSize.width, height: panelSize.height), display: true)
    }

    @objc func screensChanged() {
        geo = NotchGeometry.of(screen)
        (panel.contentView as? NSHostingView<NotchRoot>)?.rootView = NotchRoot(m: model, geo: geo)
        position()
    }

    /// The rect (screen coords) the island currently occupies.
    func activeRect() -> NSRect {
        let f = screen.frame
        let open = model.expanded
        let w: CGFloat, h: CGFloat
        if model.hasTrack && open { w = kExpandedW; h = geo.height + 4 + model.openBodyH }
        else if model.hasTrack { w = geo.width + (geo.height + 6 + (model.flash ? kFlashW : 0)) * 2 + kEar * 2; h = geo.height }
        else { w = geo.width; h = geo.height }
        return NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
    }

    func trackMouse() {
        let p = NSEvent.mouseLocation
        let inside = activeRect().insetBy(dx: -4, dy: -4).contains(p) && model.hasTrack
        panel.ignoresMouseEvents = !inside
        if inside {
            leaveWork?.cancel(); leaveWork = nil
            if !model.expanded { model.expanded = true }
        } else if model.expanded && leaveWork == nil {
            let w = DispatchWorkItem { [weak self] in self?.model.expanded = false; self?.leaveWork = nil }
            leaveWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
        }
    }

    // MARK: menu bar item
    func buildStatusItem() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Notch Player")
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu
    }

    @objc func toggleLogin() {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                else { try SMAppService.mainApp.register() }
            } catch { NSLog("NotchPlayer: login item \(error)") }
        }
    }
    @objc func openSpotify() { NSWorkspace.shared.open(URL(string: "spotify:")!) }
    @objc func quit() { NSApp.terminate(nil) }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let st = NSMenuItem(title: model.connected ? "Connected to Spotify" : "Waiting for Spotify (Spicetify extension)…", action: nil, keyEquivalent: "")
        st.isEnabled = false
        menu.addItem(st)
        let live = model.audio.current() != nil
        let vz = NSMenuItem(title: live ? "Visualizer: live audio"
                                        : model.state.playing ? "Visualizer: beat data (allow System Audio Recording for live audio)"
                                                              : "Visualizer: waiting for playback", action: nil, keyEquivalent: "")
        vz.isEnabled = false
        menu.addItem(vz)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Spotify", action: #selector(openSpotify), keyEquivalent: "o"))
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        if #available(macOS 13.0, *) { login.state = SMAppService.mainApp.status == .enabled ? .on : .off }
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Notch Player", action: #selector(quit), keyEquivalent: "q"))
        for i in menu.items where i.action != nil { i.target = self }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

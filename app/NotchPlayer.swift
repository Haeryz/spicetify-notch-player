// Notch Player — native macOS companion for the "Notch Player" Spicetify extension.
// Draws a Dynamic-Island style player fused to the MacBook's physical notch.
// Data comes from the Spicetify extension over a local WebSocket (127.0.0.1:47823).

import AppKit
import SwiftUI
import Network
import CoreImage
import ServiceManagement

let kPort: UInt16 = 47823

// MARK: - Model

struct LyricLine: Decodable, Equatable { let t: Double; let w: String }

struct NextTrack: Decodable, Equatable { let title: String; let artist: String; let art: String? }

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
}

final class NotchModel: ObservableObject {
    @Published var state = PlayerState()
    @Published var connected = false
    @Published var expanded = false
    @Published var artwork: NSImage? = nil
    @Published var nextArtwork: NSImage? = nil
    @Published var accent: Color = Color(red: 0.12, green: 0.84, blue: 0.38)
    @Published var peeking = false
    @Published var seekDrag: Double? = nil
    @Published var seekHover = false

    var send: (([String: Any]) -> Void)?
    private var artURL: String?
    private var nextArtURL: String?
    private var peekWork: DispatchWorkItem?

    var hasTrack: Bool { connected && !state.title.isEmpty }

    func currentPosition(at date: Date = Date()) -> Double {
        guard state.playing else { return state.position }
        let now = date.timeIntervalSince1970 * 1000
        return min(state.duration, state.position + max(0, now - state.ts))
    }

    func apply(_ s: PlayerState) {
        let songChanged = s.uri != state.uri && !state.uri.isEmpty
        state = s
        if s.art != artURL { artURL = s.art; load(s.art) { [weak self] img in
            self?.artwork = img
            if let img { self?.accent = Self.accent(of: img) }
        } }
        if s.next?.art != nextArtURL { nextArtURL = s.next?.art; load(s.next?.art) { [weak self] in self?.nextArtwork = $0 } }
        if songChanged { peek() }
    }

    func peek() {
        peekWork?.cancel()
        peeking = true
        let w = DispatchWorkItem { [weak self] in self?.peeking = false }
        peekWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: w)
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
let kExpandedBody: CGFloat = 196
let kEar: CGFloat = 10

struct Visualizer: View {
    var playing: Bool
    var color: Color
    var height: CGFloat = 14
    var body: some View {
        TimelineView(.periodic(from: .now, by: playing ? 0.16 : 3600)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    let v = 0.5 + 0.5 * sin(t * [7.1, 9.3, 6.2, 8.4, 10.1][i] + Double(i) * 1.7) * cos(t * 2.3 + Double(i))
                    Capsule().fill(color)
                        .frame(width: 3, height: playing ? max(3, height * CGFloat(0.25 + 0.75 * abs(v))) : 3)
                }
            }
            .frame(height: height)
            .animation(.easeInOut(duration: 0.16), value: t)
        }
    }
}

struct Artwork: View {
    var image: NSImage?
    var size: CGFloat
    var radius: CGFloat
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius).fill(Color.white.opacity(0.08))
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

func fmt(_ ms: Double) -> String {
    let s = Int(max(0, ms) / 1000)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Circle().fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0)))
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct IconButton: View {
    var name: String
    var size: CGFloat = 15
    var tint: Color = .white
    var dim = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(tint.opacity(dim ? 0.45 : 1))
                .frame(width: size * 2.3, height: size * 2.3)
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
    }
}

struct SeekBar: View {
    @ObservedObject var m: NotchModel
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let drag = m.seekDrag, hover = m.seekHover
            let dur = max(1, m.state.duration)
            let pos = drag.map { $0 * dur } ?? m.currentPosition(at: ctx.date)
            HStack(spacing: 10) {
                Text(fmt(pos)).frame(width: 40, alignment: .trailing)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule().fill(hover || drag != nil ? m.accent : .white)
                            .frame(width: max(0, g.size.width * CGFloat(pos / dur)))
                    }
                    .frame(height: hover || drag != nil ? 7 : 5)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in m.seekDrag = Double(min(1, max(0, v.location.x / g.size.width))) }
                        .onEnded { v in
                            let r = Double(min(1, max(0, v.location.x / g.size.width)))
                            m.command("seek", ["ms": r * dur])
                            m.state.position = r * dur
                            m.state.ts = Date().timeIntervalSince1970 * 1000
                            m.seekDrag = nil
                        })
                    .onHover { m.seekHover = $0 }
                }
                .frame(height: 14)
                Text("-" + fmt(dur - pos)).frame(width: 46, alignment: .leading)
            }
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundColor(.white.opacity(0.6))
            .animation(.easeOut(duration: 0.15), value: hover)
        }
    }
}

struct LyricLineView: View {
    @ObservedObject var m: NotchModel
    var body: some View {
        if let lines = m.state.lyrics, !lines.isEmpty {
            TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                let pos = m.currentPosition(at: ctx.date) + 250
                let idx = lines.lastIndex { $0.t <= pos }
                let text = idx.map { lines[$0].w } ?? "♪"
                Text(text.isEmpty ? "♪" : text)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(m.accent)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .id(idx ?? -1)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .move(edge: .top).combined(with: .opacity)))
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: idx)
            }
            .frame(height: 18)
            .clipped()
        }
    }
}

struct ExpandedView: View {
    @ObservedObject var m: NotchModel
    var body: some View {
        let s = m.state
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Artwork(image: m.artwork, size: 72, radius: 14)
                    .shadow(color: m.accent.opacity(0.35), radius: 12)
                    .onTapGesture { m.command("open", ["uri": s.albumUri ?? ""]) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.title).font(.system(size: 15, weight: .bold)).lineLimit(1)
                        .onTapGesture { m.command("open", ["uri": s.albumUri ?? ""]) }
                    Text(s.artist).font(.system(size: 12.5)).foregroundColor(.white.opacity(0.65)).lineLimit(1)
                        .onTapGesture { m.command("open", ["uri": s.artistUri ?? ""]) }
                    Text(s.album).font(.system(size: 11.5)).foregroundColor(.white.opacity(0.42)).lineLimit(1)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 10) {
                    Visualizer(playing: s.playing, color: m.accent, height: 18)
                    HStack(spacing: 4) {
                        Image(systemName: "hifispeaker.fill").font(.system(size: 9))
                        Text(s.device.isEmpty ? "This Mac" : s.device).lineLimit(1)
                    }
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(maxWidth: 120, alignment: .trailing)
                }
            }
            LyricLineView(m: m)
            SeekBar(m: m)
            HStack(spacing: 2) {
                IconButton(name: s.liked ? "heart.fill" : "heart", tint: s.liked ? m.accent : .white) {
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
                HStack(spacing: 4) {
                    Image(systemName: s.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 11)).foregroundColor(.white.opacity(0.7))
                    Slider(value: Binding(get: { m.state.volume }, set: { v in m.state.volume = v; m.command("volume", ["v": v]) }), in: 0...1)
                        .controlSize(.mini)
                        .tint(m.accent)
                        .frame(width: 70)
                }
            }
            if let n = s.next {
                HStack(spacing: 8) {
                    Artwork(image: m.nextArtwork, size: 20, radius: 5)
                    (Text("Up next  ").foregroundColor(.white.opacity(0.45))
                     + Text(n.title).foregroundColor(.white.opacity(0.85)).bold()
                     + Text("  ·  \(n.artist)").foregroundColor(.white.opacity(0.45)))
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.top, 6)
                .overlay(Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1), alignment: .top)
                .contentShape(Rectangle())
                .onTapGesture { m.command("open", ["uri": "queue"]) }
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 22)
        .padding(.bottom, 14)
    }
}

struct NotchRoot: View {
    @ObservedObject var m: NotchModel
    let geo: NotchGeometry

    var open: Bool { m.hasTrack && (m.expanded || m.peeking) }
    var wing: CGFloat { geo.height + 6 }

    var size: CGSize {
        if open { return CGSize(width: kExpandedW, height: geo.height + (m.state.next == nil ? kExpandedBody - 34 : kExpandedBody) + (m.state.lyrics?.isEmpty == false ? 26 : 0)) }
        if m.hasTrack { return CGSize(width: geo.width + wing * 2 + kEar * 2, height: geo.height) }
        return CGSize(width: geo.width + kEar * 2, height: geo.height)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(ear: kEar, bottom: open ? 30 : geo.height * 0.42)
                    .fill(Color.black)
                    .shadow(color: open ? m.accent.opacity(0.28) : .clear, radius: 24, y: 6)

                // compact wings
                HStack(spacing: 0) {
                    Artwork(image: m.artwork, size: geo.height - 12, radius: 6)
                        .frame(width: wing)
                    Spacer()
                    Visualizer(playing: m.state.playing, color: m.accent, height: geo.height * 0.42)
                        .frame(width: wing)
                }
                .padding(.horizontal, kEar)
                .frame(height: geo.height)
                .opacity(m.hasTrack && !open ? 1 : 0)

                if open {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: geo.height + 4)
                        ExpandedView(m: m)
                    }
                    .padding(.horizontal, kEar)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(NotchShape(ear: kEar, bottom: open ? 30 : geo.height * 0.42))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: open)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: m.hasTrack)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: m.state.next == nil)
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
    let panelSize = NSSize(width: kExpandedW + 80, height: 320)

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        bridge = Bridge(model: model)
        bridge.start()
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
            self.model.state.device = "MacBook Pro"   // keep personal device names out of screenshots
            snap("collapsed.png")
            self.model.expanded = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                snap("expanded.png")
                NSApp.terminate(nil)
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
        let open = model.expanded || model.peeking
        let w: CGFloat, h: CGFloat
        if model.hasTrack && open { w = kExpandedW; h = geo.height + kExpandedBody + 30 }
        else if model.hasTrack { w = geo.width + (geo.height + 6) * 2 + kEar * 2; h = geo.height }
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

import AppKit
import Combine
import CoreAudio
import SwiftUI

/// 频谱面板的数据（面板打开时每帧更新）。
final class SpectrumPanelModel: ObservableObject {
    @Published var levels = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    @Published var audible = false
    @Published var look = SpectrumLook.current
    @Published var error: String?
    @Published var nowPlaying: NowPlayingInfo?
    @Published var source: SoundSource?

    var onCommand: (NowPlayingMonitor.Command) -> Void = { _ in }
    var onLook: (SpectrumLook) -> Void = { _ in }
    var onHide: () -> Void = {}
    var onPrivacy: () -> Void = {}
    var onSettings: () -> Void = {}
    var onQuit: () -> Void = {}
    var onFullscreen: () -> Void = {}
}

/// 点开频谱时的面板：与其他指标的面板同一套卡片式设计。
struct SpectrumPanelView: View {
    @ObservedObject var model: SpectrumPanelModel

    var body: some View {
        Themed { p in
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(p.accentFill).frame(width: 20)
                    Text(model.source == nil ? "音乐频谱" : "频谱").font(Typo.title).foregroundStyle(p.text)
                    Spacer()
                    Button(action: model.onSettings) {
                        Image(systemName: "gearshape").font(.system(size: 13)).foregroundStyle(p.text2)
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("设置")
                }

                if let source = model.source { sourceHero(p, source) } else { hero(p) }

                SoundControls(model: SoundController.shared.panel)

                // 只在没法截取声音时提示权限
                if let error = model.error {
                    Card(padding: 10) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(error).font(Typo.caption).foregroundStyle(p.hot)
                            HStack {
                                Text("需要“系统录音”权限").font(Typo.body).foregroundStyle(p.text)
                                Spacer()
                                PlainButton(title: "打开权限设置…", action: model.onPrivacy)
                            }
                        }
                    }
                }

                HStack(spacing: 14) {
                    LinkButton(title: "样式设置…", muted: true, action: model.onSettings)
                    Spacer()
                    LinkButton(title: "隐藏频谱", muted: true, action: model.onHide)
                    LinkButton(title: "退出", muted: true, action: model.onQuit)
                }
                .padding(.top, 2)
            }
            .padding(14)
            .frame(width: 320)
            .background(p.panel)
        }
    }

    /// 主卡片：封面 + 歌曲信息 + 频谱 + 进度 + 控制，底色带一点专辑色。
    private func hero(_ p: Palette) -> some View {
        let info = model.nowPlaying
        let tint = info?.tint.map(Color.init)
        let accent = tint ?? p.accentFill
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Group {
                    if let artwork = info?.artwork {
                        Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            p.inset
                            Image(systemName: info?.isVideo == true ? "play.rectangle.fill" : "waveform")
                                .font(.system(size: 24, weight: .medium)).foregroundStyle(p.text3)
                        }
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(info.map { $0.title.isEmpty ? "未知" : $0.title } ?? (model.audible ? "正在播放" : "当前没有声音"))
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                    Text(info.map { $0.artist.isEmpty ? $0.album : $0.artist } ?? "没有读到播放器信息")
                        .font(Typo.body).foregroundStyle(p.text2).lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(model.audible ? p.cool : p.text3).frame(width: 6, height: 6)
                        Text(Self.appName(info?.bundle) ?? (model.audible ? "有声音" : "没有声音")).font(Typo.caption).foregroundStyle(p.text3).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                fullscreenButton(p)
            }

            bigSpectrum(p).frame(height: 54)

            if let info {
                VStack(spacing: 10) {
                    if let duration = info.duration, duration > 0 {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let position = info.position(at: context.date) ?? 0
                            VStack(spacing: 4) {
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(p.text.opacity(0.12)).frame(height: 4)
                                        Capsule().fill(accent).frame(width: geo.size.width * min(max(position / duration, 0), 1), height: 4)
                                    }
                                }
                                .frame(height: 4)
                                HStack {
                                    Text(Self.time(position)).font(Typo.number(11, .medium)).foregroundStyle(p.text3)
                                    Spacer()
                                    Text("-" + Self.time(max(duration - position, 0))).font(Typo.number(11, .medium)).foregroundStyle(p.text3)
                                }
                            }
                        }
                    }
                    HStack(spacing: 40) {
                        if info.canSkip { control(p, "backward.end.fill", size: 16) { model.onCommand(.previous) } }
                        control(p, info.playing ? "pause.fill" : "play.fill", size: 24) { model.onCommand(.togglePlayPause) }
                        if info.canSkip { control(p, "forward.end.fill", size: 16) { model.onCommand(.next) } }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                p.card
                if let tint {
                    LinearGradient(colors: [tint.opacity(0.30), tint.opacity(0.04)], startPoint: .topLeading, endPoint: .bottom)
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(p.cardStroke))
    }

    /// 全屏看频谱（可显示歌词）。
    private func fullscreenButton(_ p: Palette) -> some View {
        Button(action: model.onFullscreen) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(p.text2)
                .frame(width: 26, height: 26)
                .background(Circle().fill(p.text.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("全屏")
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// 其他程序在发声：程序图标 + 名称 + 频谱，点图标切过去。
    private func sourceHero(_ p: Palette, _ source: SoundSource) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button { model.onCommand(.openApp) } label: {
                    Group {
                        if let icon = source.icon {
                            Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                        } else {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14).fill(p.inset)
                                Image(systemName: "speaker.wave.2.fill").font(.system(size: 24, weight: .medium)).foregroundStyle(p.text3)
                            }
                        }
                    }
                    .frame(width: 64, height: 64)
                }
                .buttonStyle(.plain)
                .help("切换到 \(source.name)")
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(model.audible ? p.cool : p.text3).frame(width: 6, height: 6)
                        Text(model.audible ? "正在发声" : "没有声音").font(Typo.caption).foregroundStyle(p.text3)
                    }
                }
                Spacer(minLength: 0)
                fullscreenButton(p)
            }
            bigSpectrum(p).frame(height: 54)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(p.cardStroke))
    }

    private func control(_ p: Palette, _ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold)).foregroundStyle(p.text)
                .frame(width: 36, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 应用的显示名：优先用正在运行的应用的本地化名称（如“网易云音乐”而不是 NetEaseMusic）。
    static func appName(_ bundle: String?) -> String? {
        guard let bundle else { return nil }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.localizedName { return running }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        let info = Bundle(url: url)?.localizedInfoDictionary ?? Bundle(url: url)?.infoDictionary
        return (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String)
            ?? FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private static func time(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// 大号频谱：与菜单栏当前样式一致。
    private func bigSpectrum(_ p: Palette) -> some View {
        GeometryReader { geo in
            let count = SpectrumAnalyzer.bandCount
            let spacing: CGFloat = 3
            let width = (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count)
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(0..<count, id: \.self) { index in
                    let level = CGFloat(model.audible ? model.levels[index] : 0)
                    if model.look.shape == .dots {
                        let rows = 12
                        let lit = Int((level * CGFloat(rows)).rounded(.up))
                        VStack(spacing: 2) {
                            ForEach((0..<rows).reversed(), id: \.self) { row in
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(row < lit ? barColor(p, index: index, level: 1) : p.text3.opacity(0.25))
                                    .frame(height: (geo.size.height - CGFloat(rows - 1) * 2) / CGFloat(rows))
                            }
                        }
                        .frame(width: width)
                    } else {
                        RoundedRectangle(cornerRadius: width / 2)
                            .fill(barColor(p, index: index, level: level))
                            .frame(width: width, height: max(width, geo.size.height * level))
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
    }

    private func barColor(_ p: Palette, index: Int, level: CGFloat) -> Color {
        let base = NSColor(p.text)
        return Color(nsColor: model.look.color(level: level, album: model.nowPlaying?.tint, base: base))
    }
}

/// 菜单栏外观设置（面板和设置窗口共用）。
struct SpectrumLookEditor: View {
    /// 显示哪部分：音乐样式（形状、颜色、封面旋转、播放按钮）或灵动岛底色；all 全部。
    enum Part { case all, music, backdrop }
    let look: SpectrumLook
    var part: Part = .all
    let onChange: (SpectrumLook) -> Void

    var body: some View {
        Themed { p in
            VStack(spacing: 10) {
                if part != .backdrop {
                row(p, "形状") {
                    Segmented(options: SpectrumLook.Shape.allCases.map { ($0, $0.label) }, selection: look.shape) { value in
                        var next = look; next.shape = value; onChange(next)
                    }
                }
                row(p, "颜色") {
                    Segmented(options: SpectrumLook.Tint.allCases.map { ($0, $0.label) }, selection: look.tint) { value in
                        var next = look; next.tint = value; onChange(next)
                    }
                }
                }
                if part != .music {
                row(p, "底色") {
                    Segmented(options: SpectrumLook.Backdrop.allCases.map { ($0, $0.label) }, selection: look.backdrop) { value in
                        var next = look; next.backdrop = value; onChange(next)
                    }
                }
                }
                if part != .backdrop {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("封面旋转").font(Typo.body).foregroundStyle(p.text)
                        Text("播放时像黑胶一样转").font(Typo.caption).foregroundStyle(p.text3)
                    }
                    Spacer()
                    Toggle2(isOn: look.spin) { on in
                        var next = look; next.spin = on; onChange(next)
                    }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("播放按钮").font(Typo.body).foregroundStyle(p.text)
                        Text("上一首、播放 / 暂停、下一首").font(Typo.caption).foregroundStyle(p.text3)
                    }
                    Spacer()
                    Toggle2(isOn: look.controls) { on in
                        var next = look; next.controls = on; onChange(next)
                    }
                }
                }
            }
        }
    }

    private func row<Content: View>(_ p: Palette, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).font(Typo.body).foregroundStyle(p.text)
            Spacer(minLength: 12)
            content().frame(width: 190)
        }
    }
}

/// 设置窗口顶部的菜单栏实时预览：深色菜单栏 + 当前样式的频谱（演示电平，有正在播放的封面就用它）。
struct MenuBarPreview: NSViewRepresentable {
    let look: SpectrumLook
    var merged = false

    final class Host: NSView {
        let bars = SpectrumBarsView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        /// 合成一个岛时：指标胶囊，频谱嵌在它左侧。
        private var island: MetricsIslandView?
        private let container: NSView = {
            let view = NSView()
            view.wantsLayer = true
            return view
        }()
        private var timer: Timer?
        private var phase: Double = 0
        /// 岛的当前宽度（未合成时为 0）。
        var islandWidth: CGFloat { island?.frame.width ?? 0 }

        override init(frame: NSRect) {
            super.init(frame: frame)
            appearance = NSAppearance(named: .darkAqua)
            addSubview(container)
            addSubview(bars)
            // 示例数据：演示封面和播放器图标
            bars.artwork = Self.demoArtwork
            bars.tint = NowPlayingMonitor.dominantColor(of: Self.demoArtwork)
            bars.appIcon = SpectrumController.appIcon(bundle: "com.apple.Music")
            bars.iconTint = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music")
                .map { NSWorkspace.shared.icon(forFile: $0.path) }.flatMap(NowPlayingMonitor.dominantColor(of:))
            bars.hasMedia = true
            bars.playing = true
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        }

        required init?(coder: NSCoder) { nil }

        deinit { timer?.invalidate() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { timer?.invalidate() }
        }

        override func layout() {
            super.layout()
            if let island {
                // 音乐关闭时不显示音乐部分；岛整体居中
                island.audio = SpectrumController.isEnabled ? (bars, bars.preferredWidth) : nil
                island.backdrop = bars.look.backdropColors(tint: SpectrumController.isEnabled ? bars.tint : nil)
                // 岛按实际大小居中显示
                container.frame = bounds
                // 先定高度再取宽度：两端圆形的留白按高度计算，高度为 0 时宽度会少算
                if island.frame.height != 24 { island.frame.size.height = 24 }
                let width = island.preferredWidth
                island.frame = NSRect(x: ((bounds.width - width) / 2).rounded(), y: ((bounds.height - 24) / 2).rounded(), width: width, height: 24)
                island.layout()
                fitWindowToIsland(capsuleWidth: width - 6)
            } else {
                let width = bars.preferredWidth
                bars.frame = NSRect(x: bounds.width - width - 14, y: (bounds.height - 24) / 2, width: width, height: 24)
            }
            bars.refresh()
        }

        /// 设置窗口跟着岛定宽：窗口宽度直接由岛宽算出来（见 MenuBarPreview.windowWidth），不看预览区当前多宽——
        /// 预览区宽度会随滚动条出现 / 消失、布局先后而变，跟着它调会来回闪。
        private var pendingWidth: CGFloat?

        private func fitWindowToIsland(capsuleWidth: CGFloat) {
            // 用户按着鼠标（拖窗口、拉边框）时不改，免得和拖动打架；松手后下一次布局（最多 0.5 秒）再对齐
            guard let window, window.styleMask.contains(.resizable), !window.inLiveResize,
                  NSEvent.pressedMouseButtons == 0 else { return }
            let width = MenuBarPreview.windowWidth(capsule: capsuleWidth)
            guard abs(window.frame.width - width) >= 1 else { pendingWidth = nil; return }
            // 刚打开时会连着布局好几次：只排一次调整，执行时用最新算出的宽度，不会按旧值来回改
            let scheduled = pendingWidth != nil
            pendingWidth = width
            guard !scheduled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let width = self.pendingWidth else { return }
                self.pendingWidth = nil
                guard abs(window.frame.width - width) >= 1 else { return }
                var frame = window.frame
                frame.size.width = width
                window.minSize = NSSize(width: min(width, 640), height: window.minSize.height)
                window.setFrame(frame, display: true)
            }
        }

        func apply(_ look: SpectrumLook, merged: Bool) {
            bars.look = look
            if merged, island == nil {
                let view = MetricsIslandView(frame: .zero)
                syncIsland(view)
                bars.removeFromSuperview()
                bars.embedded = true
                container.addSubview(view)
                island = view
            } else if !merged, let island {
                island.audio = nil
                island.removeFromSuperview()
                self.island = nil
                bars.embedded = false
                addSubview(bars)
            }
            needsLayout = true
        }



        private var tickCount = 0

        /// 按当前设置用示例数据画：开了哪些指标、网速方式、蓝牙、音乐，和菜单栏上的岛一致。
        private func syncIsland(_ view: MetricsIslandView) {
            view.segments = MetricsIslandView.previewSegments()
            view.slots = IslandOrder.items.compactMap { id -> MetricsIslandView.Slot? in
                switch id {
                case "music": return .audio
                case "bluetooth": return .trailing
                default: return Metric.allCases.first { "\($0)" == id }.map { .metric($0) }
                }
            }
            // 示例：键盘、鼠标、耳机、手柄、其他设备，电量高低各不同（绿 / 橙 / 红 / 读不到）
            view.trailing = SoundController.showsBluetoothItem
                ? StatusIcons.bluetooth([(symbol: "keyboard", battery: 82), (symbol: "computermouse", battery: 15),
                                         (symbol: "headphones", battery: 38), (symbol: "gamecontroller", battery: 66),
                                         (symbol: "dot.radiowaves.left.and.right", battery: nil)]) : nil
            needsLayout = true
        }

        private func tick() {
            tickCount += 1
            if tickCount % 15 == 0, let island { syncIsland(island) }   // 设置改了很快反映到预览
            phase += 0.12
            let levels = (0..<SpectrumAnalyzer.bandCount).map { i -> Float in
                let x = Double(i)
                let base = 0.75 * exp(-pow(x - 6, 2) / 28) + 0.2
                let wobble = 0.18 * sin(phase * 1.7 + x * 0.9) + 0.12 * sin(phase * 3.1 + x * 0.37)
                return Float(min(max(base + wobble, 0.05), 1))
            }
            bars.update(levels, audible: true)
        }

        private static let demoArtwork = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSGradient(starting: NSColor(srgbRed: 1, green: 0.45, blue: 0.35, alpha: 1),
                       ending: NSColor(srgbRed: 0.6, green: 0.2, blue: 0.65, alpha: 1))!.draw(in: rect, angle: -45)
            return true
        }
    }

    /// 设置窗口的宽度：侧栏 190 + 分隔线 1 + 内容左右边距 22×2 + 岛宽（至少 480，岛很短时设置行不会挤）。
    /// 设置页不显示滚动条，所以不用给它留宽度。岛和下面的卡片因此一样宽。
    static func windowWidth(capsule: CGFloat) -> CGFloat {
        ceil(190 + 1 + 22 * 2 + max(capsule.rounded(.up), 480))
    }

    /// 按当前设置算出的设置窗口宽度（打开窗口时用，和打开后的调整同一个算法，不会跳）。
    static func windowWidth() -> CGFloat {
        let host = Host(frame: NSRect(x: 0, y: 0, width: 1200, height: 46))
        host.apply(SpectrumLook.current, merged: true)
        host.layout()
        return windowWidth(capsule: host.islandWidth - 6)
    }

    func makeNSView(context: Context) -> Host {
        let host = Host(frame: NSRect(x: 0, y: 0, width: 400, height: 46))
        host.apply(look, merged: merged)
        return host
    }

    func updateNSView(_ host: Host, context: Context) { host.apply(look, merged: merged) }
}


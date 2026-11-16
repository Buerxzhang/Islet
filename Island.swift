import AppKit
import Combine
import CoreAudio
import SwiftUI

/// 菜单栏项的保存名称。拆回独立项时换一代名字，让系统按创建顺序重新排好。
enum StatusItemNames {
    private static let key = "statusItemGeneration"
    private static var generation: Int { UserDefaults.standard.integer(forKey: key) }
    static let bases = ["network", "fan", "temperature", "power", "disk", "memory", "gpu", "cpu", "spectrum", "island", "bluetooth"]

    static func name(_ base: String, generation: Int = generation) -> String {
        generation == 0 ? "islet.\(base)" : "islet.\(base).\(generation)"
    }

    /// 换下一代名字，并清掉上一代在系统里留下的位置记录。
    static func renew() {
        let defaults = UserDefaults.standard
        let old = generation
        for base in bases {
            let name = name(base, generation: old)
            for prefix in ["NSStatusItem VisibleCC ", "NSStatusItem Preferred Position ", "NSStatusItem Visible "] {
                defaults.removeObject(forKey: prefix + name)
            }
        }
        defaults.set(old + 1, forKey: key)
    }
}

/// 合并显示时承载频谱的菜单栏项（指标灵动岛）。
protocol SpectrumHost: AnyObject {
    /// 放入（或移除，nil）频谱视图。
    func embed(_ view: SpectrumBarsView?)
    /// 频谱出现 / 消失 / 宽度或颜色变化，需要重新排版。
    func spectrumLayoutChanged()
}

/// 透明按钮承载胶囊，把左右键交给与菜单栏共用的分发逻辑。
final class FloatingIslandButton: NSButton {
    var canDrag = false
    var onDrag: (NSPoint, Bool) -> Void = { _, _ in }
    private var mouseStart: NSPoint?
    private var windowStart: NSPoint = .zero
    private var dragged = false

    override func mouseDown(with event: NSEvent) {
        guard canDrag, !event.modifierFlags.contains(.control), let window else {
            super.mouseDown(with: event)
            return
        }
        mouseStart = NSEvent.mouseLocation
        windowStart = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseStart else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - mouseStart.x, dy = current.y - mouseStart.y
        guard dragged || hypot(dx, dy) >= 4 else { return }
        dragged = true
        onDrag(NSPoint(x: windowStart.x + dx, y: windowStart.y + dy), false)
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = mouseStart else { super.mouseUp(with: event); return }
        mouseStart = nil
        let current = NSEvent.mouseLocation
        if dragged {
            onDrag(NSPoint(x: windowStart.x + current.x - start.x, y: windowStart.y + current.y - start.y), true)
        } else if bounds.contains(convert(event.locationInWindow, from: nil)) {
            sendAction(action, to: target)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            sendAction(action, to: target)
        }
    }
}

/// “指标灵动岛”：把各指标合成一块深色胶囊。
/// 不透明的胶囊盖住了系统在菜单栏项下面画的按下 / 打开底色，切换指标时不会整片闪动；
/// 当前打开的那一段由这里自己点亮。
final class MetricsIslandView: NSView {
    static let defaultsKey = "metricsIsland"
    static var isEnabled: Bool { true }   // 只保留灵动岛模式

    /// 从左到右的指标和各自的图像。
    var segments: [(metric: Metric, image: NSImage)] = [] { didSet { needsDisplay = true } }
    var selected: Metric? { didSet { if oldValue != selected { needsDisplay = true } } }
    /// 指标之后的蓝牙设备（图标 + 电量）；没有已连接设备时为 nil。
    var trailing: NSImage? { didSet { needsDisplay = true; needsLayout = true } }
    var trailingSelected = false { didSet { if oldValue != trailingSelected { needsDisplay = true } } }
    /// 左侧的音频部分（频谱视图及其宽度，含视图自带的左右各 3 点留白）。
    var audio: (view: NSView, width: CGFloat)? {
        didSet {
            if oldValue?.view !== audio?.view { oldValue?.view.removeFromSuperview() }
            if let view = audio?.view, view.superview !== audioClip {
                if audioClip.superview == nil { addSubview(audioClip) }
                audioClip.addSubview(view)
            }
            needsLayout = true
            needsDisplay = true
        }
    }
    /// 音频部分展开的程度：0 收起，1 完全展开（动画中间值）。菜单栏项宽度跟着变（不预留空位）。
    var reveal: CGFloat = 1 {
        didSet {
            needsLayout = true
            needsDisplay = true
            if oldValue != reveal { onWidthChange?(preferredWidth) }
        }
    }
    /// 宽度随展开程度变化时通知菜单栏项调整长度。
    var onWidthChange: ((CGFloat) -> Void)?
    /// 临时提示（如调音量）：盖在胶囊上显示一会儿，宽度不变。
    struct HUD { var symbol: String; var fraction: Double; var text: String }
    private(set) var hud: HUD?
    private var hudAlpha: CGFloat = 0 { didSet { needsLayout = true; needsDisplay = true } }
    private var hudTimer: Timer?
    private var hudHide: DispatchWorkItem?

    /// 显示提示：淡入，停 1.5 秒后淡出。连续调用时只刷新内容并重新计时。
    func showHUD(_ value: HUD) {
        hud = value
        needsDisplay = true
        fadeHUD(to: 1)
        hudHide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fadeHUD(to: 0) }
        hudHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// 离屏渲染：直接显示提示（不做动画）。
    func setHUDImmediately(_ value: HUD) { hud = value; hudAlpha = 1 }

    private func fadeHUD(to target: CGFloat) {
        hudTimer?.invalidate()
        let from = hudAlpha, start = Date(), duration = 0.2
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = min(Date().timeIntervalSince(start) / duration, 1)
            self.hudAlpha = from + (target - from) * CGFloat(t)
            if t >= 1 { timer.invalidate(); if target == 0 { self.hud = nil } }
        }
        RunLoop.main.add(timer, forMode: .common)
        hudTimer = timer
    }

    /// 胶囊底色，从左到右（一种颜色为纯色，两种为渐变）。
    var backdrop = [NSColor(white: 0.06, alpha: 0.97)] {
        didSet {
            guard oldValue != backdrop else { return }
            // 换歌、换程序时底色不突变：从当前看到的颜色渐变过去（离屏渲染没有窗口，直接换）
            if window != nil { ColorFade.start(&backdropFade, from: shownBackdrop, to: backdrop) { [weak self] in self?.needsDisplay = true } }
            else { backdropFade = nil }
            needsDisplay = true
        }
    }
    private var backdropFade: ColorFade?
    /// 此刻画出来的底色（渐变过程中是两者之间的颜色）。
    private var shownBackdrop: [NSColor] { backdropFade?.colors ?? backdrop }
    static let dividerSpace: CGFloat = 8   // 分隔线两侧的留白

    /// 设置里的预览：按当前设置（显示哪些、顺序、网速方式、单位）用示例数据画。
    static func previewSegments() -> [(metric: Metric, image: NSImage)] {
        let demo = Dictionary(uniqueKeysWithValues: demoSegments().map { ($0.metric, $0.image) })
        return MetricOrder.current.filter(\.isShown).compactMap { metric in
            switch metric {
            case .temperature:
                return (metric, StatusIcons.labeled("TEMP", value: Units.degrees(52), level: .normal, widest: "108°"))
            case .network:
                let down = StatusIcons.RateRow(arrow: "↓", value: Units.networkRate(66_000), active: true)
                let up = StatusIcons.RateRow(arrow: "↑", value: Units.networkRate(2_200), active: true)
                return (metric, StatusIcons.network(SpeedSetting.direction.selection == 1 ? [up, down] : [down]))
            default:
                return demo[metric].map { (metric, $0) }
            }
        }
    }

    /// 演示用指标（设置预览、离屏渲染）。
    static func demoSegments() -> [(metric: Metric, image: NSImage)] {
        [
            (.cpu, StatusIcons.labeled("CPU", value: "18%", level: .normal, widest: "100%")),
            (.gpu, StatusIcons.labeled("GPU", value: "32%", level: .normal, widest: "100%")),
            (.memory, StatusIcons.labeled("MEM", value: "10.2G", level: .normal, widest: "88.8G")),
            (.disk, StatusIcons.labeled("DISK", value: "51%", level: .normal, widest: "100%")),
            (.power, StatusIcons.labeled("PWR", value: "21W", level: .normal, widest: "188W")),
            (.temperature, StatusIcons.labeled("TEMP", value: "52°", level: .normal, widest: "108°")),
            (.fan, StatusIcons.labeled("FAN", value: "1000", level: .normal, widest: "8888")),
            (.network, StatusIcons.network([.init(arrow: "↓", value: "66K", active: true)])),
        ]
    }

    static let padding: CGFloat = 7     // 胶囊左右内边距
    static let gap: CGFloat = 6         // 段间距

    private let maskLayer = CAShapeLayer()
    /// 描边：深色壁纸上黑色胶囊和菜单栏融在一起，靠一圈细亮边勾出轮廓。放在最上层，音乐部分也不会盖住它。
    private let borderLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = nil
        layer.strokeColor = NSColor(white: 1, alpha: 0.24).cgColor
        layer.lineWidth = 1
        layer.zPosition = 100
        return layer
    }()
    private var revealTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)  // 胶囊总是深色：文字按深色外观画成白色
        wantsLayer = true
        layer?.mask = maskLayer                      // 嵌入的频谱只显示在胶囊范围内
        layer?.addSublayer(borderLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // 点击交给菜单栏按钮

    // MARK: 几何（整体靠右排：音乐展开 / 收起时，它右边的内容不动，左边的内容随之移动）

    /// 岛上的一项：音乐、某个指标、蓝牙。
    enum Slot: Equatable { case audio, metric(Metric), trailing }
    /// 从左到右的排列（可在设置里拖动调整）；为空时按默认：音乐、指标、蓝牙。
    var slots: [Slot] = [] { didSet { if oldValue != slots { needsLayout = true; needsDisplay = true } } }
    /// 音乐部分的裁切容器：展开过程中只露出已展开的宽度，不盖住旁边的指标。
    private let audioClip: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        return view
    }()

    private var audioContent: CGFloat { audio.map { $0.width - 6 } ?? 0 }
    /// 音乐部分最左边是圆形封面（排在最左时让它和胶囊圆头同心）。
    var audioLeadsWithCircle = false { didSet { if oldValue != audioLeadsWithCircle { needsLayout = true; needsDisplay = true } } }

    /// 两端的内边距：文字留 7；圆形（封面、蓝牙电量圈）和胶囊圆头同心，四周留白一样（16 的圆在 21 高的胶囊里各留 2.5）。
    private var roundPadding: CGFloat { max((bounds.height - 1 - 16) / 2, 0) }
    private func edgePadding(_ slot: Slot?) -> CGFloat {
        switch slot {
        case .audio?: return audioLeadsWithCircle ? Self.padding + (roundPadding - Self.padding) * min(reveal, 1) : Self.padding
        case .trailing?: return roundPadding
        default: return Self.padding
        }
    }
    private var leadingPadding: CGFloat { edgePadding(activeSlots.first) }
    /// 右端：音乐排在最右时最右边是播放器图标、不是封面，按文字留白。
    private var trailingPadding: CGFloat { activeSlots.last == .audio ? Self.padding : edgePadding(activeSlots.last) }
    private var dividerTotal: CGFloat { Self.dividerSpace * 2 + 1 }

    /// 当前实际显示的项（没有内容的项跳过）。
    private var activeSlots: [Slot] {
        let base: [Slot] = slots.isEmpty ? [.audio] + segments.map { .metric($0.metric) } + [.trailing] : slots
        return base.filter { slot in
            switch slot {
            case .audio: return audio != nil
            case .metric(let metric): return segments.contains { $0.metric == metric }
            case .trailing: return trailing != nil
            }
        }
    }

    private func width(of slot: Slot) -> CGFloat {
        switch slot {
        case .audio: return audioContent * reveal
        case .metric(let metric): return segments.first { $0.metric == metric }?.image.size.width ?? 0
        case .trailing: return trailing?.size.width ?? 0
        }
    }

    private struct Placement { var slot: Slot; var rect: NSRect }

    /// 各项的位置 + 分隔线位置。挨着音乐的间距是分隔线（随展开程度出现），其他是普通间距。
    private func layoutSlots() -> (items: [Placement], dividers: [CGFloat], width: CGFloat) {
        let list = activeSlots
        guard !list.isEmpty else { return ([], [], 0) }
        var spans: [CGFloat] = []
        for index in 0..<(list.count - 1) {
            let a = list[index], b = list[index + 1]
            if a == .audio || b == .audio {
                let audioIndex = a == .audio ? index : index + 1
                let atEdge = audioIndex == 0 || audioIndex == list.count - 1
                // 音乐在两端：收起时不留空；在中间：收起时两侧各留半个间距，合起来正好一个普通间距
                spans.append(dividerTotal * reveal + (atEdge ? 0 : Self.gap / 2 * (1 - reveal)))
            } else {
                spans.append(Self.gap)
            }
        }
        let total = list.map(width(of:)).reduce(0, +) + spans.reduce(0, +)
        var x = bounds.width - 3 - trailingPadding - total
        var items: [Placement] = [], dividers: [CGFloat] = []
        for (index, slot) in list.enumerated() {
            let w = width(of: slot)
            items.append(Placement(slot: slot, rect: NSRect(x: x, y: 0, width: w, height: bounds.height)))
            x += w
            if index < spans.count {
                if slot == .audio || list[index + 1] == .audio { dividers.append(x + spans[index] / 2) }
                x += spans[index]
            }
        }
        return (items, dividers, total)
    }

    /// 菜单栏项的宽度：各项 + 间距 + 按展开程度露出的音乐部分。
    var preferredWidth: CGFloat {
        guard !segments.isEmpty || audio != nil || trailing != nil else { return 0 }
        return ceil(layoutSlots().width + leadingPadding + trailingPadding) + 6
    }

    /// 当前可见的胶囊：靠右，宽度不超过菜单栏项（换位置动画中跟着变）。
    private var capsule: NSRect {
        let width = max(min(preferredWidth - 6, bounds.width - 6), 0)
        return NSRect(x: bounds.width - 3 - width, y: 0.5, width: width, height: bounds.height - 1)
    }

    private func rect(of slot: Slot) -> NSRect? { layoutSlots().items.first { $0.slot == slot }?.rect }

    /// 蓝牙部分的范围（点击判断、面板箭头定位）。
    var trailingFrame: NSRect? { rect(of: .trailing).map { $0.insetBy(dx: -Self.gap / 2, dy: 0) } }

    /// 音乐部分的点击范围（展开过半才算）。
    var audioRect: NSRect? {
        guard reveal > 0.5, let rect = rect(of: .audio) else { return nil }
        return rect.insetBy(dx: -Self.dividerSpace, dy: 0)
    }

    override func layout() {
        super.layout()
        if let audio, let rect = rect(of: .audio) {
            // 裁切容器只露出已展开的部分；频谱视图靠右放在容器里
            audioClip.frame = NSRect(x: rect.minX, y: 0, width: max(rect.width, 0), height: bounds.height)
            audio.view.frame = NSRect(x: rect.width - audioContent - 3, y: 0, width: audio.width, height: bounds.height)
            audioClip.alphaValue = min(reveal * 1.4, 1) * (1 - hudAlpha)
        }
        let shape = capsule
        let radius = min(shape.height, shape.width) / 2
        maskLayer.frame = bounds
        maskLayer.path = CGPath(roundedRect: shape, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let edge = shape.insetBy(dx: 0.5, dy: 0.5)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        borderLayer.frame = bounds
        borderLayer.path = edge.width > 0 ? CGPath(roundedRect: edge, cornerWidth: radius, cornerHeight: radius, transform: nil) : nil
        CATransaction.commit()
    }

    /// 展开 / 收起音频部分（只在视图里画，不改菜单栏项宽度）。
    func setRevealed(_ on: Bool, animated: Bool) {
        revealTimer?.invalidate()
        let target: CGFloat = on ? 1 : 0
        guard animated, reveal != target else { reveal = target; return }
        let from = reveal, start = Date(), duration = on ? 0.45 : 0.3
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = min(Date().timeIntervalSince(start) / duration, 1)
            let e: Double
            if on {
                let c = 1.2, u = t - 1
                e = 1 + (c + 1) * u * u * u + c * u * u      // 回弹
            } else {
                e = 1 - pow(1 - t, 3)
            }
            self.reveal = max(0, from + (target - from) * CGFloat(e))
            if t >= 1 { timer.invalidate(); self.reveal = target }
        }
        RunLoop.main.add(timer, forMode: .common)
        revealTimer = timer
    }

    /// 每个指标在视图里的范围（点击判断、面板箭头定位都用它）。
    func frames() -> [(metric: Metric, rect: NSRect)] {
        layoutSlots().items.compactMap { item in
            guard case .metric(let metric) = item.slot else { return nil }
            return (metric, item.rect.insetBy(dx: -Self.gap / 2, dy: 0))
        }
    }

    func metric(at point: NSPoint) -> Metric? {
        guard capsule.insetBy(dx: -2, dy: -4).contains(point) else { return nil }
        return frames().first { $0.rect.contains(point) }?.metric
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !segments.isEmpty || audio != nil || trailing != nil else { return }
        let placements = layoutSlots()
        let shape = capsule
        guard shape.width > 0 else { return }
        let radius = min(shape.height, shape.width) / 2
        let path = NSBezierPath(roundedRect: shape, xRadius: radius, yRadius: radius)
        let backdrop = shownBackdrop
        if backdrop.count > 1, backdrop.first != backdrop.last, let gradient = NSGradient(colors: backdrop) {
            gradient.draw(in: path, angle: 0)
        } else {
            (backdrop.first ?? .black).setFill()
            path.fill()
        }
        path.addClip()
        if reveal > 0 {
            NSColor(white: 1, alpha: 0.18 * min(reveal, 1)).setFill()
            for x in placements.dividers { NSRect(x: x - 0.5, y: (bounds.height - 12) / 2, width: 1, height: 12).fill() }
        }
        for (metric, rect) in frames() {
            if metric == selected {
                let highlight = rect.insetBy(dx: Self.gap / 2 - 3, dy: 0).intersection(shape.insetBy(dx: 2, dy: 2))
                NSColor(white: 1, alpha: 0.16).setFill()
                NSBezierPath(roundedRect: highlight, xRadius: 6, yRadius: 6).fill()
            }
            guard let image = segments.first(where: { $0.metric == metric })?.image else { continue }
            let origin = NSPoint(x: rect.minX + Self.gap / 2, y: (rect.midY - image.size.height / 2).rounded())
            image.draw(in: NSRect(origin: origin, size: image.size))
        }
        if let trailing, let rect = trailingFrame {
            if trailingSelected {
                let highlight = rect.insetBy(dx: Self.gap / 2 - 3, dy: 0).intersection(shape.insetBy(dx: 2, dy: 2))
                NSColor(white: 1, alpha: 0.16).setFill()
                NSBezierPath(roundedRect: highlight, xRadius: 6, yRadius: 6).fill()
            }
            trailing.draw(in: NSRect(x: rect.minX + Self.gap / 2, y: (rect.midY - trailing.size.height / 2).rounded(),
                                     width: trailing.size.width, height: trailing.size.height))
        }
        // 临时提示：先用底色盖住胶囊，再画图标、进度条和数值
        if let hud, hudAlpha > 0 {
            (shownBackdrop.first ?? .black).withAlphaComponent(hudAlpha).setFill()
            path.fill()
            let alpha = hudAlpha
            let height = bounds.height
            let y: CGFloat = 0
            var x = shape.minX + Self.padding + 4
            if let symbol = NSImage(systemSymbolName: hud.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold).applying(.init(paletteColors: [.white]))) {
                symbol.draw(in: NSRect(x: x, y: y + (height - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height),
                            from: .zero, operation: .sourceOver, fraction: alpha)
                x += symbol.size.width + 8
            }
            let text = hud.text as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                                                             .foregroundColor: NSColor.white.withAlphaComponent(alpha)]
            let textSize = text.size(withAttributes: attributes)
            let textX = shape.maxX - Self.padding - 4 - textSize.width
            text.draw(at: NSPoint(x: textX, y: y + (height - textSize.height) / 2), withAttributes: attributes)
            let track = NSRect(x: x, y: y + height / 2 - 2, width: max(textX - 10 - x, 10), height: 4)
            NSColor.white.withAlphaComponent(0.2 * alpha).setFill()
            NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
            var filled = track
            filled.size.width = track.width * CGFloat(min(max(hud.fraction, 0), 1))
            NSColor.white.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()
        }
    }
}

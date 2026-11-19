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
    /// 从左到右的指标和各自的图像。
    var segments: [(metric: Metric, image: NSImage)] = [] {
        didSet {
            needsLayout = true
            needsDisplay = true
            let old = Set(oldValue.map(\.metric)), new = Set(segments.map(\.metric))
            guard old != new else { return }
            // 去掉的指标留着最后一帧图像，淡出缩没后再真正拿掉
            for (metric, image) in oldValue where !new.contains(metric) { leaving[.metric(metric)] = image }
            for metric in new { leaving[.metric(metric)] = nil }
            beginTransition()
        }
    }
    var selected: Metric? { didSet { if oldValue != selected { needsDisplay = true } } }
    /// 指标之后的蓝牙设备（图标 + 电量）；没有已连接设备时为 nil。
    var trailing: NSImage? {
        didSet {
            needsDisplay = true
            needsLayout = true
            guard (oldValue == nil) != (trailing == nil) else { return }
            leaving[.trailing] = trailing == nil ? oldValue : nil
            beginTransition()
        }
    }
    var trailingSelected = false { didSet { if oldValue != trailingSelected { needsDisplay = true } } }
    /// 左侧的音频部分（频谱视图及其宽度，含视图自带的左右各 3 点留白）。
    var audio: (view: NSView, width: CGFloat)? {
        didSet {
            removingAudio = false
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

    /// 演示用指标（离屏渲染）。
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
    static let splitGap: CGFloat = 5    // 分体时各小胶囊之间的空隙

    /// 分体：音乐、指标、蓝牙各成一个小胶囊（默认合成一个）。
    static let splitKey = "splitIsland"
    static var splits: Bool { UserDefaults.standard.bool(forKey: splitKey) }
    var split = false {
        didSet {
            guard oldValue != split else { return }
            // 合体 / 分体切换直接换，不和出现 / 消失的过渡混在一起
            endTransition()
            lastShown = nil
            needsLayout = true
            needsDisplay = true
            onWidthChange?(preferredWidth)
        }
    }

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
    enum Slot: Hashable { case audio, metric(Metric), trailing }
    /// 从左到右的排列（可在设置里拖动调整）；为空时按默认：音乐、指标、蓝牙。
    var slots: [Slot] = [] { didSet { if oldValue != slots { beginTransition() } } }
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
    private var trailingPadding: CGFloat { activeSlots.last.map(groupTrail) ?? Self.padding }
    /// 音乐部分的右端：圆形播放器图标和胶囊圆头同心；没有图标（只有频谱）时按文字留白。
    private var audioTrailPadding: CGFloat {
        guard (audio?.view as? SpectrumBarsView)?.trailsWithCircle == true else { return Self.padding }
        return Self.padding + (roundPadding - Self.padding) * min(reveal, 1)
    }
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

    /// 分体时属于哪个小胶囊：音乐、指标、蓝牙。
    private func kind(_ slot: Slot) -> Int {
        switch slot {
        case .audio: return 0
        case .metric: return 1
        case .trailing: return 2
        }
    }

    /// 小胶囊的左右内边距（音乐那段随展开程度缩放，收起时连同空隙一起消失）。
    private func groupLead(_ slot: Slot) -> CGFloat { edgePadding(slot) }
    private func groupTrail(_ slot: Slot) -> CGFloat { slot == .audio ? audioTrailPadding : edgePadding(slot) }

    /// 各项的位置 + 分隔线位置。挨着音乐的间距是分隔线（随展开程度出现），其他是普通间距。
    /// 分体时，不同小胶囊之间是“左边胶囊的右内边距 + 空隙 + 右边胶囊的左内边距”，没有分隔线。
    /// x 相对视图右边缘（视图宽度逐帧变化时不受影响）。
    private func layoutSlots() -> (items: [Placement], width: CGFloat) {
        let list = activeSlots
        guard !list.isEmpty else { return ([], 0) }
        var spans: [CGFloat] = []
        for index in 0..<(list.count - 1) {
            let a = list[index], b = list[index + 1]
            if split, kind(a) != kind(b) {
                let full = groupTrail(a) + Self.splitGap + groupLead(b)
                spans.append(a == .audio || b == .audio ? full * min(reveal, 1) : full)
            } else if a == .audio || b == .audio {
                let audioIndex = a == .audio ? index : index + 1
                let atEdge = audioIndex == 0 || audioIndex == list.count - 1
                // 音乐在两端：收起时不留空；在中间：收起时两侧各留半个间距，合起来正好一个普通间距
                spans.append(dividerTotal * reveal + (atEdge ? 0 : Self.gap / 2 * (1 - reveal)))
            } else {
                spans.append(Self.gap)
            }
        }
        let total = list.map(width(of:)).reduce(0, +) + spans.reduce(0, +)
        var x = -3 - trailingPadding - total
        var items: [Placement] = []
        for (index, slot) in list.enumerated() {
            let w = width(of: slot)
            items.append(Placement(slot: slot, rect: NSRect(x: x, y: 0, width: w, height: bounds.height)))
            x += w
            if index < spans.count { x += spans[index] }
        }
        return (items, total)
    }

    // MARK: 出现 / 消失的过渡（显示 / 隐藏某项、蓝牙连上 / 断开、调整顺序）

    /// 一帧布局：各项位置和不透明度、分体时各小胶囊的左右范围、总宽度。x 都相对视图右边缘。
    private struct Snapshot {
        var items: [Slot: (rect: NSRect, alpha: CGFloat)] = [:]
        var shapes: [Int: (minX: CGFloat, maxX: CGFloat)] = [:]   // 键：种类 × 16 + 第几个同种小胶囊
        var width: CGFloat = 0
        var order: [Slot] = []                                     // 从左到右
    }
    /// 正在淡出的项：已从数据里去掉，留着图像画完消失过渡。
    private var leaving: [Slot: NSImage] = [:]
    private var transition: Snapshot?           // 过渡起点
    private var transitionProgress: CGFloat = 1
    private var transitionTimer: Timer?
    private var lastShown: Snapshot?            // 上一次布局时画出来的样子（新过渡从这里开始，中途改变也不跳）

    /// 数据对应的最终布局。
    private func target() -> Snapshot {
        var result = Snapshot()
        // 音乐收起（没在播放）时不算：只剩它时整个胶囊隐藏，不留一个空的黑胶囊
        guard !segments.isEmpty || (audio != nil && reveal > 0) || trailing != nil else { return result }
        let layout = layoutSlots()
        result.width = ceil(layout.width + leadingPadding + trailingPadding) + 6
        for item in layout.items { result.items[item.slot] = (item.rect, 1) }
        result.order = layout.items.map(\.slot)
        guard split else { return result }
        let lower = -3 - (result.width - 6), upper: CGFloat = -3
        let items = layout.items
        var start = 0, counts: [Int: Int] = [:]
        for end in items.indices where end == items.count - 1 || kind(items[end].slot) != kind(items[end + 1].slot) {
            let first = items[start], last = items[end]
            let scale: CGFloat = first.slot == .audio ? min(reveal, 1) : 1
            let minX = max(first.rect.minX - groupLead(first.slot) * scale, lower)
            let maxX = min(last.rect.maxX + groupTrail(last.slot) * scale, upper)
            let k = kind(first.slot)
            result.shapes[k * 16 + counts[k, default: 0]] = (minX, max(maxX, minX))
            counts[k, default: 0] += 1
            start = end + 1
        }
        return result
    }

    /// 此刻画出来的布局：过渡中是起点和最终布局之间。
    private func current() -> Snapshot {
        let to = target()
        guard let from = transition else { return to }
        let e = transitionProgress
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * e }
        // 排列：按最终顺序；正在淡出的项留在起点时的位置（插在它原来左边的那一项后面），原地缩没，不滑到别处
        var order = to.order
        for (index, slot) in from.order.enumerated() where !order.contains(slot) {
            let prev = from.order[..<index].last { order.contains($0) }
            order.insert(slot, at: prev.flatMap { order.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        }
        // 一边没有的项：放在左右邻居之间的空隙中间，宽度 0、透明
        func anchor(_ slot: Slot, in items: [Slot: (rect: NSRect, alpha: CGFloat)]) -> (rect: NSRect, alpha: CGFloat) {
            let index = order.firstIndex(of: slot) ?? 0
            let prev = order[..<index].last { items[$0] != nil }.flatMap { items[$0]?.rect }
            let next = order[(index + 1)...].first { items[$0] != nil }.flatMap { items[$0]?.rect }
            let x = prev.flatMap { p in next.map { (p.maxX + $0.minX) / 2 } } ?? prev?.maxX ?? next?.minX ?? -3
            return (NSRect(x: x, y: 0, width: 0, height: bounds.height), 0)
        }
        var result = Snapshot(width: mix(from.width, to.width), order: order)
        for slot in order {
            let a = from.items[slot] ?? anchor(slot, in: from.items)
            let b = to.items[slot] ?? anchor(slot, in: to.items)
            result.items[slot] = (NSRect(x: mix(a.rect.minX, b.rect.minX), y: 0,
                                         width: max(mix(a.rect.width, b.rect.width), 0), height: bounds.height),
                                  mix(a.alpha, b.alpha))
        }
        for key in Set(from.shapes.keys).union(to.shapes.keys) {
            // 一边没有的小胶囊：从另一边的中心长出来 / 缩回去
            func collapsed(_ s: (minX: CGFloat, maxX: CGFloat)) -> (minX: CGFloat, maxX: CGFloat) { ((s.minX + s.maxX) / 2, (s.minX + s.maxX) / 2) }
            guard let a = from.shapes[key] ?? to.shapes[key].map(collapsed),
                  let b = to.shapes[key] ?? from.shapes[key].map(collapsed) else { continue }
            result.shapes[key] = (mix(a.minX, b.minX), mix(a.maxX, b.maxX))
        }
        return result
    }

    private func beginTransition() {
        needsLayout = true
        needsDisplay = true
        guard window != nil, let from = lastShown else { endTransition(); return }
        transition = from
        transitionProgress = 0
        transitionTimer?.invalidate()
        let start = Date(), duration = 0.32
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = min(Date().timeIntervalSince(start) / duration, 1)
            self.transitionProgress = CGFloat(1 - pow(1 - t, 3))
            if t >= 1 { self.endTransition() }
            self.needsLayout = true
            self.needsDisplay = true
            self.onWidthChange?(self.preferredWidth)
        }
        RunLoop.main.add(timer, forMode: .common)
        transitionTimer = timer
    }

    private func endTransition() {
        transitionTimer?.invalidate()
        transitionTimer = nil
        transition = nil
        transitionProgress = 1
        leaving.removeAll()
    }

    /// 此刻画出来的各项（视图坐标，从左到右）。
    private func shownItems() -> [(slot: Slot, rect: NSRect, alpha: CGFloat)] {
        let now = current()
        return now.order.compactMap { slot in
            now.items[slot].map { (slot, $0.rect.offsetBy(dx: bounds.width, dy: 0), $0.alpha) }
        }
    }

    /// 菜单栏项的宽度：各项 + 间距 + 按展开程度露出的音乐部分（过渡中逐帧变化）。
    var preferredWidth: CGFloat { current().width }

    /// 当前可见的胶囊：靠右，宽度不超过菜单栏项（换位置动画中跟着变）。
    private var capsule: NSRect {
        let width = max(min(preferredWidth - 6, bounds.width - 6), 0)
        return NSRect(x: bounds.width - 3 - width, y: 0.5, width: width, height: bounds.height - 1)
    }

    /// 实际画出来的胶囊：合体时就是整个胶囊；分体时每段一个（收起中的音乐段太窄时不画）。
    private var shapes: [NSRect] {
        let whole = capsule
        guard split, whole.width > 0 else { return [whole] }
        let result = current().shapes.values.compactMap { shape -> NSRect? in
            let minX = max(shape.minX + bounds.width, whole.minX), maxX = min(shape.maxX + bounds.width, whole.maxX)
            return maxX - minX >= 2 ? NSRect(x: minX, y: whole.minY, width: maxX - minX, height: whole.height) : nil
        }
        return result.isEmpty ? [whole] : result.sorted { $0.minX < $1.minX }
    }

    private func capsulePath(_ rects: [NSRect], inset: CGFloat = 0) -> CGPath {
        let path = CGMutablePath()
        for rect in rects {
            let r = rect.insetBy(dx: inset, dy: inset)
            guard r.width > 0 else { continue }
            let radius = min(r.height, r.width) / 2
            path.addRoundedRect(in: r, cornerWidth: radius, cornerHeight: radius)
        }
        return path
    }

    /// 包含某个位置的那个胶囊（高亮、提示框都限制在它里面）。
    private func shape(containing rect: NSRect) -> NSRect {
        let all = shapes
        return all.first { $0.intersects(rect) } ?? all.first ?? capsule
    }

    /// 有数据的项此刻的位置（正在淡出的不算）。
    private func rect(of slot: Slot) -> NSRect? {
        switch slot {
        case .audio: guard audio != nil else { return nil }
        case .trailing: guard trailing != nil else { return nil }
        case .metric(let metric): guard segments.contains(where: { $0.metric == metric }) else { return nil }
        }
        return shownItems().first { $0.slot == slot }?.rect
    }

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
            audioClip.alphaValue = min(reveal * 1.4, 1)
        }
        lastShown = current()
        let all = shapes
        maskLayer.frame = bounds
        maskLayer.path = capsulePath(all)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        borderLayer.frame = bounds
        borderLayer.path = capsulePath(all, inset: 0.5)
        CATransaction.commit()
    }

    /// 展开 / 收起音频部分（只在视图里画，不改菜单栏项宽度）。
    func setRevealed(_ on: Bool, animated: Bool, completion: (() -> Void)? = nil) {
        revealTimer?.invalidate()
        let target: CGFloat = on ? 1 : 0
        guard animated, reveal != target else { reveal = target; completion?(); return }
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
            if t >= 1 { timer.invalidate(); self.reveal = target; completion?() }
        }
        RunLoop.main.add(timer, forMode: .common)
        revealTimer = timer
    }

    private var removingAudio = false
    /// 拿掉音乐部分（关掉音乐模块）：先收起，收完再移除视图。
    func removeAudio(animated: Bool) {
        guard let current = audio, !removingAudio else { return }
        guard animated, window != nil, reveal > 0 else { audio = nil; return }
        removingAudio = true
        // 频谱那边已经把视图摘下来了：收起过程中先放回来
        if current.view.superview !== audioClip { audioClip.addSubview(current.view) }
        setRevealed(false, animated: true) { [weak self] in
            guard let self, self.audio?.view === current.view else { return }
            self.audio = nil
        }
    }

    /// 每个指标在视图里的范围（点击判断、面板箭头定位都用它）。
    func frames() -> [(metric: Metric, rect: NSRect)] {
        shownItems().compactMap { item in
            guard case .metric(let metric) = item.slot, segments.contains(where: { $0.metric == metric }) else { return nil }
            return (metric, item.rect.insetBy(dx: -Self.gap / 2, dy: 0))
        }
    }

    func metric(at point: NSPoint) -> Metric? {
        guard capsule.insetBy(dx: -2, dy: -4).contains(point) else { return nil }
        return frames().first { $0.rect.contains(point) }?.metric
    }

    override func draw(_ dirtyRect: NSRect) {
        let items = shownItems()
        guard !items.isEmpty else { return }
        let shape = capsule
        guard shape.width > 0 else { return }
        let parts = shapes
        let path = NSBezierPath()
        for part in parts {
            let radius = min(part.height, part.width) / 2
            path.append(NSBezierPath(roundedRect: part, xRadius: radius, yRadius: radius))
        }
        // 底色按整个胶囊的宽度铺开，分体时各段接着同一条渐变
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let backdrop = shownBackdrop
        if backdrop.count > 1, backdrop.first != backdrop.last, let gradient = NSGradient(colors: backdrop) {
            gradient.draw(in: shape, angle: 0)
        } else {
            (backdrop.first ?? .black).setFill()
            shape.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        path.addClip()
        // 分隔线：音乐和相邻项之间的空隙中间（合体时）
        if reveal > 0, !split {
            NSColor(white: 1, alpha: 0.18 * min(reveal, 1)).setFill()
            for (a, b) in zip(items, items.dropFirst()) where a.slot == .audio || b.slot == .audio {
                let x = (a.rect.maxX + b.rect.minX) / 2
                NSRect(x: x - 0.5, y: (bounds.height - 12) / 2, width: 1, height: 12).fill()
            }
        }
        let highlighted = [frames().first { $0.metric == selected }?.rect, trailingSelected ? trailingFrame : nil]
        for rect in highlighted.compactMap({ $0 }) {
            let highlight = rect.insetBy(dx: Self.gap / 2 - 3, dy: 0).intersection(self.shape(containing: rect).insetBy(dx: 2, dy: 2))
            NSColor(white: 1, alpha: 0.16).setFill()
            NSBezierPath(roundedRect: highlight, xRadius: 6, yRadius: 6).fill()
        }
        // 各项图像：过渡中只露出当前宽度、按不透明度淡入淡出
        for item in items where item.alpha > 0.01 && item.rect.width > 0.5 {
            let image: NSImage?
            switch item.slot {
            case .audio: continue
            case .metric(let metric): image = segments.first { $0.metric == metric }?.image ?? leaving[item.slot]
            case .trailing: image = trailing ?? leaving[.trailing]
            }
            guard let image else { continue }
            NSGraphicsContext.saveGraphicsState()
            item.rect.clip()
            image.draw(in: NSRect(x: item.rect.minX, y: (item.rect.midY - image.size.height / 2).rounded(),
                                  width: image.size.width, height: image.size.height),
                       from: .zero, operation: .sourceOver, fraction: item.alpha)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

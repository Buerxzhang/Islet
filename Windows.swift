import AppKit
import ServiceManagement
import SwiftUI

// 独立窗口：设置、温度曲线、规则。风格与弹出面板一致（FunFan 设计令牌）。

// MARK: - 窗口管理

final class WindowManager {
    private var windows: [String: NSWindow] = [:]

    /// 打开（或前置）一个 SwiftUI 窗口。
    func show<Content: View>(_ id: String, title: String, size: NSSize, resizable: Bool = false,
                             onClose: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        if let window = windows[id] {
            window.appearance = AppearanceSetting.current.nsAppearance
            bringToFront(window)   // 宽度不在这里改：设置窗口由预览里的岛决定宽度，两处都改会来回闪
            return
        }
        // 不用 fullSizeContentView：内容从标题栏下方开始，滚动时不会从红黄绿按钮下面穿过
        var style: NSWindow.StyleMask = [.titled, .closable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.titleVisibility = .hidden          // 页面里已有大标题
        // 不设 titlebarAppearsTransparent：macOS 27 上透明标题栏的窗口拖向另一块屏时会被拽回原屏
        window.backgroundColor = Self.panelColor
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.contentViewController = NSHostingController(rootView: content())
        window.setContentSize(size)
        window.appearance = AppearanceSetting.current.nsAppearance
        // 普通层级：切到别的程序时正常退到后面；窗口打开期间在程序坞显示图标，可从程序坞或 ⌘Tab 切回来
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        // 记住窗口位置：第一次居中，之后在上次拖到的地方打开
        if resizable { window.minSize = NSSize(width: 640, height: 480) }
        // 记住窗口位置和高度：第一次按设计尺寸居中，之后沿用上次的位置和高度。
        // 可调大小的窗口宽度用这次算好的设计宽度（设置窗口 = 预览里岛的宽度），不用上次的：否则打开后预览再改宽度，会跳一下
        let restored = window.setFrameUsingName("islet.\(id)")
        window.setFrameAutosaveName("islet.\(id)")   // 这一步也会套用上次保存的尺寸，所以宽度放在它后面改
        if !restored { window.center() }
        if restored, resizable {
            var frame = window.frame
            frame.size.width = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).width
            window.setFrame(frame, display: false)
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            onClose?()
            DispatchQueue.main.async { self?.updateDockIcon() }
        }
        windows[id] = window
        bringToFront(window)
    }

    /// 有窗口开着时在程序坞显示图标（菜单栏程序平时没有，窗口落到后面就找不回来）；全部关闭后隐藏。
    private func updateDockIcon() {
        let anyOpen = windows.values.contains { $0.isVisible }
        let policy: NSApplication.ActivationPolicy = anyOpen ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    private func bringToFront(_ window: NSWindow) {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()  // 即使系统没批准激活，也先显示在最前
    }

    /// 与 Palette.panel 一致的窗口底色（随明暗切换）。
    private static let panelColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1)
            : NSColor(srgbRed: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF5 / 255, alpha: 1)
    }

    /// 外观设置变化后更新已打开的窗口。
    func applyAppearance() {
        for window in windows.values { window.appearance = AppearanceSetting.current.nsAppearance }
    }

    func close(_ id: String) { windows[id]?.close() }

    func isOpen(_ id: String) -> Bool { windows[id]?.isVisible == true }
}

// MARK: - 设置

/// 设置窗口的分页（左侧导航）。
enum SettingsPage: String, CaseIterable, Identifiable {
    case menuBar, extensions, general, about
    static let bottom: [SettingsPage] = [.about]
    var id: String { rawValue }
    var title: String {
        switch self {
        case .menuBar: return "灵动岛"
        case .extensions: return "扩展功能"
        case .general: return "通用"
        case .about: return "关于"
        }
    }
    var symbol: String {
        switch self {
        case .menuBar: return "capsule.fill"
        case .extensions: return "puzzlepiece.extension.fill"
        case .general: return "gearshape.fill"
        case .about: return "info.circle.fill"
        }
    }
    var tint: Color {
        switch self {
        case .menuBar: return Color(hex: 0x5E5CE6)
        case .extensions: return Color(hex: 0xBF5AF2)
        case .general: return Color(hex: 0x8E8E93)
        case .about: return Color(hex: 0xFF9F0A)
        }
    }
}

final class SettingsModel: ObservableObject {
    @Published private(set) var revision = 0      // 设置变化时递增，触发界面刷新
    @Published var page: SettingsPage = .menuBar
    @Published var controlTemperatures: (average: Double, peak: Double)?
    @Published var diagnosticsNote: String?

    var onChange: (SpeedSetting) -> Void = { _ in }
    var onAppearance: () -> Void = {}
    var onMetricOrder: () -> Void = {}
    var onFullScreenFloatingIsland: (Bool) -> Void = { _ in }
    var onFreeFloatingIsland: (Bool) -> Void = { _ in }
    var onFloatingIsland: (Bool) -> Void = { _ in }
    var onKeepLeftmost: () -> Void = {}
    var onUnits: () -> Void = {}
    @Published var alertRules = AlertCenter.rules
    @Published var stars: Int?
    @Published var update: UpdateChecker.State = .idle
    @Published var showDonate = false
    /// 灵动岛页里展开了设置的项（music、bluetooth、cpu、network…）。
    @Published var expanded: Set<String> = []
    /// 打开设置时要滚到的项（滚到后清空）
    @Published var scrollTarget: String?
    var onResetAll: () -> Void = {}
    /// 灵动岛各项的顺序；拖动时实时变化，松手后才保存并应用到菜单栏。
    @Published var islandOrder = IslandOrder.items
    /// 正在拖动的项、手指相对按下时的位移、当前位置（列表坐标）、是否还在列表范围内。
    @Published var dragging: String?
    @Published var dragOffset: CGFloat = 0
    @Published var dragY: CGFloat = 0
    @Published var dragInside = true
    /// 各行（以及“未显示”分隔标题、整个列表）在列表坐标里的位置，用来算落点。
    var rowFrames: [String: CGRect] = [:]
    static let hiddenMarker = "__hidden__"
    static let listMarker = "__list__"

    /// 某项当前是否显示在岛上。
    func isVisible(_ id: String) -> Bool {
        switch id {
        case "music": return SpectrumController.isEnabled
        case "bluetooth": return SoundController.showsBluetoothItem
        case "network": return SpeedSetting.direction.selection != 2
        default: return Self.metricSetting(id).map { $0.selection == 0 } ?? false
        }
    }

    /// 显示 / 隐藏某项。
    func setVisible(_ id: String, _ on: Bool) {
        switch id {
        case "music": SpectrumController.shared.setEnabled(on)
        case "bluetooth":
            UserDefaults.standard.set(on, forKey: "bluetoothItem")
            SoundController.shared.startBluetoothItem()
        case "network":
            select(.direction, on ? (UserDefaults.standard.object(forKey: "networkLastMode") as? Int ?? 0) : 2)
        default:
            if let setting = Self.metricSetting(id) { select(setting, on ? 0 : 1) }
            // 帧率需要屏幕录制权限：打开时向系统申请（已授权则不弹）
            if id == "fps", on, !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        }
        refresh()
    }

    /// 只恢复“显示在岛上”这一块：各项显示 / 隐藏、顺序（重新按机型套用默认），其他设置不动。
    func resetIslandItems() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "islandOrder")
        defaults.removeObject(forKey: "metricOrder")
        for setting in Metric.allCases.map(\.setting) where setting != .direction { defaults.removeObject(forKey: setting.key) }
        islandOrder = IslandOrder.items
        // 音乐、蓝牙、网速默认都显示；网速沿用原来的显示方式
        for id in ["music", "bluetooth", "network"] where !isVisible(id) { setVisible(id, true) }
        onChange(.cpuItem)
        onMetricOrder()
        refresh()
    }

    static func metricSetting(_ id: String) -> SpeedSetting? {
        Metric.allCases.first { "\($0)" == id }?.setting
    }
    /// 显示组 + 分隔 + 未显示组，连成一条序列。
    var sequence: [String] {
        islandOrder.filter { isVisible($0) } + [Self.hiddenMarker] + islandOrder.filter { !isVisible($0) }
    }

    /// 松手时会落到的位置：除被拖动项外，中线在手指上方的行数。
    var dropIndex: Int? {
        guard let dragging else { return nil }
        let others = sequence.filter { $0 != dragging }
        return others.filter { (rowFrames[$0]?.midY ?? .infinity) < dragY }.count
    }

    /// 松手：在列表范围内就按落点调整顺序和显示 / 隐藏；拖出列表外则取消，一切照旧。
    func endDrag() {
        defer {
            dragging = nil
            dragOffset = 0
        }
        guard let id = dragging, dragInside, let index = dropIndex else { return }
        var others = sequence.filter { $0 != id }
        others.insert(id, at: min(index, others.count))
        guard let marker = others.firstIndex(of: Self.hiddenMarker) else { return }
        let shown = Array(others[..<marker]), hidden = Array(others[(marker + 1)...])
        let order = shown + hidden
        let visible = shown.contains(id)
        if order != islandOrder {
            IslandOrder.save(order)
            islandOrder = IslandOrder.items
        }
        if visible != isVisible(id) { setVisible(id, visible) }
        onMetricOrder()
    }

    var onInstallFan: () -> Void = {}
    var onUninstallFan: () -> Void = {}
    var onCopyDiagnostics: () -> Void = {}

    func selection(_ setting: SpeedSetting) -> Int { setting.selection }

    /// 修改设置。允许把指标全部隐藏：胶囊消失后再次打开 islet 会弹出设置。
    func select(_ setting: SpeedSetting, _ index: Int) {
        setting.select(index)
        onChange(setting)
        revision += 1
    }

    var appearance: AppearanceSetting { AppearanceSetting.current }

    func setAppearance(_ value: AppearanceSetting) {
        AppearanceSetting.select(value)
        onAppearance()
        revision += 1
    }

    var launchAtLogin: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } else {
                try service.unregister()
            }
        } catch {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "无法更改登录时启动"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        revision += 1
    }

    func refresh() { revision += 1 }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var fanClient = FanHelperClient.shared
    @ObservedObject var smoothScroll = SmoothScrollController.shared
    @ObservedObject var displays = DisplayManager.shared
    /// 走查用：不包 ScrollView（离屏渲染画不出滚动视图的内容）。
    var flat = false

    var body: some View {
        Themed { p in
            HStack(spacing: 0) {
                sidebar(p)
                Rectangle().fill(p.separator).frame(width: 1)
                VStack(spacing: 0) {
                    // 不显示滚动条：接了鼠标时系统用常驻滚动条，占 17 点宽，而且刚打开时系统先报“悬浮”、过一会儿才改成常驻，
                    // 窗口宽度（跟着预览里的岛走）会因此跳一下。滚轮、触控板照常滚动
                    if flat { page(p) } else {
                        ScrollViewReader { proxy in
                            ScrollView { page(p) }.scrollIndicators(.never)
                                .onAppear { scroll(proxy) }
                                .onChange(of: model.scrollTarget) { _, _ in scroll(proxy) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(minWidth: 640, minHeight: 480)
            .background(p.panel)
        }
    }

    // MARK: 左侧导航

    private func sidebar(_ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPage.allCases.filter { !SettingsPage.bottom.contains($0) }) { page in sidebarItem(p, page) }
            // “关于”紧跟在功能页下面，用分隔线隔开；不推到底部，窗口拉高时不会孤零零挂在最下面
            Rectangle().fill(p.separator).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 6)
            ForEach(SettingsPage.bottom) { page in sidebarItem(p, page) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
        .frame(width: 190)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(p.inset.opacity(0.5))
    }

    private func sidebarItem(_ p: Palette, _ page: SettingsPage) -> some View {
        let selected = model.page == page
        return Button { model.page = page } label: {
            HStack(spacing: 10) {
                IconTile(symbol: page.symbol, tint: page.tint, size: 24)
                Text(page.title).font(selected ? Typo.bodyMedium : Typo.body).foregroundStyle(p.text)
                Spacer(minLength: 0)
                if page == .about {
                    Text("v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")).font(Typo.caption).foregroundStyle(p.text3)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? p.accentFill.opacity(0.2) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 分页内容

    private func page(_ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.page.title).font(.system(size: 20, weight: .semibold)).foregroundStyle(p.text)
            switch model.page {
            case .general: generalPage(p)
            case .menuBar: menuBarPage(p)
            case .extensions: extensionsPage(p)
            case .about: aboutPage(p)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(model.revision)
    }

    /// 通用：启动、外观、单位、提醒、数据与流量。
    @ViewBuilder private func generalPage(_ p: Palette) -> some View {
        section(p, "基本") {
            row(p, "登录时启动", nil, icon: "power", tint: Color(hex: 0x30D158)) {
                Toggle2(isOn: model.launchAtLogin, onChange: model.setLaunchAtLogin)
            }
            divider(p)
            row(p, "主题", "面板和窗口", icon: "circle.lefthalf.filled", tint: Color(hex: 0x5E5CE6)) {
                Segmented(options: AppearanceSetting.allCases.map { ($0, $0.label) },
                          selection: model.appearance, onSelect: model.setAppearance)
                    .frame(width: 200)
            }
        }
        section(p, "提醒") {
            row(p, "提醒规则", "指标持续过高时发通知，回落后才会再次提醒", icon: "bell.badge.fill", tint: Color(hex: 0xFF453A)) {
                PlainButton(title: "添加") {
                    model.alertRules.append(AlertRule(kind: .temperature, threshold: AlertRule.Kind.temperature.defaultThreshold, minutes: 1))
                    AlertCenter.rules = model.alertRules
                }
            }
            ForEach($model.alertRules) { $rule in
                divider(p)
                AlertRuleRow(rule: $rule, onChange: { AlertCenter.rules = model.alertRules }) {
                    model.alertRules.removeAll { $0.id == rule.id }
                    AlertCenter.rules = model.alertRules
                }
            }
        }
        section(p, "数据") {
            row(p, "刷新频率", "越快越耗电", icon: "arrow.clockwise", tint: Color(hex: 0x0A84FF)) {
                Segmented(options: [(0, "1 秒"), (1, "2 秒"), (2, "3 秒")],
                          selection: model.selection(.interval)) { model.select(.interval, $0) }
                    .frame(width: 170)
            }
            divider(p)
            row(p, "排行条数", nil, icon: "list.number", tint: Color(hex: 0x32ADE6)) {
                Segmented(options: [(0, "3"), (1, "5"), (2, "8")],
                          selection: model.selection(.count)) { model.select(.count, $0) }
                    .frame(width: 170)
            }
        }
        section(p, "重置") {
            row(p, "恢复默认设置", "重置 islet 的应用偏好", icon: "arrow.uturn.backward.circle.fill", tint: Color(hex: 0x8E8E93)) {
                PlainButton(title: "恢复默认…") {
                    guard confirmAlert("恢复 islet 的默认设置？",
                                       "islet 会重新启动。流量统计、macOS 的显示器配置和系统权限会保留。") else { return }
                    model.onResetAll()
                }
            }
        }
    }

    /// 灵动岛：位置、底色，以及岛上显示的内容（顺序与岛上一致，可展开各项设置）。
    @ViewBuilder private func menuBarPage(_ p: Palette) -> some View {
        VStack(spacing: 10) {
            MenuBarPreview(look: SpectrumLook.current, merged: true)
                .frame(height: 36)
            Text("预览（示例数据）").font(Typo.caption).foregroundStyle(p.text3)
        }
        .frame(maxWidth: .infinity)
        section(p, "胶囊") {
            row(p, "全局悬浮", "将胶囊居中放在刘海或菜单栏下方", icon: "rectangle.on.rectangle", tint: Color(hex: 0x0A84FF)) {
                Toggle2(isOn: AppDelegate.floatsIsland, onChange: model.onFloatingIsland)
            }
            divider(p)
            if AppDelegate.floatsIsland {
                row(p, "全屏时保持悬浮", "在支持的全屏视频和游戏上显示胶囊", icon: "arrow.up.left.and.arrow.down.right", tint: Color(hex: 0x0A84FF)) {
                    Toggle2(isOn: AppDelegate.fullScreenFloatingIsland, onChange: model.onFullScreenFloatingIsland)
                }
                divider(p)
                row(p, "自由拖动", "按住胶囊拖到想放的位置", icon: "hand.draw", tint: Color(hex: 0x0A84FF)) {
                    Toggle2(isOn: AppDelegate.freeFloatingIsland, onChange: model.onFreeFloatingIsland)
                }
            } else {
                row(p, "始终在菜单栏最左侧", "关闭后可按住 ⌘ 拖到任意位置", icon: "pin.fill", tint: Color(hex: 0x30D158)) {
                    Toggle2(isOn: AppDelegate.keepsLeftmost) { on in
                        UserDefaults.standard.set(on, forKey: "keepLeftmost")
                        if on { model.onKeepLeftmost() }
                        model.refresh()
                    }
                }
            }
            divider(p)
            SpectrumLookEditor(look: SpectrumLook.current, part: .backdrop) { look in
                SpectrumController.shared.setLook(look)
                model.refresh()
            }
            .padding(.vertical, 4)
        }
        itemList(p)
    }

    /// 显示 / 未显示两组连成一个列表：按住任意一行拖动，蓝线是松手后的位置，拖出列表外松手则取消。
    private func itemList(_ p: Palette) -> some View {
        let shown = model.islandOrder.filter { model.isVisible($0) }
        let hidden = model.islandOrder.filter { !model.isVisible($0) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("显示在岛上").font(Typo.bodyMedium).foregroundStyle(p.text2)
                Spacer()
                Text("按住拖动排序，拖到“未显示”即隐藏").font(Typo.caption).foregroundStyle(p.text3)
            }
            Card(padding: 12) { itemRows(p, shown, empty: "把要显示的项拖到这里") }
            if !Metric.allCases.contains(where: \.isShown) {
                // 音乐、蓝牙只在播放 / 连接时出现，没有常驻指标时胶囊可能整个消失
                Text("没有常驻指标时胶囊可能会消失，再次打开 islet 即可回到设置")
                    .font(Typo.caption).foregroundStyle(p.text3)
            }
            Text("未显示").font(Typo.bodyMedium).foregroundStyle(p.text2).padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(frameReader(SettingsModel.hiddenMarker))
            Card(padding: 12) { itemRows(p, hidden, empty: "把不需要的项拖到这里") }
            // 列表的“恢复默认”放在整块末尾：只管显示哪些项和顺序
            LinkButton(title: "恢复默认显示和顺序", muted: true) {
                guard confirmAlert("恢复岛上项目的默认显示？",
                                   "显示哪些项目和它们的顺序会按本机重新设置，其他设置不变。") else { return }
                model.resetIslandItems()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, 2)
        }
        .background(frameReader(SettingsModel.listMarker))
        .coordinateSpace(name: "islandList")
        .onPreferenceChange(RowFramesKey.self) { model.rowFrames = $0 }
        .overlay(alignment: .topLeading) { dragOverlay(p) }
    }

    private func itemRows(_ p: Palette, _ ids: [String], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if ids.isEmpty {
                Text(empty).font(Typo.caption).foregroundStyle(p.text3).frame(maxWidth: .infinity, minHeight: 36)
            }
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                VStack(alignment: .leading, spacing: 0) {
                    if index > 0 { divider(p) }
                    itemRow(p, id)
                        .id("item-\(id)")
                        .background(frameReader(id))
                        .opacity(model.dragging == id ? 0.25 : 1)
                        .gesture(dragGesture(id))
                    if model.expanded.contains(id), model.dragging != id { itemDetail(p, id) }
                }
            }
        }
    }

    /// 滚到要定位的项：等这一帧布局完（展开的内容出现）再滚，项的标题行停在顶部附近。
    private func scroll(_ proxy: ScrollViewProxy) {
        guard let target = model.scrollTarget else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("item-\(target)", anchor: UnitPoint(x: 0.5, y: 0.08)) }
            model.scrollTarget = nil
        }
    }

    private func frameReader(_ id: String) -> some View {
        GeometryReader { geo in Color.clear.preference(key: RowFramesKey.self, value: [id: geo.frame(in: .named("islandList"))]) }
    }

    private func dragGesture(_ id: String) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("islandList"))
            .onChanged { value in
                if model.dragging == nil { model.dragging = id }
                model.dragOffset = value.translation.height
                model.dragY = value.location.y
                let list = model.rowFrames[SettingsModel.listMarker] ?? .infinite
                model.dragInside = list.insetBy(dx: -24, dy: -24).contains(value.location)
            }
            .onEnded { _ in withAnimation(.easeOut(duration: 0.15)) { model.endDrag() } }
    }

    /// 拖动时：跟着手指的那一行 + 落点处的蓝线；拖出列表外时蓝线消失、行变淡，表示松手会取消。
    @ViewBuilder private func dragOverlay(_ p: Palette) -> some View {
        if let id = model.dragging, let frame = model.rowFrames[id] {
            let others = model.sequence.filter { $0 != id }
            let index = model.dropIndex ?? 0
            let lineY: CGFloat? = {
                guard model.dragInside else { return nil }
                if index < others.count, let next = model.rowFrames[others[index]] {
                    return others[index] == SettingsModel.hiddenMarker ? next.minY - 2 : next.minY - 1
                }
                return others.last.flatMap { model.rowFrames[$0]?.maxY }.map { $0 + 1 }
            }()
            ZStack(alignment: .topLeading) {
                // 浮起的行半透明，蓝线画在它上面，任何时候都看得见落点
                itemRow(p, id)
                    .frame(width: frame.width, height: frame.height)
                    .background(RoundedRectangle(cornerRadius: 8).fill(p.card).shadow(color: .black.opacity(0.25), radius: 10, y: 4))
                    .opacity(model.dragInside ? 0.75 : 0.4)
                    .offset(x: frame.minX, y: frame.minY + model.dragOffset)
                if let lineY {
                    Capsule().fill(p.accentFill).frame(width: frame.width, height: 3)
                        .shadow(color: p.accentFill.opacity(0.6), radius: 3)
                        .offset(x: frame.minX, y: lineY - 1.5)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func itemInfo(_ id: String) -> (title: String, icon: String, tint: Color, hasDetail: Bool) {
        switch id {
        case "music": return ("音乐", "waveform", Color(hex: 0xFF375F), true)
        case "bluetooth": return ("蓝牙电量", "headphones", Color(hex: 0x0A84FF), true)
        case "network": return ("网速", "arrow.up.arrow.down", Color(hex: 0x0A84FF), true)
        default:
            let setting = SettingsModel.metricSetting(id)
            let icon = setting.map(Self.metricIcon) ?? ("circle", Color.gray)
            return (setting?.title ?? id, icon.0, icon.1, ["fan", "fps", "temperature"].contains(id))
        }
    }

    /// 一行：展开箭头、图标、名称；右侧是拖动把手。整行都能拖。
    private func itemRow(_ p: Palette, _ id: String) -> some View {
        let info = itemInfo(id)
        let open = model.expanded.contains(id)
        return HStack(spacing: 10) {
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(p.text3)
                .rotationEffect(.degrees(open ? 90 : 0))
                .opacity(info.hasDetail ? 1 : 0)
                .frame(width: 12)
            IconTile(symbol: info.icon, tint: info.tint, size: 30)
            Text(info.title).font(Typo.body).foregroundStyle(p.text)
            Spacer(minLength: 8)
            Image(systemName: "line.3.horizontal").font(.system(size: 13, weight: .medium)).foregroundStyle(p.text3)
                .frame(width: 28, height: 30)
                .help("拖动调整顺序或显示 / 隐藏")
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            guard info.hasDetail else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                if open { model.expanded.remove(id) } else { model.expanded.insert(id) }
            }
        }
    }

    @ViewBuilder private func itemDetail(_ p: Palette, _ id: String) -> some View {
        switch id {
        case "music": musicDetail(p)
        case "bluetooth": bluetoothDetail(p)
        case "network": networkDetail(p)
        case "fan": fanDetail(p)
        case "fps": fpsDetail(p)
        case "temperature": temperatureDetail(p)
        default: EmptyView()
        }
    }

    // MARK: 展开后的设置

    /// 展开区：缩进到图标下方，浅色底。
    private func detail<Content: View>(_ p: Palette, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(p.text.opacity(0.04)))
            .padding(.leading, 46).padding(.bottom, 8)
    }

    private func detailRow<Control: View>(_ p: Palette, _ title: String, _ subtitle: String? = nil, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typo.body).foregroundStyle(p.text)
                if let subtitle { Text(subtitle).font(Typo.caption).foregroundStyle(p.text3) }
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.vertical, 6)
    }

    private func musicDetail(_ p: Palette) -> some View {
        detail(p) {
            detailRow(p, "其他程序的声音", "游戏、剪辑软件等也显示") {
                Toggle2(isOn: SpectrumController.showsOtherSounds) { on in
                    UserDefaults.standard.set(on, forKey: "spectrumOtherSounds")
                    SpectrumController.shared.otherSoundsChanged()
                    model.refresh()
                }
            }
            detailRow(p, "停止播放后收起") {
                Segmented(options: SpectrumController.hideDelayChoices,
                          selection: UserDefaults.standard.object(forKey: "spectrumHideDelay") as? Int ?? 10) { value in
                    UserDefaults.standard.set(value, forKey: "spectrumHideDelay")
                    SpectrumController.shared.hideDelayChanged()
                    model.refresh()
                }
                .frame(width: 220)
            }
            SpectrumLookEditor(look: SpectrumLook.current, part: .music) { look in
                SpectrumController.shared.setLook(look)
                model.refresh()
            }
            .padding(.vertical, 6)
            detailRow(p, "灵敏度", "安静的歌调高") {
                Segmented(options: SpectrumAnalyzer.sensitivityChoices, selection: SpectrumAnalyzer.sensitivity) { value in
                    SpectrumAnalyzer.sensitivity = value
                    model.refresh()
                }
                .frame(width: 190)
            }
            detailRow(p, "系统录音权限", "只读取播放的声音，不录麦克风") {
                PlainButton(title: "打开权限设置…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private func networkDetail(_ p: Palette) -> some View {
        detail(p) {
            detailRow(p, "显示方式", "自动：只显示较快的一方") {
                Segmented(options: [(0, "自动"), (1, "上传和下载")], selection: min(model.selection(.direction), 1)) { value in
                    UserDefaults.standard.set(value, forKey: "networkLastMode")
                    model.select(.direction, value)
                }
                .frame(width: 180)
            }
            detailRow(p, "单位") {
                Segmented(options: [(false, "MB/s"), (true, "Mb/s")], selection: Units.bits) { value in
                    UserDefaults.standard.set(value, forKey: "unitBits")
                    model.onUnits()
                    model.refresh()
                }
                .frame(width: 140)
            }
            detailRow(p, "流量统计每月起始日", "对齐运营商账单") {
                Menu("\(TrafficLedger.monthStart) 日") {
                    ForEach(1...28, id: \.self) { day in
                        Button("\(day) 日") {
                            UserDefaults.standard.set(day, forKey: "trafficMonthStart")
                            model.refresh()
                        }
                    }
                }
                .frame(width: 90)
            }
            detailRow(p, "清零流量统计", "今日和本月重新计") {
                PlainButton(title: "清零") {
                    guard confirmAlert("清零流量统计？", "今日和本月的上传、下载记录会归零。") else { return }
                    TrafficLedger.shared.reset()
                    model.refresh()
                }
            }
        }
    }

    /// 帧率：测量方式说明和屏幕录制权限。
    private func fpsDetail(_ p: Palette) -> some View {
        let authorized = CGPreflightScreenCaptureAccess()
        return detail(p) {
            detailRow(p, "测量方式", "统计前台窗口所在屏幕每秒画面变化的次数（islet 自己不算）；画面静止时数字会变低，最高不超过屏幕刷新率") { EmptyView() }
            detailRow(p, "屏幕录制权限", authorized ? "已授权。只数画面变化，不保存、不上传画面" : "未授权：在系统设置里打开 islet 后重新启动 islet") {
                PlainButton(title: authorized ? "已授权" : "打开权限设置…") {
                    if !authorized { CGRequestScreenCaptureAccess() }
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    /// 温度：单位（影响所有温度显示，所以放在“温度”这一项，不藏在风扇里）。
    private func temperatureDetail(_ p: Palette) -> some View {
        detail(p) {
            detailRow(p, "温度单位", "岛上、面板和提醒里的温度") {
                Segmented(options: [(false, "℃"), (true, "℉")], selection: Units.fahrenheit) { value in
                    UserDefaults.standard.set(value, forKey: "unitFahrenheit")
                    model.onUnits()
                    model.refresh()
                }
                .frame(width: 120)
            }
        }
    }

    private func fanDetail(_ p: Palette) -> some View {
        detail(p) {
            row(p, "调速依据温度", basisSubtitle, icon: "thermometer.medium", tint: Color(hex: 0xFF9F0A)) {
                Segmented(options: TemperatureBasis.allCases.reversed().map { ($0, $0.label) },
                          selection: fanClient.config.basis) { basis in
                    fanClient.update { $0.basis = basis }
                }
                .frame(width: 170)
            }
            divider(p)
            row(p, "控制组件", componentSubtitle, icon: "wrench.and.screwdriver.fill", tint: Color(hex: 0x8E8E93)) {
                if fanClient.isInstalled {
                    HStack(spacing: 6) {
                        if !fanClient.isHelperCurrent {
                            PlainButton(title: "更新", prominent: true, action: model.onInstallFan)
                        }
                        PlainButton(title: "卸载", action: model.onUninstallFan)
                    }
                } else {
                    PlainButton(title: "安装", prominent: true, action: model.onInstallFan)
                }
            }
            divider(p)
            row(p, "退出时交还系统", "退出、崩溃或睡眠时自动交还", icon: "arrow.uturn.backward", tint: Color(hex: 0x30D158)) {
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill").font(.system(size: 10))
                    Text("始终开启").font(Typo.caption)
                }
                .foregroundStyle(p.text3)
            }
        
            Text("通过未公开的 SMC 接口调速，系统升级后可能失效。转速有安全下限、绝不停转，但仍请自行承担风险；异常时切回“自动”或卸载组件。")
                .font(Typo.caption).foregroundStyle(p.text3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 6)
        }
    }

    private func bluetoothDetail(_ p: Palette) -> some View {
        let sound = SoundController.shared.panel
        return detail(p) {
            detailRow(p, "低电量提醒", "电量低于下面的值时通知，标题带设备类型") {
                toggle("alertLowBattery", default: true) { _ in AlertCenter.shared.prepare() }
            }
            if AlertCenter.lowBatteryEnabled {
                detailRow(p, "提醒电量") {
                    Segmented(options: AlertCenter.lowBatteryChoices, selection: AlertCenter.lowBatteryThreshold) { value in
                        UserDefaults.standard.set(value, forKey: "alertLowBatteryThreshold")
                        model.refresh()
                    }
                    .frame(width: 200)
                }
                detailRow(p, "提示音") { toggle("alertSound", default: true) }
                detailRow(p, "测试", "用已连接的设备发一条示例通知") {
                    PlainButton(title: "发送测试通知") {
                        let device = sound.allDevices.first { $0.connected && SoundController.batteryLevel($0.battery) != nil }
                        AlertCenter.shared.sendTest(device: device.map { ($0.name, $0.symbol, SoundController.batteryLevel($0.battery) ?? 20) })
                    }
                }
            }
            Text("显示的设备（取消勾选即隐藏）").font(Typo.caption).foregroundStyle(p.text3).padding(.top, 6)
            if sound.allDevices.isEmpty {
                Text("正在读取设备…").font(Typo.caption).foregroundStyle(p.text3).padding(.vertical, 6)
            }
            ForEach(sound.allDevices) { device in
                Button {
                    sound.setHidden(!sound.hiddenDevices.contains(device.id), device: device.id)
                    model.refresh()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: sound.hiddenDevices.contains(device.id) ? "square" : "checkmark.square.fill")
                            .font(.system(size: 15)).foregroundStyle(sound.hiddenDevices.contains(device.id) ? p.text3 : p.accentFill)
                        Image(systemName: device.symbol).font(.system(size: 13)).foregroundStyle(p.text2).frame(width: 20)
                        Text(device.name).font(Typo.body).foregroundStyle(p.text)
                        Spacer()
                        if device.connected { Text("已连接").font(Typo.caption).foregroundStyle(p.text3) }
                    }
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear { if !flat { SoundController.shared.loadDevices() } }
    }

    /// 开关行的通用开关：读写一个布尔设置。
    private func toggle(_ key: String, default value: Bool, onChange: @escaping (Bool) -> Void = { _ in }) -> some View {
        Toggle2(isOn: UserDefaults.standard.object(forKey: key) as? Bool ?? value) { on in
            UserDefaults.standard.set(on, forKey: key)
            onChange(on)
            model.refresh()
        }
    }

    private func confirmAlert(_ title: String, _ message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func setting(for metric: Metric) -> SpeedSetting? {
        switch metric {
        case .cpu: return .cpuItem
        case .gpu: return .gpuItem
        case .memory: return .memoryItem
        case .disk: return .diskItem
        case .power: return .powerItem
        case .temperature: return .temperatureItem
        case .fan: return .fanItem
        case .fps: return .fpsItem
        case .network: return nil
        }
    }

    private static func metricIcon(_ setting: SpeedSetting) -> (String, Color) {
        switch setting {
        case .cpuItem: return ("cpu", Color(hex: 0x0A84FF))
        case .gpuItem: return ("square.stack.3d.up.fill", Color(hex: 0x5E5CE6))
        case .memoryItem: return ("memorychip", Color(hex: 0x30D158))
        case .diskItem: return ("internaldrive.fill", Color(hex: 0x8E8E93))
        case .powerItem: return ("bolt.fill", Color(hex: 0xFFB800))
        case .temperatureItem: return ("thermometer.medium", Color(hex: 0xFF9F0A))
        case .fanItem: return ("fanblades.fill", Color(hex: 0x30B0C7))
        case .fpsItem: return ("gauge.with.needle.fill", Color(hex: 0xFF375F))
        default: return ("circle.fill", Color(hex: 0x8E8E93))
        }
    }

    @ViewBuilder private func extensionsPage(_ p: Palette) -> some View {
        section(p, "鼠标滚动") {
            row(p, "平滑滚动", smoothScroll.state.description, icon: "computermouse.fill", tint: Color(hex: 0x0A84FF)) {
                Toggle2(isOn: smoothScroll.enabled, onChange: smoothScroll.setEnabled)
            }
            if smoothScroll.state == .permissionRequired || smoothScroll.state == .unavailable {
                divider(p)
                row(p, "辅助功能权限", "用来接管鼠标滚轮，只改变滚动的节奏", icon: "hand.raised.fill", tint: Color(hex: 0x8E8E93)) {
                    PlainButton(title: "打开权限设置…", action: smoothScroll.openPermissionSettings)
                }
            }
            if smoothScroll.enabled {
                divider(p)
                row(p, "滚动距离", "滚轮每转一格移动多远", icon: "arrow.up.and.down", tint: Color(hex: 0x30D158)) {
                    Segmented(options: SmoothScrollController.Distance.allCases.map { ($0, $0.label) },
                              selection: smoothScroll.options.distance, onSelect: smoothScroll.setDistance)
                        .frame(width: 150)
                }
                divider(p)
                row(p, "平滑程度", "越高越柔和，停下得越慢", icon: "waveform.path", tint: Color(hex: 0xFF9F0A)) {
                    Segmented(options: SmoothScrollController.Smoothness.allCases.map { ($0, $0.label) },
                              selection: smoothScroll.options.smoothness, onSelect: smoothScroll.setSmoothness)
                        .frame(width: 150)
                }
                divider(p)
                row(p, "反转滚动方向", "只影响鼠标滚轮，触控板不变", icon: "arrow.up.arrow.down", tint: Color(hex: 0x5E5CE6)) {
                    Toggle2(isOn: smoothScroll.options.reverse, onChange: smoothScroll.setReverse)
                }
            }
        }
        displaysSection(p)
    }

    // MARK: 显示器

    /// 每块屏一行，下面是“文字大小”选项。没有实用 HiDPI 档位的外接屏有个 HiDPI 开关：
    /// 打开 = 写一份显示配置并切到推荐大小，关掉 = 移除 islet 写的配置。别的工具写的配置不给开关。
    private func displaysSection(_ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            section(p, "显示器") {
                if displays.displays.isEmpty {
                    Text("没有检测到显示器").font(Typo.caption).foregroundStyle(p.text3).padding(.vertical, 10)
                }
                ForEach(Array(displays.displays.enumerated()), id: \.element.id) { index, display in
                    if index > 0 { divider(p) }
                    displayRow(p, display)
                }
                if let message = displays.message {
                    divider(p)
                    Text(message).font(Typo.caption).foregroundStyle(p.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                }
            }
            Text("切换显示模式后，15 秒内未确认将自动恢复。")
            .font(Typo.caption).foregroundStyle(p.text3).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
        }
        .onAppear { displays.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in displays.refresh() }
    }

    private enum HiDPISwitch { case none, off, on }

    private func hiDPISwitch(_ display: DisplayManager.Display) -> HiDPISwitch {
        guard display.canSwitch, let status = displays.overrides[display.id], status.external else { return .none }
        if status.owned { return .on }
        if !status.installed, !display.hasHiDPIChoices, !status.sizes.isEmpty { return .off }
        return .none
    }

    private func displayRow(_ p: Palette, _ display: DisplayManager.Display) -> some View {
        let current = display.current
        let hiDPI = hiDPISwitch(display)
        let options = displays.expanded.contains(display.id) ? display.allSizes : display.sizeOptions
        // 没开 HiDPI 且正用原生分辨率时不列大小（只剩一个“原生的一半”，没什么可选）
        let showSizes = display.canSwitch && options.count > 1 && !(hiDPI == .off && current.native && !current.hiDPI)
        let subtitle: String
        if !display.active {
            subtitle = "未启用"
        } else {
            let mode = "\(current.size) \(current.hiDPI ? "HiDPI" : "普通")"
            let details = [mode, current.rate].filter { !$0.isEmpty }.joined(separator: " · ")
            // 第二行：镜像时说明为什么不能调；没开 HiDPI 时说明开关的作用；用 HiDPI 时给出实际渲染尺寸（普通模式等于分辨率，不重复）
            let note = display.mirrored ? "镜像中，解除镜像后可以单独调整"
                : hiDPI == .off ? "开启 HiDPI 后文字更清晰，大小可调"
                : current.hiDPI ? renderNote(current, display) : nil
            subtitle = note.map { "\(details)\n\($0)" } ?? details
        }
        return VStack(alignment: .leading, spacing: 0) {
            row(p, display.isMain ? "\(display.name)（主屏）" : display.name, subtitle,
                icon: display.builtIn ? "laptopcomputer" : "display", tint: Color(hex: 0x0A84FF)) {
                if hiDPI != .none {
                    HStack(spacing: 8) {
                        Text("HiDPI 支持").font(Typo.body).foregroundStyle(p.text2)
                        Toggle2(isOn: hiDPI == .on) { setHiDPI($0, on: display) }
                    }
                    .disabled(displays.busy)
                } else if let note = hiDPINote(display) {
                    // 没有开关的屏幕也说明一下原因，免得让人以为功能缺了
                    Text(note).font(Typo.caption).foregroundStyle(p.text3)
                }
            }
            if showSizes { sizePicker(p, display, options) }
        }
    }

    /// 没有 HiDPI 开关时，右侧显示的说明。
    private func hiDPINote(_ display: DisplayManager.Display) -> String? {
        guard display.canSwitch else { return nil }
        if display.builtIn || display.hasHiDPIChoices { return "系统已支持 HiDPI" }
        if displays.overrides[display.id]?.installed == true { return "已有其他工具的显示配置" }
        return nil
    }

    /// HiDPI 的渲染说明：渲染尺寸比屏幕像素大时要再缩小显示，提醒会多占 GPU；正好等于屏幕像素时最省也最清晰。
    private func renderNote(_ mode: DisplayManager.Mode, _ display: DisplayManager.Display) -> String {
        guard let native = display.native, mode.pixelWidth > native.width + 8 else {
            return "按屏幕原生像素绘制，最清晰"
        }
        return "文字更清晰，显卡负担稍高（按 \(mode.renderingSize) 绘制）"
    }

    private func setHiDPI(_ on: Bool, on display: DisplayManager.Display) {
        if on {
            guard confirmAlert("为 \(display.name) 开启 HiDPI？",
                               "需要输入管理员密码，为这块屏写一份显示配置，补上系统没有的 HiDPI 档位（只写入或删除 islet 自己的配置）。开启后屏幕会断开再接上一次，然后切到推荐的大小。随时可以关掉。") else { return }
            displays.addHiDPI(display)
        } else {
            guard confirmAlert("关闭 \(display.name) 的 HiDPI？",
                               "需要输入管理员密码。关闭后这块屏会断开再接上一次，回到系统自带的分辨率。") else { return }
            displays.removeHiDPI(display)
        }
    }

    /// 一排档位卡片：原生在最左，往右文字越来越大。每张卡片依次是分辨率、文字说明、界面放大比例（次要）。
    /// 默认只列核心的几档，其余收在“更多分辨率”里。
    private func sizePicker(_ p: Palette, _ display: DisplayManager.Display, _ options: [DisplayManager.Mode]) -> some View {
        let expanded = displays.expanded.contains(display.id)
        let hidden = display.allSizes.count - display.sizeOptions.count
        return VStack(alignment: .trailing, spacing: 6) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                ForEach(options) { mode in
                    let selected = mode.group == display.current.group
                    let label = display.label(mode)
                    let highlight = label == "推荐" || label == "默认"
                    Button { displays.choose(mode, on: display) } label: {
                        VStack(spacing: 3) {
                            Text(mode.size).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(selected ? p.accentText : p.text)
                                .lineLimit(1).minimumScaleFactor(0.7)
                            Text(label).font(Typo.caption)
                                .foregroundStyle(selected || highlight ? p.accentText : p.text2)
                                .lineLimit(1).minimumScaleFactor(0.8)
                            Text(display.scale(mode))
                                .font(.system(size: 10)).monospacedDigit()
                                .foregroundStyle(p.text3.opacity(0.7))
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9).padding(.horizontal, 4)
                        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? p.accentFill.opacity(0.14) : p.inset))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? p.accentFill.opacity(0.6) : .clear, lineWidth: 1.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(mode.size)，\(label)，界面 \(display.scale(mode))")
                }
            }
            if hidden > 0 {
                Button(expanded ? "收起" : "更多分辨率（\(hidden)）") {
                    displays.toggleExpanded(display.id)
                }
                .buttonStyle(.plain).font(Typo.caption).foregroundStyle(p.accentText)
            }
        }
        .padding(.leading, 42)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .disabled(displays.busy)
    }

    private var updateTitle: String {
        switch model.update {
        case .available(let release): return "发现新版本 \(release.version)"
        case .latest: return "已是最新版本"
        default: return "软件更新"
        }
    }

    private var updateSubtitle: String {
        switch model.update {
        case .checking: return "正在查询 GitHub…"
        case .failed: return "检查失败，请检查网络后再试"
        case .available: return "当前是 \(UpdateChecker.currentVersion)，可以直接更新并重启"
        case .latest: return "当前是 \(UpdateChecker.currentVersion)"
        case .idle: return "从 GitHub 查询是否有新版本"
        }
    }

    @ViewBuilder private func aboutPage(_ p: Palette) -> some View {
        // 头部：图标、名称、版本、简介
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(AppInfo.name).font(.system(size: 22, weight: .bold)).foregroundStyle(p.text)
                    Text("v" + AppInfo.version).font(Typo.caption).foregroundStyle(p.text3)
                }
                Text(AppInfo.summary).font(Typo.body).foregroundStyle(p.text2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 4)
        section(p, "项目") {
            row(p, "\(AppInfo.author) / islet", "GitHub 开源项目", icon: "chevron.left.forwardslash.chevron.right", tint: Color(hex: 0x1C1C1E)) {
                HStack(spacing: 8) {
                    PlainButton(title: "主页") { NSWorkspace.shared.open(AppInfo.homepage) }
                    PlainButton(title: model.stars.map { "⭐ Star · \($0)" } ?? "⭐ Star") { NSWorkspace.shared.open(AppInfo.homepage) }
                    PlainButton(title: model.showDonate ? "☕️ 收起" : "☕️ 打赏", prominent: model.showDonate) {
                        withAnimation(.easeInOut(duration: 0.2)) { model.showDonate.toggle() }
                    }
                }
                .fixedSize()
            }
            // 打赏：点了才展开
            if model.showDonate {
                divider(p)
                VStack(spacing: 8) {
                    Text("如果 islet 对你有帮助，可以请作者喝杯咖啡").font(Typo.caption).foregroundStyle(p.text3)
                    HStack(spacing: 28) {
                        donateCode(p, "alipay", "支付宝", Color(hex: 0x1677FF))
                        donateCode(p, "wechat", "微信", Color(hex: 0x07C160))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
        }
        .onAppear { if !flat { AppInfo.fetchStars { model.stars = $0 } } }
        section(p, "更新") {
            row(p, updateTitle, updateSubtitle, icon: "arrow.triangle.2.circlepath", tint: Color(hex: 0x0A84FF)) {
                if case .available(let release) = model.update {
                    PlainButton(title: "更新…", prominent: true) { Updater.shared.prompt(release) }
                } else {
                    PlainButton(title: model.update == .checking ? "检查中…" : "检查更新") {
                        UpdateChecker.check { state in
                            model.update = state
                            if case .available(let release) = state { Updater.shared.prompt(release) }
                        }
                    }
                    .disabled(model.update == .checking)
                }
            }
            divider(p)
            row(p, "自动检查更新", "每天一次，有新版本时弹窗", icon: "bell.badge", tint: Color(hex: 0xFF9F0A)) {
                toggle("autoCheckUpdates", default: true)
            }
        }
        section(p, "诊断") {
            row(p, Diagnostics.summary(), "反馈时自动复制报告，粘贴即可", icon: "stethoscope", tint: Color(hex: 0xFF453A)) {
                HStack(spacing: 8) {
                    PlainButton(title: model.diagnosticsNote ?? "复制报告", systemImage: "doc.on.doc",
                                action: model.onCopyDiagnostics)
                    PlainButton(title: "反馈问题", systemImage: "exclamationmark.bubble") {
                        model.onCopyDiagnostics()
                        NSWorkspace.shared.open(AppInfo.issuesURL)
                    }
                }
                .fixedSize()
            }
        }
    }

    /// 打赏二维码（随程序打包在 Resources 里）：白底圆角卡片，中间是支付方式的图标，下面一行带品牌色圆点的名字。
    @ViewBuilder private func donateCode(_ p: Palette, _ name: String, _ title: String, _ tint: Color) -> some View {
        if let image = Bundle.main.image(forResource: name) {
            VStack(spacing: 8) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 148, height: 148)
                    .padding(10)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(p.separator, lineWidth: 1))
                HStack(spacing: 6) {
                    Circle().fill(tint).frame(width: 7, height: 7)
                    Text(title).font(Typo.caption).foregroundStyle(p.text2)
                }
            }
        }
    }

    private var basisSubtitle: String {
        let reading = model.controlTemperatures
        switch fanClient.config.basis {
        case .peak:
            return "CPU/GPU 最热点" + (reading.map { " · \(Int($0.peak.rounded()))℃" } ?? "")
        case .average:
            return "CPU/GPU 均温" + (reading.map { " · \(Int($0.average.rounded()))℃" } ?? "")
        }
    }

    private var componentSubtitle: String {
        if !fanClient.isInstalled { return "未安装，调速需要" }
        if !fanClient.isHelperCurrent { return "版本不一致，需要更新" }
        return "已安装，正常"
    }

    private func section<Content: View>(_ p: Palette, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Typo.bodyMedium).foregroundStyle(p.text2)
            Card(padding: 12) {
                VStack(alignment: .leading, spacing: 0) { content() }
            }
        }
    }

    private func row<Control: View>(_ p: Palette, _ title: String, _ subtitle: String?, icon: String? = nil, tint: Color = Color(hex: 0x0A84FF),
                                    @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if let icon { IconTile(symbol: icon, tint: tint, size: 30) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typo.body).foregroundStyle(p.text)
                if let subtitle {
                    Text(subtitle).font(Typo.caption).foregroundStyle(p.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.vertical, 6)
    }

    private func divider(_ p: Palette) -> some View {
        Rectangle().fill(p.separator).frame(height: 1)
    }
}

// MARK: - 温度曲线

final class CurveEditorModel: ObservableObject {
    @Published var points: [CurvePoint] = []
    @Published var selected: Int?
    @Published var currentCelsius: Double?
    let minimum: Double
    let maximum: Double

    var onActivate: () -> Void = {}

    init(minimum: Double, maximum: Double) {
        self.minimum = minimum
        self.maximum = maximum
        points = FanHelperClient.shared.config.curve
    }

    /// 保存到配置；若当前就是曲线策略，立即生效。
    func commit(preset: CurvePreset? = nil) {
        let points = self.points
        FanHelperClient.shared.update { config in
            config.curve = points
            config.preset = preset
        }
    }

    func apply(_ preset: CurvePreset) {
        points = preset.points(minimum: minimum, maximum: maximum)
        selected = nil
        commit(preset: preset)
    }

    func addPointAtCurrent() {
        let celsius = (currentCelsius ?? 70).rounded()
        guard !points.contains(where: { abs($0.celsius - celsius) < 2 }) else { return }
        let rpm = FanCurve.rpm(points, at: celsius) ?? minimum
        points.append(CurvePoint(celsius: celsius, rpm: rpm.rounded()))
        points.sort { $0.celsius < $1.celsius }
        selected = points.firstIndex { $0.celsius == celsius }
        commit()
    }

    func deleteSelected() {
        guard let selected, points.count > 2 else { return }
        points.remove(at: selected)
        self.selected = nil
        commit()
    }
}

struct CurveEditorView: View {
    @ObservedObject var model: CurveEditorModel
    @ObservedObject var fanClient = FanHelperClient.shared
    private let domain: ClosedRange<Double> = 30...100

    var body: some View {
        Themed { p in
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("温度曲线").font(.system(size: 20, weight: .semibold)).foregroundStyle(p.text)
                    Text(fanClient.config.preset?.label ?? "自定义")
                        .font(Typo.captionMedium).foregroundStyle(p.accentText)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(p.accentFill.opacity(0.16)))
                    Spacer()
                    if let celsius = model.currentCelsius {
                        Text("\(fanClient.config.basis == .peak ? "最热" : "均温") \(Int(celsius.rounded()))℃")
                            .font(Typo.captionMedium).foregroundStyle(p.temperature(celsius))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(p.inset))
                    }
                }
                Text("拖动控制点改变温度到转速的映射；斜纹区域是安全下限，曲线拖不进去。")
                    .font(Typo.caption).foregroundStyle(p.text3)

                chart(p)
                    .frame(height: 300)
                    .background(RoundedRectangle(cornerRadius: 10).fill(p.card))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(p.cardStroke))

                HStack(spacing: 8) {
                    Text("预设").font(Typo.caption).foregroundStyle(p.text3)
                    ForEach(CurvePreset.allCases, id: \.self) { preset in
                        presetCard(p, preset)
                    }
                }

                HStack(spacing: 8) {
                    PlainButton(title: "在当前温度加点", systemImage: "plus.circle", action: model.addPointAtCurrent)
                    PlainButton(title: "删除选中点", systemImage: "minus.circle",
                                disabled: model.selected == nil || model.points.count <= 2, action: model.deleteSelected)
                    Spacer()
                    Text("\(model.points.count) 个控制点").font(Typo.caption).foregroundStyle(p.text3)
                    if fanClient.config.strategy != .curve {
                        PlainButton(title: "使用曲线调速", prominent: true, action: model.onActivate)
                    } else {
                        Text("曲线调速中").font(Typo.captionMedium).foregroundStyle(p.accentText)
                    }
                }
            }
            .padding(22)
            .frame(width: 640)
            .background(p.panel)
        }
    }

    private func presetCard(_ p: Palette, _ preset: CurvePreset) -> some View {
        let selected = fanClient.config.preset == preset
        return Button { model.apply(preset) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.label).font(Typo.bodyMedium).foregroundStyle(selected ? p.accentText : p.text)
                Text(preset.detail).font(Typo.caption).foregroundStyle(p.text3).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? p.accentFill.opacity(0.14) : p.card))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? p.accentFill.opacity(0.6) : p.cardStroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func chart(_ p: Palette) -> some View {
        GeometryReader { geo in
            let inset = EdgeInsets(top: 16, leading: 52, bottom: 28, trailing: 18)
            let plot = CGRect(x: inset.leading, y: inset.top,
                              width: geo.size.width - inset.leading - inset.trailing,
                              height: geo.size.height - inset.top - inset.bottom)
            let x = { (c: Double) -> CGFloat in plot.minX + CGFloat((c - domain.lowerBound) / (domain.upperBound - domain.lowerBound)) * plot.width }
            let y = { (r: Double) -> CGFloat in plot.maxY - CGFloat((r - model.minimum) / max(model.maximum - model.minimum, 1)) * plot.height }
            let celsiusAt = { (px: CGFloat) -> Double in domain.lowerBound + Double((px - plot.minX) / plot.width) * (domain.upperBound - domain.lowerBound) }
            let rpmAt = { (py: CGFloat) -> Double in model.minimum + Double((plot.maxY - py) / plot.height) * (model.maximum - model.minimum) }

            ZStack(alignment: .topLeading) {
                // 网格与坐标
                Path { path in
                    for step in 0...4 {
                        let yy = plot.minY + plot.height * CGFloat(step) / 4
                        path.move(to: CGPoint(x: plot.minX, y: yy)); path.addLine(to: CGPoint(x: plot.maxX, y: yy))
                    }
                    for c in stride(from: 30.0, through: 100, by: 10) {
                        path.move(to: CGPoint(x: x(c), y: plot.minY)); path.addLine(to: CGPoint(x: x(c), y: plot.maxY))
                    }
                }
                .stroke(p.separator, lineWidth: 1)
                ForEach(0...4, id: \.self) { step in
                    let rpm = model.maximum - (model.maximum - model.minimum) * Double(step) / 4
                    Text(String(Int(rpm))).font(Typo.caption).foregroundStyle(p.text3)
                        .frame(width: 44, alignment: .trailing)
                        .position(x: plot.minX - 28, y: plot.minY + plot.height * CGFloat(step) / 4)
                }
                ForEach(Array(stride(from: 30, through: 100, by: 10)), id: \.self) { c in
                    Text("\(c)°").font(Typo.caption).foregroundStyle(p.text3)
                        .position(x: x(Double(c)), y: plot.maxY + 14)
                }

                // 安全下限：斜纹带 + 虚线（中性色：表示“画不到的地方”，不是危险区）
                let floorPath = Path { path in
                    path.move(to: CGPoint(x: plot.minX, y: plot.maxY))
                    for c in stride(from: domain.lowerBound, through: domain.upperBound, by: 1) {
                        path.addLine(to: CGPoint(x: x(c), y: y(FanSafety.floor(celsius: c, minimum: model.minimum, maximum: model.maximum))))
                    }
                    path.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
                    path.closeSubpath()
                }
                Path { path in
                    var offset = -plot.height
                    while offset < plot.width {
                        path.move(to: CGPoint(x: plot.minX + offset, y: plot.maxY))
                        path.addLine(to: CGPoint(x: plot.minX + offset + plot.height, y: plot.minY))
                        offset += 7
                    }
                }
                .stroke(p.text3.opacity(0.35), lineWidth: 1)
                .clipShape(floorPath)
                Path { path in
                    for (index, c) in stride(from: domain.lowerBound, through: domain.upperBound, by: 1).enumerated() {
                        let point = CGPoint(x: x(c), y: y(FanSafety.floor(celsius: c, minimum: model.minimum, maximum: model.maximum)))
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }
                .stroke(p.text3, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

                // 当前温度
                if let celsius = model.currentCelsius, domain.contains(celsius) {
                    Path { path in
                        path.move(to: CGPoint(x: x(celsius), y: plot.minY)); path.addLine(to: CGPoint(x: x(celsius), y: plot.maxY))
                    }
                    .stroke(p.text2, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }

                // 曲线：区间外取端点值，所以两端延伸到坐标边界
                let curvePoints = [CGPoint(x: plot.minX, y: y(model.points.first?.rpm ?? model.minimum))]
                    + model.points.map { CGPoint(x: x(min(max($0.celsius, domain.lowerBound), domain.upperBound)), y: y($0.rpm)) }
                    + [CGPoint(x: plot.maxX, y: y(model.points.last?.rpm ?? model.maximum))]
                Path { path in
                    path.move(to: CGPoint(x: plot.minX, y: plot.maxY))
                    curvePoints.forEach { path.addLine(to: $0) }
                    path.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
                    path.closeSubpath()
                }
                .fill(p.accentFill.opacity(0.12))
                Path { path in
                    path.addLines(curvePoints)
                }
                .stroke(p.accentFill, style: StrokeStyle(lineWidth: 2, lineJoin: .round))

                // 控制点：可拖动；温度限制在相邻点之间，转速不低于该温度的安全下限
                ForEach(model.points.indices, id: \.self) { index in
                    let point = model.points[index]
                    let selected = model.selected == index
                    Circle()
                        .fill(p.card)
                        .overlay(Circle().stroke(p.accentFill, lineWidth: selected ? 3 : 2))
                        .frame(width: selected ? 14 : 11, height: selected ? 14 : 11)
                        .position(x: x(point.celsius), y: y(point.rpm))
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                model.selected = index
                                let lower = index > 0 ? model.points[index - 1].celsius + 1 : domain.lowerBound
                                let upper = index < model.points.count - 1 ? model.points[index + 1].celsius - 1 : domain.upperBound
                                let celsius = min(max(celsiusAt(drag.location.x).rounded(), lower), upper)
                                let floor = FanSafety.floor(celsius: celsius, minimum: model.minimum, maximum: model.maximum)
                                let rpm = min(max((rpmAt(drag.location.y) / 10).rounded() * 10, floor), model.maximum)
                                model.points[index] = CurvePoint(celsius: celsius, rpm: rpm)
                            }
                            .onEnded { _ in model.commit() })
                        .help("\(Int(point.celsius))℃ → \(Int(point.rpm)) 转")
                }
            }
        }
    }
}

// MARK: - 规则

struct RulesView: View {
    @ObservedObject var fanClient = FanHelperClient.shared
    let fan: FanData?
    /// 走查用：不包 ScrollView、不固定高度。
    var flat = false
    var onActivate: () -> Void = {}

    var body: some View {
        Themed { p in
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("规则").font(.system(size: 20, weight: .semibold)).foregroundStyle(p.text)
                    Text("规则命中时把风扇提到指定转速；多条同时命中取最高；都未命中时交给系统。")
                        .font(Typo.caption).foregroundStyle(p.text3)
                }
                if flat { ruleList(p) } else { ScrollView { ruleList(p) } }
                HStack(spacing: 8) {
                    PlainButton(title: "添加规则", systemImage: "plus", disabled: fanClient.config.rules.count >= 16) {
                        let rpm = fan.map { ($0.minimum + ($0.maximum - $0.minimum) * 0.6).rounded() } ?? 3000
                        fanClient.update { $0.rules.append(FanRule(threshold: 80, rpm: rpm)) }
                    }
                    Spacer()
                    if fanClient.config.strategy != .rules {
                        PlainButton(title: "使用规则调速", prominent: true, action: onActivate)
                    } else {
                        Text("规则调速中").font(Typo.captionMedium).foregroundStyle(p.accentText)
                    }
                }
            }
            .padding(22)
            .frame(width: 580, height: flat ? nil : 440)
            .background(p.panel)
        }
    }

    private func ruleList(_ p: Palette) -> some View {
        VStack(spacing: 8) {
            ForEach(fanClient.config.rules) { rule in
                ruleCard(p, rule)
            }
            if fanClient.config.rules.isEmpty {
                Text("还没有规则").font(Typo.body).foregroundStyle(p.text3).padding(.vertical, 20)
            }
        }
    }

    private func ruleCard(_ p: Palette, _ rule: FanRule) -> some View {
        let triggered = fanClient.status?.triggered.contains(rule.id) == true
        return Card(padding: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Toggle2(isOn: rule.enabled) { on in edit(rule) { $0.enabled = on } }
                    Text("当").font(Typo.body).foregroundStyle(p.text2)
                    Menu(rule.group) {
                        ForEach(Temperatures.groupNames, id: \.self) { name in
                            Button(name) { edit(rule) { $0.group = name } }
                        }
                    }
                    .frame(width: 96)
                    Menu(rule.peak ? "最高" : "平均") {
                        Button("平均") { edit(rule) { $0.peak = false } }
                        Button("最高") { edit(rule) { $0.peak = true } }
                    }
                    .frame(width: 56)
                    Text("≥").font(Typo.body).foregroundStyle(p.text2)
                    Stepper2(value: rule.threshold, step: 1, range: 20...120, unit: "℃", width: 30) { value in
                        edit(rule) { $0.threshold = value }
                    }
                    Text("→").font(Typo.body).foregroundStyle(p.text2)
                    Stepper2(value: rule.rpm, step: 100, range: (fan?.minimum ?? 0)...(fan?.maximum ?? 10000), unit: "转", width: 40) { value in
                        edit(rule) { $0.rpm = value }
                    }
                    Spacer(minLength: 0)
                    Button { fanClient.update { $0.rules.removeAll { $0.id == rule.id } } } label: {
                        Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(p.text3)
                    }
                    .buttonStyle(.plain)
                    .help("删除规则")
                }
                HStack(spacing: 6) {
                    if triggered {
                        Text("已触发").font(Typo.captionMedium).foregroundStyle(p.accentText)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(p.accentFill.opacity(0.16)))
                    }
                    Text("回落到 \(Int(rule.threshold - rule.hysteresis))℃ 以下才解除（迟滞 \(Int(rule.hysteresis))℃）")
                        .font(Typo.caption).foregroundStyle(p.text3)
                }
                .padding(.leading, 36)
            }
        }
        .opacity(rule.enabled ? 1 : 0.6)
    }

    private func edit(_ rule: FanRule, _ change: @escaping (inout FanRule) -> Void) {
        fanClient.update { config in
            guard let index = config.rules.firstIndex(where: { $0.id == rule.id }) else { return }
            change(&config.rules[index])
        }
    }
}

/// 指标行拖动排序：拖过某一行时实时换位，松手后保存。
/// 收集各行在列表里的位置。
struct RowFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// 一条提醒规则的编辑行：开关、指标、阈值、持续时间、删除。
struct AlertRuleRow: View {
    @Binding var rule: AlertRule
    let onChange: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Themed { p in
            HStack(spacing: 8) {
                Toggle2(isOn: rule.enabled) { on in rule.enabled = on; onChange() }
                Menu(rule.kind.title) {
                    ForEach(AlertRule.Kind.allCases, id: \.self) { kind in
                        Button(kind.title) {
                            rule.kind = kind
                            rule.threshold = kind.defaultThreshold
                            onChange()
                        }
                    }
                }
                .frame(width: 72)
                Text("≥").font(Typo.body).foregroundStyle(p.text2)
                Menu(thresholdText) {
                    ForEach(choices, id: \.self) { value in
                        Button(label(value)) { rule.threshold = value; onChange() }
                    }
                }
                .frame(width: 84)
                Text("持续").font(Typo.body).foregroundStyle(p.text2)
                Menu("\(rule.minutes) 分钟") {
                    ForEach([1, 3, 5, 10, 30], id: \.self) { minutes in
                        Button("\(minutes) 分钟") { rule.minutes = minutes; onChange() }
                    }
                }
                .frame(width: 84)
                Spacer()
                Button(action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(p.text3)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("删除这条规则")
            }
            .padding(.vertical, 4)
            .opacity(rule.enabled ? 1 : 0.55)
        }
    }

    /// 各指标可选的阈值。
    private var choices: [Double] {
        switch rule.kind {
        case .cpu, .gpu: return [50, 70, 80, 90, 95]
        case .temperature: return [70, 80, 85, 90, 95, 100]
        case .power: return [20, 30, 40, 60, 80, 100]
        case .memory: return [8, 12, 14, 16, 20, 24, 32]
        }
    }

    private func label(_ value: Double) -> String {
        rule.kind == .temperature ? Units.degrees(value) : "\(Int(value)) \(rule.kind.unit)"
    }

    private var thresholdText: String { label(rule.threshold) }
}

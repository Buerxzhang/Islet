import AppKit
import Network
import ServiceManagement
import SwiftUI

struct Traffic {
    let interface: String  // 参与统计的网卡，如 "en1"
    let upload: UInt64
    let download: UInt64
    var time = ProcessInfo.processInfo.systemUptime

    /// 物理网卡（en*：Wi-Fi、有线、雷雳网卡）。
    /// 不用“主接口”：开代理 / VPN 时主接口是 utun 等虚拟接口，有的代理不更新它的计数，
    /// 网速会一直显示 0；而所有流量最终都经过物理网卡，统计它们既准确又不会重复。
    static func physicalInterfaces() -> [(name: String, index: UInt32)] {
        guard let list = if_nameindex() else { return [] }
        defer { if_freenameindex(list) }
        var result: [(String, UInt32)] = []
        var entry = list
        while entry.pointee.if_index != 0, let cName = entry.pointee.if_name {
            let name = String(cString: cName)
            if name.hasPrefix("en") { result.append((name, entry.pointee.if_index)) }
            entry += 1
        }
        return result
    }

    /// 汇总处于 UP/RUNNING 的物理网卡的累计字节数；都不可用时返回 nil。
    static func read(_ interfaces: [(name: String, index: UInt32)]) -> Traffic? {
        var names: [String] = []
        var upload: UInt64 = 0
        var download: UInt64 = 0
        let running = UInt32(IFF_UP | IFF_RUNNING)
        for interface in interfaces {
            var query: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, Int32(interface.index), IFDATA_GENERAL]
            var data = ifmibdata()
            var size = MemoryLayout.size(ofValue: data)
            guard sysctl(&query, UInt32(query.count), &data, &size, nil, 0) == 0,
                  size == MemoryLayout.size(ofValue: data),
                  data.ifmd_flags & running == running else { continue }
            names.append(interface.name)
            upload += data.ifmd_data.ifi_obytes
            download += data.ifmd_data.ifi_ibytes
        }
        guard !names.isEmpty else { return nil }
        return Traffic(interface: names.joined(separator: "+"), upload: upload, download: download)
    }

    func rates(since previous: Traffic) -> (upload: Double, download: Double)? {
        let elapsed = time - previous.time
        guard interface == previous.interface, elapsed > 0, elapsed < 5,
              upload >= previous.upload, download >= previous.download else { return nil }
        return (Double(upload - previous.upload) / elapsed, Double(download - previous.download) / elapsed)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    /// 蓝牙设备图像（画在灵动岛末尾）。
    private var bluetoothImage: NSImage?
    /// 合并显示时的“指标灵动岛”：一个菜单栏项画下所有指标（在各指标项之后创建，排在它们左边）。
    private lazy var islandView: MetricsIslandView = {
        let view = MetricsIslandView(frame: .zero)
        view.autoresizingMask = [.width, .height]
        // 音乐部分展开 / 收起时，菜单栏项宽度逐帧跟随（内容靠右排，指标不动）
        view.onWidthChange = { [weak self] width in
            self?.layoutIsland(width: width)
        }
        return view
    }()
    private var islandItem: NSStatusItem?
    private var island: (item: NSStatusItem, view: MetricsIslandView) {
        if islandItem == nil { islandItem = makeIslandItem() }
        return (islandItem!, islandView)
    }

    private func makeIslandItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: 0)
        item.autosaveName = StatusItemNames.name("island")
        if let button = item.button {
            button.setAccessibilityLabel("系统指标")
            button.target = self
            button.action = #selector(islandClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            islandView.frame = button.bounds
            button.addSubview(islandView)
        }
        return item
    }

    // MARK: 悬浮位置

    private static let floatingKey = "floatingIsland"
    static var floatsIsland: Bool { UserDefaults.standard.bool(forKey: floatingKey) }
    private static let fullScreenFloatingKey = "fullScreenFloatingIsland"
    static var fullScreenFloatingIsland: Bool { UserDefaults.standard.bool(forKey: fullScreenFloatingKey) }
    private static var floatingWindowLevel: NSWindow.Level {
        // 部分全屏游戏把窗口放在菜单栏层（24）之上的 27 层；全屏悬浮开启时用 28 层盖过它们，
        // 但仍低于系统弹出菜单（101），不会挡住菜单。
        fullScreenFloatingIsland ? NSWindow.Level(rawValue: 28) : .floating
    }

    private static var floatingCollectionBehavior: NSWindow.CollectionBehavior {
        if fullScreenFloatingIsland {
            return [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .ignoresCycle]
        }
        return [.canJoinAllSpaces, .fullScreenNone, .ignoresCycle]
    }

    private static let floatingOriginKey = "floatingIslandOrigin"
    static var freeFloatingIsland: Bool { UserDefaults.standard.bool(forKey: "freeFloatingIsland") }
    private var floatingOrigin = UserDefaults.standard.string(forKey: AppDelegate.floatingOriginKey).map(NSPointFromString)
    private var floatingPanel: NSPanel?
    private var floatingScreen: NSNumber?
    private var islandAnchor: NSView? {
        if Self.floatsIsland { return floatingPanel?.contentView }
        return islandItem?.button
    }

    private func setFloatingIsland(_ enabled: Bool) {
        guard enabled != Self.floatsIsland else { return }
        popover.performClose(nil)
        closePanel()
        SoundController.shared.closeBluetoothPanel()
        SpectrumController.shared.closePanel()
        islandAnimation?.invalidate()
        islandAnimating = false
        islandView.alphaValue = 1
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        floatingScreen = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        UserDefaults.standard.set(enabled, forKey: Self.floatingKey)
        updateIsland()
        settingsModel.refresh()
    }

    private func setFullScreenFloatingIsland(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.fullScreenFloatingKey)
        floatingPanel?.level = Self.floatingWindowLevel
        floatingPanel?.collectionBehavior = Self.floatingCollectionBehavior
        settingsModel.refresh()
    }

    private func setFreeFloatingIsland(_ free: Bool) {
        popover.performClose(nil)
        closePanel()
        SoundController.shared.closeBluetoothPanel()
        SpectrumController.shared.closePanel()
        UserDefaults.standard.set(free, forKey: "freeFloatingIsland")
        updateIsland()
        settingsModel.refresh()
    }

    private func dragIsland(to point: NSPoint, finished: Bool) {
        if popover.isShown || pendingMetric != nil { popover.performClose(nil); closePanel() }
        SoundController.shared.closeBluetoothPanel()
        SpectrumController.shared.closePanel()
        floatingOrigin = point
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
            floatingScreen = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        }
        layoutIsland(width: islandView.preferredWidth)
        if finished, let frame = floatingPanel?.frame {
            let origin = NSPoint(x: frame.minX, y: frame.maxY)
            floatingOrigin = origin
            UserDefaults.standard.set(NSStringFromPoint(origin), forKey: Self.floatingOriginKey)
        }
    }

    @objc private func floatingScreenChanged() {
        if Self.floatsIsland { layoutIsland(width: islandView.preferredWidth) }
    }

    private func layoutIsland(width: CGFloat) {
        guard let item = islandItem, let button = item.button else { return }
        guard Self.floatsIsland else {
            if let floatingPanel {
                floatingPanel.orderOut(nil)
                self.floatingPanel = nil
                islandView.frame = button.bounds
                button.addSubview(islandView)
            }
            if item.isVisible != (width > 0) { item.isVisible = width > 0 }
            if !islandAnimating, width > 0, item.length != width { item.length = width }
            return
        }

        if floatingPanel == nil {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: true)
            panel.level = Self.floatingWindowLevel
            panel.collectionBehavior = Self.floatingCollectionBehavior
            panel.hidesOnDeactivate = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.title = "islet 全局悬浮"
            let anchor = FloatingIslandButton(frame: .zero)
            anchor.title = ""
            anchor.isBordered = false
            anchor.setAccessibilityLabel("系统指标")
            anchor.target = self
            anchor.action = #selector(islandClicked(_:))
            anchor.onDrag = { [weak self] point, finished in self?.dragIsland(to: point, finished: finished) }
            panel.contentView = anchor
            islandView.frame = anchor.bounds
            anchor.addSubview(islandView)
            floatingPanel = panel
            item.isVisible = false
        }
        guard let panel = floatingPanel else { return }
        (panel.contentView as? FloatingIslandButton)?.canDrag = Self.freeFloatingIsland
        let savedScreen = floatingOrigin.flatMap { position in
            NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(position) }
        }
        let selectedScreen = NSScreen.screens.first {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber == floatingScreen
        }
        let screen = (Self.freeFloatingIsland ? selectedScreen ?? savedScreen : selectedScreen)
            ?? button.window?.screen ?? NSScreen.main
        let size = NSSize(width: width, height: max(26, NSStatusBar.system.thickness))
        guard size.width > 0, !sleeping, let screen else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        let safeTop = screen.frame.maxY - max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        let top = min(screen.visibleFrame.maxY, safeTop)
        let available = screen.visibleFrame.insetBy(dx: 8, dy: 0)
        let fittedWidth = min(size.width, available.width)
        let fittedHeight = min(size.height, top - available.minY)
        let origin = Self.freeFloatingIsland ? floatingOrigin : nil
        let x = min(max(origin?.x ?? screen.frame.midX - fittedWidth / 2, available.minX), available.maxX - fittedWidth)
        let y = min(max((origin?.y ?? top - 8) - fittedHeight, available.minY), top - fittedHeight)
        let frame = NSRect(x: x, y: y, width: fittedWidth, height: fittedHeight).integral
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    // MARK: 保持在最左侧

    /// 设置：菜单栏里始终排在最左（其他程序新出现的图标会被挤到右边）。
    static var keepsLeftmost: Bool { UserDefaults.standard.object(forKey: "keepLeftmost") as? Bool ?? true }
    private var leftmostWork: DispatchWorkItem?

    /// 新建的菜单栏项总是出现在最左：把我们的项换新名字重建一次，就回到最左。
    /// （系统不提供其他程序菜单栏图标的位置，无法判断是否被挤到右边，所以在有程序启动后统一重建一次。）
    func moveToLeftmost() {
        guard Self.keepsLeftmost, !Self.floatsIsland, renderRequest == nil, !sleeping else { return }
        if popover.isShown || SpectrumController.shared.visualizer.isOpen { scheduleLeftmost(after: 5); return }
        SpectrumController.shared.closePanel()
        StatusItemNames.renew()
        moveIslandAnimated()
    }

    private var islandAnimating = false
    private var islandRevealTarget: Bool?   // 音频部分当前的展开目标
    private var islandAnimation: Timer?

    /// 灵动岛换位置：原处收拢淡出 → 在最左重建 → 从无到有展开淡入（略带回弹），两侧图标随宽度平滑移动。
    private func moveIslandAnimated() {
        guard let old = islandItem, old.isVisible, old.length > 0 else {
            if let old = islandItem { NSStatusBar.system.removeStatusItem(old) }
            islandItem = nil
            updateIsland()
            return
        }
        islandAnimating = true
        let width = old.length
        animate(old, from: width, to: 0, alpha: (1, 0), duration: 0.22, curve: { $0 * $0 }) { [weak self] in
            guard let self else { return }
            NSStatusBar.system.removeStatusItem(old)
            self.islandItem = nil
            let item = self.island.item          // 新建：系统放到最左
            item.length = 0
            self.islandView.alphaValue = 0
            self.updateIsland()                   // 只更新内容，不改宽度
            let target = self.islandView.preferredWidth
            item.isVisible = target > 0
            // 回弹缓动：略微超出再回到目标宽度
            let back: (Double) -> Double = { t in
                let c = 1.4, u = t - 1
                return 1 + (c + 1) * u * u * u + c * u * u
            }
            self.animate(item, from: 0, to: target, alpha: (0, 1), duration: 0.42, curve: back) {
                self.islandAnimating = false
                self.updateIsland()
            }
        }
    }

    /// 逐帧改菜单栏项宽度和内容透明度（菜单栏项没有系统动画，只能一帧帧设置）。
    private func animate(_ item: NSStatusItem, from: CGFloat, to: CGFloat, alpha: (CGFloat, CGFloat)?, duration: Double,
                         curve: @escaping (Double) -> Double, completion: @escaping () -> Void) {
        islandAnimation?.invalidate()
        let start = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = min(Date().timeIntervalSince(start) / duration, 1)
            let e = curve(t)
            item.length = max(0, (from + (to - from) * CGFloat(e)).rounded())
            if let alpha { self.islandView.alphaValue = alpha.0 + (alpha.1 - alpha.0) * CGFloat(min(max(t * 1.2, 0), 1)) }
            self.islandView.needsLayout = true
            self.islandView.needsDisplay = true
            if t >= 1 {
                timer.invalidate()
                item.length = to
                if let alpha { self.islandView.alphaValue = alpha.1 }
                completion()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        islandAnimation = timer
    }

    /// 合并短时间内的多次触发（同时启动好几个程序时只重建一次）。
    private func scheduleLeftmost(after delay: TimeInterval) {
        leftmostWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.moveToLeftmost() }
        leftmostWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    @objc private func appLaunched(_ note: Notification) {
        // 纯后台进程不会有菜单栏图标；其他程序的图标通常在启动后一两秒才出现
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard app?.activationPolicy != .prohibited else { return }
        scheduleLeftmost(after: 3)
    }
    private var iconImages: [Metric: NSImage] = [:]
    private var accessibilityValues: [Metric: String] = [:]   // 读屏：每个指标的当前值
    /// 灵动岛里从左到右的顺序。
    private let monitor = NWPathMonitor()
    private let popover = NSPopover()
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var iconKeys: [Metric: String] = [:]  // 上次绘制的内容，没变就不重绘
    private var sleeping = false
    private var previous: Traffic?
    private var physicalInterfaces: [(name: String, index: UInt32)]?
    private var cpuLoad = CPULoad()
    private var previousDisk: DiskStats?
    private var diskCapacity: (available: Int64?, total: Int64?, used: Double?)
    private var tick = 0
    private var showingUpload = false  // 自动模式当前显示的是上传还是下载
    private let temperatures = Temperatures()  // 首次读取时扫描 SMC 传感器
    private var lastTemperature: Double?
    private var hotSince: [Metric: TimeInterval] = [:]  // CPU / GPU 进入高负载的时刻
    private var heroes: [Metric: HeroData] = [:]  // 各指标面板的主数据卡，随每次刷新更新
    private var history: [Metric: (a: [Double], b: [Double]?)] = [:]  // 最近 300 次刷新的读数
    private var lastRates: (upload: Double, download: Double)?
    private var interfaceLabel = "—"
    private var peakWatts: Double = 30
    private var peakDownload: Double = 1_000_000  // 网速圆环的满格：本次运行以来的下载峰值（至少 1MB/s）
    private var timer: Timer?
    private let panel = PanelModel()
    private lazy var hosting: NSHostingController<PanelView> = {
        let controller = NSHostingController(rootView: PanelView(model: panel))
        controller.sizingOptions = [.preferredContentSize]  // 面板高度随内容变化
        return controller
    }()
    private let settingsModel = SettingsModel()
    private let windows = WindowManager()
    private var curveModel: CurveEditorModel?
    /// GPU 核心数（IORegistry 的 gpu-core-count），只读一次。
    private lazy var gpuCores: Int? = {
        var count: Int?
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        if service != 0 {
            count = (IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber)?.intValue
            IOObjectRelease(service)
        }
        return count
    }()
    private let sampleQueue = DispatchQueue(label: "local.codex.islet.apps")
    private let appResolver = AppIdentityResolver()  // 仅在 sampleQueue 上使用
    private var shownMetric: Metric?
    private var panelTimer: Timer?
    private var sampleSession = UUID()
    private var pendingMetric: Metric?  // 已点击、正在取数据、尚未弹出的指标
    private var sampleInProgress = false
    // 后台快照：每 30 秒取一份，点开面板时拿新样本与之对比，排行立即可用
    private var trafficSnapshots: [AppTraffic] = []
    private var processSnapshots: [ProcessSample] = []
    private var gpuSnapshots: [GPUSample] = []
    private var snapshotInProgress = false
    private var cachedRankings: [Metric: [RankedApp]] = [:]  // 最近一次算出的排行，点开时先显示

    /// 离屏渲染走查：--render <目标> <输出.png> [light|dark] [expanded]，不创建菜单栏图标。
    var renderRequest: (target: String, output: String, dark: Bool, expanded: Bool)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let request = renderRequest {
            runRender(request)
            return
        }
        _ = island
        applyItemVisibility()
        SpectrumController.shared.openSettings = { [weak self] in self?.openSettings(page: .menuBar, expand: "music") }
        SpectrumController.shared.showContextMenu = { [weak self] anchor in self?.showIslandMenu(from: anchor) }
        SpectrumController.shared.setHost(self)   // 频谱放进灵动岛左侧
        SpectrumController.shared.start()  // 在指标项之后创建：排在 CPU 左侧
        SoundController.shared.openSettings = { [weak self] in self?.openSettings(page: .menuBar, expand: "bluetooth") }
        SoundController.shared.start()
        SoundController.shared.onBluetoothImage = { [weak self] image in
            self?.bluetoothImage = image
            self?.applyBluetoothImage()
        }
        SoundController.shared.onBluetoothPanel = { [weak self] shown in self?.islandView.trailingSelected = shown }
        SoundController.shared.startBluetoothItem()
        installMainMenu()
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.appearance = AppearanceSetting.current.nsAppearance
        wirePanel()
        wireSettings()
        FanHelperClient.shared.resume()
        WallpaperController.shared.start()
        monitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.resetSampling() }
        }
        monitor.start(queue: DispatchQueue(label: "local.codex.islet.path"))
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didMountNotification, object: nil)
        workspace.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didUnmountNotification, object: nil)
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(appLaunched(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        scheduleLeftmost(after: 3)   // 启动时也排到最左
        AlertCenter.shared.prepare()
        // 检查更新：启动 30 秒后一次，之后每 6 小时看一眼（距上次检查不满一天会跳过）
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { UpdateChecker.checkInBackground() }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in UpdateChecker.checkInBackground() }
        if UserDefaults.standard.bool(forKey: "keepAwakeOnLaunch") { KeepAwake.shared.set(.always) }
        // 系统不提供禁止 ⌘ 拖动菜单栏图标的接口：发现在菜单栏里 ⌘ 拖动后，自动把灵动岛放回最左
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard event.modifierFlags.contains(.command) else { return }
            let point = NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
                  point.y >= screen.frame.maxY - NSStatusBar.system.thickness - 6 else { return }
            self?.scheduleLeftmost(after: 0.4)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(floatingScreenChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        // 屏幕关闭 / 切换用户时菜单栏不可见，暂停采样省电
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        refresh()
        startRefreshTimer()
        takeSnapshots()
        let snapshotTimer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.takeSnapshots() }
        snapshotTimer.tolerance = 5
        RunLoop.main.add(snapshotTimer, forMode: .common)
    }

    private func applyItemVisibility() {
        updateIsland()
        if let shownMetric, !shownMetric.isShown { popover.performClose(nil) }
    }

    /// 把各指标图像排进灵动岛，宽度变化时才调整菜单栏项长度。
    private func updateIsland() {
        guard renderRequest == nil else { return }
        let view = island.view
        view.segments = MetricOrder.current.compactMap { metric in
            guard metric.isShown, let image = iconImages[metric] else { return nil }
            return (metric, image)
        }
        view.trailing = bluetoothImage
        view.slots = IslandOrder.items.compactMap { id -> MetricsIslandView.Slot? in
            switch id {
            case "music": return .audio
            case "bluetooth": return .trailing
            default: return Metric.allCases.first { "\($0)" == id }.map { .metric($0) }
            }
        }
        let controller = SpectrumController.shared
        view.backdrop = controller.islandBackdrop
        if let bars = controller.hostedBars {
            let barsWidth = bars.preferredWidth
            if view.audio?.view !== bars || view.audio?.width != barsWidth { view.audio = (bars, barsWidth) }
            view.audioLeadsWithCircle = bars.leadsWithCircle
            let shown = controller.embeddedLayout != nil
            if islandRevealTarget != shown {
                let first = islandRevealTarget == nil
                islandRevealTarget = shown
                view.setRevealed(shown, animated: !first && island.item.isVisible)
            }
        } else {
            view.audio = nil
            islandRevealTarget = nil
        }
        // 读屏：按显示顺序读出各指标，如“CPU 使用率 18%，GPU 使用率 32%…”
        let summary = MetricOrder.current.filter(\.isShown).compactMap { metric in
            accessibilityValues[metric].map { "\(metric.accessibilityLabel) \($0)" }
        }
        let audioSummary = view.audio != nil ? SpectrumController.shared.accessibilitySummary : nil
        layoutIsland(width: view.preferredWidth)
        islandAnchor?.setAccessibilityValue(([audioSummary].compactMap { $0 } + summary).joined(separator: "，"))
    }

    @objc private func islandClicked(_ sender: NSView) {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            popover.performClose(nil)
            showIslandMenu(from: sender)
            return
        }
        guard let window = sender.window else { return }
        let view = island.view
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        // 末尾的蓝牙设备：打开蓝牙面板
        if let trailing = view.trailingFrame, trailing.contains(point) {
            if popover.isShown || pendingMetric != nil { popover.close(); closePanel() }
            SpectrumController.shared.closePanel()
            SoundController.shared.toggleBluetoothPanel(from: sender, anchor: view.convert(trailing, to: sender))
            return
        }
        SoundController.shared.closeBluetoothPanel()
        // 左侧音频部分：交给频谱（播放按钮、面板）
        if let audioRect = view.audioRect, audioRect.contains(point) {
            if popover.isShown || pendingMetric != nil {
                popover.close()
                closePanel()
            }
            SpectrumController.shared.hostClicked(sender, anchor: view.convert(audioRect, to: sender))
            return
        }
        SpectrumController.shared.closePanel()
        guard let metric = view.metric(at: point), let rect = view.frames().first(where: { $0.metric == metric })?.rect else { return }
        togglePanel(metric, from: sender, anchor: view.convert(rect, to: sender))
    }

    /// 设置里调整了指标顺序：灵动岛直接重排。
    func metricOrderChanged() { updateIsland() }

    /// 蓝牙设备图像更新：画进灵动岛末尾。
    private func applyBluetoothImage() {
        if islandView.trailing !== bluetoothImage { updateIsland() }
    }

    private func startRefreshTimer() {
        timer?.invalidate()
        let interval = Double(SpeedSetting.interval.selection + 1)
        let refreshTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refreshTimer.tolerance = interval * 0.1  // 允许系统合并唤醒，速率按实际间隔计算不受影响
        RunLoop.main.add(refreshTimer, forMode: .common)
        timer = refreshTimer
    }

    // MARK: - 离屏渲染（设计走查）

    private func runRender(_ request: (target: String, output: String, dark: Bool, expanded: Bool)) {
        let metric = Metric.allCases.first { "\($0)" == request.target }
        takeSnapshots()  // 先取快照（作为排行的对比基线），再标记正在看的面板
        shownMetric = metric ?? .fan
        refresh()
        // 等 1.3 秒取第二个样本，速率、占用率、排行才有值
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [self] in
            refresh()
            guard let metric else {
                writeRender(request)
                return
            }
            panel.metric = metric
            panel.expanded = request.expanded
            panel.flatRender = true
            updateThermal()
            updateHero()
            panel.traffic = metric == .network ? TrafficLedger.shared.current() : nil
            if metric == .network {
                panel.connection = NetworkDetails.Info(publicIP: "203.0.113.24", wifi: "Home-5G · 信号强（-48 dBm）", latency: 18)
            }
            if metric == .disk { panel.drives = DriveHealth.read() }
            if metric == .power { panel.battery = BatteryInfo.read() ?? BatteryInfo(level: 82, charging: true, health: 91, cycles: 214) }
            if metric == .disk { panel.volumes = ExternalVolumes.list() }
            collect(metric) { [self] result in
                render(result, metric: metric)
                if CommandLine.arguments.contains("demo") {
                    panel.rows = Self.demoRows(metric, columns: panel.rows.first?.values.count ?? 1)   // README 截图：不暴露本机进程
                } else {
                    let target = panel.rows.first { $0.canTerminate }?.id
                    panel.hovered = target          // 走查：显示悬停状态与“确认退出”
                    panel.confirming = target
                }
                panel.frozen = true
                if panel.history.count < 2 {    // 走查：没有历史时用示例曲线，检查图例排版
                    // 示例曲线：几段起伏 + 固定的伪随机抖动，看起来像真实负载
                    func noise(_ i: Int, _ seed: Double) -> Double { let x = sin(Double(i) * 12.9898 + seed) * 43758.5453; return x - x.rounded(.down) }
                    panel.history = (0..<60).map { i in
                        let d = Double(i)
                        return max(1, 9 + 6 * sin(d / 7) + 5 * max(0, sin(d / 3.1 - 1)) + 5 * noise(i, 1))
                    }
                    if metric == .network || metric == .disk {
                        panel.history2 = (0..<60).map { i in max(0.5, 2.5 + 1.5 * sin(Double(i) / 5 + 2) + 1.5 * noise(i, 7)) }
                    }
                    if panel.historyPeak.isEmpty { panel.historyPeak = "峰值 16KB/s" }
                }
                writeRender(request)
            }
        }
    }

    /// 应用图标转成 64 像素的单一位图（多尺寸图标在离屏渲染里会出问题）。
    private static func flatIcon(_ icon: NSImage) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.addRepresentation(rep)
        return image
    }

    /// README 截图用的示例排行（常见应用 + 合理数值）。
    private static func demoRows(_ metric: Metric, columns: Int) -> [RankRowData] {
        let apps: [(String, String)] = [("Google Chrome", "/Applications/Google Chrome.app"), ("网易云音乐", "/Applications/NeteaseMusic.app"),
                                        ("微信", "/Applications/WeChat.app"), ("Visual Studio Code", "/Applications/Visual Studio Code.app"),
                                        ("访达", "/System/Library/CoreServices/Finder.app")]
        let values: [[String]] = {
            switch metric {
            case .network: return [["1.8MB", "96KB"], ["420KB", "12KB"], ["86KB", "40KB"], ["12KB", "3KB"], ["2KB", "0KB"]]
            case .disk: return [["24MB", "3.1MB"], ["8.2MB", "1.2MB"], ["2.1MB", "640KB"], ["0KB", "420KB"], ["96KB", "0KB"]]
            case .memory: return [["2.4G"], ["860M"], ["620M"], ["540M"], ["180M"]]
            case .power: return [["6.2W"], ["1.8W"], ["0.9W"], ["0.6W"], ["0.2W"]]
            default: return [["38%"], ["12%"], ["6.4%"], ["4.1%"], ["1.2%"]]
            }
        }()
        let shares = [1, 0.34, 0.18, 0.12, 0.04]
        return apps.indices.map { i in
            let row = values[i]
            return RankRowData(id: "demo\(i)", name: apps[i].0, icon: Self.flatIcon(NSWorkspace.shared.icon(forFile: apps[i].1)),
                               values: Array((row + Array(repeating: row.last ?? "", count: max(columns - row.count, 0))).prefix(max(columns, 1))),
                               share: shares[i], dim: false, tooltip: "", pids: [], canTerminate: false)
        }
    }

    private func writeRender(_ request: (target: String, output: String, dark: Bool, expanded: Bool)) {
        let scheme: ColorScheme = request.dark ? .dark : .light
        let view: AnyView
        switch request.target {
        case "settings":
            updateControlTemperatures()
            if let page = SettingsPage.allCases.first(where: { CommandLine.arguments.contains($0.rawValue) }) { settingsModel.page = page }
            if CommandLine.arguments.contains("open") { settingsModel.expanded = ["cpu", "temperature", "fan"] }
            SoundController.fillDemo(SoundController.shared.panel)
            view = AnyView(SettingsView(model: settingsModel, flat: true).frame(width: 680, height: 560))
        case "curve":
            let fan = Fan.readAll().first
            let model = CurveEditorModel(minimum: fan?.minimum ?? 1000, maximum: fan?.maximum ?? 4900)
            model.currentCelsius = temperatures.controlCelsius(basis: FanHelperClient.shared.config.basis)
            model.selected = 1
            view = AnyView(CurveEditorView(model: model))
        case "bluetooth":
            let model = SoundPanelModel()
            SoundController.fillDemo(model)
            view = AnyView(BluetoothPanelView(model: model))
        case "spectrum":
            let model = SpectrumPanelModel()
            model.levels = (0..<SpectrumAnalyzer.bandCount).map { i in
                Float(max(0.08, 0.85 * exp(-pow(Double(i) - 7, 2) / 30) + 0.12 * sin(Double(i) * 1.7) + 0.15))
            }
            model.audible = true
            // 演示用：渐变封面 + 正在播放
            let art = NSImage(size: NSSize(width: 100, height: 100), flipped: false) { rect in
                NSGradient(starting: NSColor(srgbRed: 1, green: 0.45, blue: 0.3, alpha: 1),
                           ending: NSColor(srgbRed: 0.55, green: 0.15, blue: 0.5, alpha: 1))!.draw(in: rect, angle: -45)
                return true
            }
            var info = NowPlayingInfo()
            info.title = "Moments"; info.artist = "Kygo"; info.duration = 240; info.elapsed = 83; info.playing = true
            info.bundle = "com.netease.163music"; info.artwork = art; info.tint = NowPlayingMonitor.dominantColor(of: art)
            if CommandLine.arguments.contains("expanded") { model.nowPlaying = info }
            if CommandLine.arguments.contains("source") {
                model.nowPlaying = nil
                model.source = SoundSource(pid: 0, bundle: nil, name: "原神", icon: nil)
            }
            SoundController.fillDemo(SoundController.shared.panel)
            if CommandLine.arguments.contains("visualizer") {
                // 全屏频谱：演示电平
                let visual = VisualizerModel()
                // 演示电平：低频鼓点、中频人声、高频逐渐回落（不是只有左边一个峰）
                let demoLevels: [Float] = (0..<SpectrumAnalyzer.bandCount).map { i in
                    let d = Double(i)
                    let shape = 0.18 + 0.62 * exp(-pow(d - 3, 2) / 10) + 0.42 * exp(-pow(d - 11, 2) / 14)
                        + 0.26 * exp(-pow(d - 18, 2) / 9) + 0.08 * sin(d * 2.3)
                    return Float(min(max(shape, 0.12), 0.95))
                }
                for _ in 0..<12 { visual.bars.push(demoLevels, audible: true) }
                visual.demo = true
                visual.info = model.nowPlaying
                visual.audible = true
                visual.controlsVisible = true
                visual.screenNames = []   // 只有一块屏时不显示切换菜单（离屏渲染画不出菜单）
                let wide = CommandLine.arguments.contains("wide")
                view = AnyView(VisualizerView(model: visual).frame(width: wide ? 1720 : 1440, height: wide ? 720 : 900))
            } else {
                view = AnyView(SpectrumPanelView(model: model))
            }
        case "rules":
            let fan = Fan.readAll().first.map { FanData(current: $0.current, minimum: $0.minimum, maximum: $0.maximum) }
            view = AnyView(RulesView(fan: fan, flat: true))
        default:
            view = AnyView(PanelView(model: panel))
        }
        MainActor.assumeIsolated {
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
            renderer.scale = 2
            guard let image = renderer.cgImage else { print("渲染失败"); exit(1) }
            let bitmap = NSBitmapImageRep(cgImage: image)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: request.output))
            print("已渲染：\(request.output)（\(image.width / 2)×\(image.height / 2)）")
        }
        exit(0)
    }

    /// 菜单栏程序没有菜单栏菜单，快捷键默认不起作用；补一个最小主菜单，让窗口支持 ⌘W 关闭、文字支持拷贝。
    private func installMainMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "退出 islet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    // MARK: - 面板与窗口的动作

    private func wirePanel() {
        panel.onHistoryRange = { [weak self] in self?.updateHero() }
        NetworkDetails.shared.onChange = { [weak self] info in
            guard let self, self.shownMetric == .network else { return }
            self.panel.connection = info
        }
        panel.onSettings = { [weak self] in self?.openSettings() }
        panel.onQuit = { NSApp.terminate(nil) }
        panel.onDiagnostics = { [weak self] in
            Diagnostics.copyReport()
            self?.panel.footerNote = "已复制诊断信息"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.panel.footerNote = nil }
        }
        panel.onSelectStrategy = { [weak self] strategy in self?.selectStrategy(strategy) }
        panel.onFixedCommit = { [weak self] rpm in
            FanHelperClient.shared.update({ $0.fixedRPM = rpm }) { error in self?.panel.strategyError = error }
        }
        panel.onOpenCurve = { [weak self] in self?.openCurveEditor() }
        panel.onOpenRules = { [weak self] in self?.openRules() }
        panel.onQuitApp = { [weak self] row in self?.quitApp(row) }
        panel.onForceQuit = { [weak self] row in self?.forceQuitApp(row) }
        panel.onEject = { [weak self] volume in
            guard let self else { return }
            self.panel.ejecting.insert(volume.id)
            ExternalVolumes.eject(volume) { error in
                self.panel.ejecting.remove(volume.id)
                self.panel.volumes = ExternalVolumes.list()
                self.panel.footerNote = error == nil ? "已推出“\(volume.name)”" : nil
                if let error { self.showAlert("推出失败", error) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.panel.footerNote = nil }
            }
        }
        panel.onToggleExpanded = { [weak self] in
            guard let self else { return }
            self.panel.expanded.toggle()
            self.updateThermal()
        }
    }

    /// 请求退出；3 秒后仍在运行则提供“强制结束”。
    private func quitApp(_ row: RankRowData) {
        let note: String?
        switch ProcessControl.quit(row.id, pids: row.pids) {
        case .requested:
            panel.quitting.insert(row.id)
            note = "已请求退出 \(row.name)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                self.panel.quitting.remove(row.id)
                if ProcessControl.isRunning(row.pids) {
                    self.panel.forceable.insert(row.id)
                    self.panel.footerNote = "\(row.name) 仍在运行，可以强制结束"
                } else {
                    self.panel.footerNote = "\(row.name) 已退出"
                    self.refreshPanel()
                }
            }
        case .notFound: note = "\(row.name) 已经不在运行"
        case .denied: note = "\(row.name) 属于其他用户或系统，无法结束"
        case .notAllowed: note = "系统进程不能在这里结束"
        }
        panel.footerNote = note
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.panel.footerNote == note { self?.panel.footerNote = nil }
        }
    }

    private func forceQuitApp(_ row: RankRowData) {
        guard confirm("强制结束 \(row.name)？", "它没有响应退出请求。强制结束会立即终止它，未保存的内容会丢失。", button: "强制结束") else { return }
        _ = ProcessControl.forceQuit(row.id, pids: row.pids)
        panel.forceable.remove(row.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.panel.footerNote = ProcessControl.isRunning(row.pids) ? "\(row.name) 仍未结束" : "\(row.name) 已结束"
            self.refreshPanel()
        }
    }

    private func wireSettings() {
        settingsModel.onChange = { [weak self] setting in
            guard let self else { return }
            switch setting {
            case .interval: self.startRefreshTimer()
            case .count: self.refreshPanel()
            default:
                self.applyItemVisibility()
                self.iconKeys.removeAll()
                self.refresh()
            }
        }
        settingsModel.onMetricOrder = { [weak self] in self?.metricOrderChanged() }
        settingsModel.onFullScreenFloatingIsland = { [weak self] in self?.setFullScreenFloatingIsland($0) }
        settingsModel.onFreeFloatingIsland = { [weak self] in self?.setFreeFloatingIsland($0) }
        settingsModel.onFloatingIsland = { [weak self] in self?.setFloatingIsland($0) }
        settingsModel.onKeepLeftmost = { [weak self] in self?.moveToLeftmost() }   // 重新打开置顶：立即回到最左
        settingsModel.onUnits = { [weak self] in
            self?.iconKeys.removeAll()   // 单位变了：重画所有指标
            self?.refresh()
        }
        settingsModel.onResetAll = {
            // 保留流量统计和本地签名用到的记录，其余设置全部清掉，然后重新启动
            let defaults = UserDefaults.standard
            let keep = ["trafficLedger"]
            let saved = keep.reduce(into: [String: Any]()) { $0[$1] = defaults.object(forKey: $1) }
            if let domain = Bundle.main.bundleIdentifier { defaults.removePersistentDomain(forName: domain) }
            saved.forEach { defaults.set($1, forKey: $0) }
            defaults.synchronize()
            SettingsTransfer.relaunch()
        }
        settingsModel.onAppearance = { [weak self] in
            self?.popover.appearance = AppearanceSetting.current.nsAppearance
            self?.windows.applyAppearance()
        }
        settingsModel.onInstallFan = { [weak self] in
            _ = self?.ensureFanHelper(title: "安装风扇控制组件")
            self?.settingsModel.refresh()
        }
        settingsModel.onUninstallFan = { [weak self] in self?.uninstallFanHelper() }
        settingsModel.onCopyDiagnostics = { [weak self] in
            Diagnostics.copyReport()
            self?.settingsModel.diagnosticsNote = "已复制"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.settingsModel.diagnosticsNote = nil }
        }
    }

    /// 右键菜单（系统原生菜单：点任意位置都会关闭，带快捷键提示）：设置、全局悬浮、关于、退出。
    private func islandMenu() -> NSMenu {
        let menu = NSMenu()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let title = NSMenuItem(title: "islet \(version)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "设置…", action: #selector(menuOpenSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let floating = NSMenuItem(title: "全局悬浮", action: #selector(menuToggleFloating), keyEquivalent: "")
        floating.target = self
        floating.state = Self.floatsIsland ? .on : .off
        menu.addItem(floating)
        let about = NSMenuItem(title: "关于 islet", action: #selector(menuOpenAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 islet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private func showIslandMenu(from anchor: NSView) {
        SoundController.shared.closeBluetoothPanel()
        SpectrumController.shared.closePanel()
        // 菜单栏里：从按钮下沿弹出；悬浮时：在鼠标位置弹出
        let mouse = anchor.convert(anchor.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        let point = Self.floatsIsland && anchor.bounds.contains(mouse) ? mouse : NSPoint(x: 0, y: anchor.bounds.height + 5)
        islandMenu().popUp(positioning: nil, at: point, in: anchor)
    }

    @objc private func menuOpenSettings() { openSettings() }
    @objc private func menuOpenAbout() { openSettings(page: .about) }
    @objc private func menuToggleFloating() { setFloatingIsland(!Self.floatsIsland) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    private func openSettings(page: SettingsPage? = nil, expand: String? = nil) {
        if let page { settingsModel.page = page }
        if let expand { settingsModel.expanded.insert(expand) }
        popover.performClose(nil)
        updateControlTemperatures()
        // 宽度 = 侧栏 190 + 分隔线 1 + 内容左右边距 22×2 + 预览里岛的宽度：岛和下面的卡片一样宽。
        // 指标关得很少、岛很短时，内容至少留 480，设置行不会挤
        let content = max(MenuBarPreview.islandWidth(), 480)
        let width = ceil(190 + 1 + 22 * 2 + content)
        windows.show("settings", title: "islet 设置", size: NSSize(width: width, height: 620), resizable: true) {
            SettingsView(model: settingsModel)
        }
    }

    private func openCurveEditor() {
        guard let fan = Fan.readAll().first else { return }
        popover.performClose(nil)
        let model = curveModel ?? CurveEditorModel(minimum: fan.minimum, maximum: fan.maximum)
        model.points = FanHelperClient.shared.config.curve
        model.onActivate = { [weak self] in self?.selectStrategy(.curve) }
        curveModel = model
        updateControlTemperatures()
        windows.show("curve", title: "温度曲线", size: NSSize(width: 640, height: 560)) {
            CurveEditorView(model: model)
        }
    }

    private func openRules() {
        let fan = Fan.readAll().first.map { FanData(current: $0.current, minimum: $0.minimum, maximum: $0.maximum) }
        popover.performClose(nil)
        FanHelperClient.shared.refreshStatus()
        windows.show("rules", title: "规则", size: NSSize(width: 580, height: 440)) {
            RulesView(fan: fan, onActivate: { [weak self] in self?.selectStrategy(.rules) })
        }
    }

    /// 设置页、曲线编辑器显示的参考温度。
    private func updateControlTemperatures() {
        let groups = temperatures.read(only: Set(FanControl.controlGroups))
        if let average = groups.map(\.average).max(), let peak = groups.map(\.maximum).max() {
            settingsModel.controlTemperatures = (average, peak)
            curveModel?.currentCelsius = FanHelperClient.shared.config.basis == .peak ? peak : average
        }
    }

    // MARK: - 弹出面板

    private struct Collected {
        let ranking: [RankedApp]?  // nil：还没有可对比的快照
        let failed: Bool
    }

    /// 点击某个菜单栏指标：打开它的排行；再点同一个关闭；点另一个直接切过去。
    /// 取一份新样本（几十毫秒）与后台快照对比，数据就绪后才弹出，打开即可看到排行。
    private func togglePanel(_ metric: Metric, from button: NSView, anchor: NSRect? = nil) {
        if popover.isShown || pendingMetric != nil {
            let same = (shownMetric ?? pendingMetric) == metric
            popover.close()
            closePanel()
            if same { return }
        }
        let session = UUID()
        sampleSession = session
        if let cached = cachedRankings[metric] {
            // 有现成排行：立即弹出，随后用新样本刷新
            present(metric, from: button, anchor: anchor, with: Collected(ranking: cached, failed: false))
            refreshPanel()
            return
        }
        pendingMetric = metric
        collect(metric) { [weak self] result in
            guard let self, session == self.sampleSession, self.pendingMetric == metric else { return }
            self.pendingMetric = nil
            self.present(metric, from: button, anchor: anchor, with: result)
        }
    }

    private func present(_ metric: Metric, from button: NSView, anchor: NSRect? = nil, with result: Collected) {
        guard button.window?.isVisible == true else { return }
        panel.metric = metric
        panel.expanded = false
        panel.fixedDraft = nil
        panel.strategyError = nil
        panel.rows = []
        shownMetric = metric
        popover.appearance = AppearanceSetting.current.nsAppearance
        if metric == .fan || metric == .temperature || metric == .gpu || metric == .power {
            refresh()  // 这些面板的主数据卡需要温度 / 风扇读数，打开时先刷新一次
        }
        updateHero()
        updateThermal()
        if metric == .fan { FanHelperClient.shared.refreshStatus() }
        panel.hovered = nil
        panel.confirming = nil
        panel.frozen = false
        panel.quitting = []
        panel.forceable = []
        panel.traffic = metric == .network ? TrafficLedger.shared.current() : nil
        if metric == .network {
            panel.connection = NetworkDetails.shared.info
            NetworkDetails.shared.refresh()
        }
        if metric == .disk {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let drives = DriveHealth.read()
                DispatchQueue.main.async { if self?.shownMetric == .disk { self?.panel.drives = drives } }
            }
        }
        if metric == .power { panel.battery = BatteryInfo.read() }
        if metric == .disk { panel.volumes = ExternalVolumes.list() }
        render(result, metric: metric)
        popover.show(relativeTo: anchor ?? button.bounds, of: button, preferredEdge: .minY)
        guard popover.isShown else { shownMetric = nil; return }
        if anchor != nil { island.view.selected = metric }
        watchOutsideClicks()
        startPanelTimer(quick: result.ranking == nil)
    }

    func popoverDidClose(_ notification: Notification) {
        // close() 后可能紧接着打开了另一个指标的面板，此时不要清理
        guard !popover.isShown, pendingMetric == nil else { return }
        closePanel()
    }

    private func closePanel() {
        removeClickMonitors()
        panelTimer?.invalidate()
        panelTimer = nil
        sampleSession = UUID()
        pendingMetric = nil
        shownMetric = nil
        island.view.selected = nil
        let resolver = appResolver
        sampleQueue.async { resolver.removeAll() }  // PID 会被复用，面板关闭后丢弃缓存
    }

    private func watchOutsideClicks() {
        removeClickMonitors()
        let mouseDown: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDown) { [weak self] _ in
            self?.popover.performClose(nil)
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseDown) { [weak self] event in
            guard let self, self.popover.isShown, event.window !== self.hosting.view.window else { return event }
            // 点到自己的菜单栏图标时交给 togglePanel 处理（关闭或切换）
            if let button = self.islandAnchor, event.window === button.window,
               button.bounds.contains(button.convert(event.locationInWindow, from: nil)) {
                return event
            }
            self.popover.performClose(nil)
            return event
        }
    }

    private func removeClickMonitors() {
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        globalClickMonitor = nil
        localClickMonitor = nil
    }

    /// 面板打开期间每 2 秒更新；还没有快照（刚启动）时 1 秒后先补一次。
    private func startPanelTimer(quick: Bool) {
        let timer = Timer(fire: Date(timeIntervalSinceNow: quick ? 1 : 2), interval: 2, repeats: true) { [weak self] _ in
            self?.refreshPanel()
        }
        timer.tolerance = 0.2
        panelTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshPanel() {
        guard !sleeping, let metric = shownMetric, !sampleInProgress else { return }
        sampleInProgress = true
        let session = sampleSession
        collect(metric) { [weak self] result in
            guard let self else { return }
            self.sampleInProgress = false
            guard session == self.sampleSession, self.shownMetric == metric,
                  result.failed || result.ranking != nil else { return }
            self.render(result, metric: metric)
        }
    }

    private func render(_ result: Collected, metric: Metric) {
        guard metric != .temperature else { return }  // 温度面板没有应用排行
        if result.failed {
            panel.rows = []
            panel.message = metric == .network ? "暂时无法读取应用流量" : "暂时无法读取进程信息"
            return
        }
        guard let ranking = result.ranking else {
            panel.rows = []
            panel.message = "正在采样…"
            return
        }
        let limit = [3, 5, 8][SpeedSetting.count.selection]
        let ranked = Array(ranking.prefix(limit))
        panel.setRanking(ranked, format: Self.formatter(for: metric))
        panel.message = ranked.isEmpty ? metric.emptyMessage : nil
    }

    /// 取一份新样本，与至少 1 秒前的最近快照对比得出排行；新样本也存为快照。
    /// 采样、进程路径解析与排序都在后台队列，回调在主线程。
    private func collect(_ metric: Metric, completion: @escaping (Collected) -> Void) {
        let started = Date()
        if metric == .temperature {
            // 温度面板的数据在 refresh 里直接读 SMC，不需要应用排行
            updateThermal()
            panel.sampleMillis = Int(Date().timeIntervalSince(started) * 1000)
            completion(Collected(ranking: [], failed: false))
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        func usable(_ time: TimeInterval) -> Bool { now - time >= 1 && now - time < 70 }
        let trafficBase = trafficSnapshots.last { usable($0.time) }
        let processBase = processSnapshots.last { usable($0.time) }
        let gpuBase = gpuSnapshots.last { usable($0.time) }
        let resolver = appResolver
        sampleQueue.async { [weak self] in
            var ranking: [RankedApp]?
            var traffic: AppTraffic?
            var processes: ProcessSample?
            var gpu: GPUSample?
            switch metric {
            case .network:
                traffic = AppTraffic.sample()
                ranking = trafficBase.flatMap { old in traffic?.ranked(since: old, resolver: resolver) }
            case .cpu, .memory, .disk, .power, .fan:
                processes = ProcessSample.sample()
                switch metric {
                case .cpu: ranking = processBase.flatMap { old in processes?.cpuRanking(since: old) }
                case .disk: ranking = processBase.flatMap { old in processes?.diskRanking(since: old) }
                case .power, .fan: ranking = processBase.flatMap { old in processes?.powerRanking(since: old) }
                default: ranking = processes?.memoryRanking()
                }
            case .gpu:
                gpu = GPUSample.read(includeClients: true)
                ranking = gpuBase.flatMap { old in gpu?.ranking(since: old, resolver: resolver) }
            case .temperature:
                break  // 已在上面同步处理
            }
            let failed = traffic == nil && processes == nil && gpu == nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.store(traffic: traffic, processes: processes, gpu: gpu)
                if let ranking { self.cachedRankings[metric] = ranking }
                if self.shownMetric == metric || self.pendingMetric == metric {
                    self.panel.sampleMillis = Int(Date().timeIntervalSince(started) * 1000)
                }
                completion(Collected(ranking: ranking, failed: failed))
            }
        }
    }

    private func store(traffic: AppTraffic?, processes: ProcessSample?, gpu: GPUSample?) {
        if let traffic { trafficSnapshots = Array((trafficSnapshots + [traffic]).suffix(3)) }
        if let processes { processSnapshots = Array((processSnapshots + [processes]).suffix(3)) }
        if let gpu { gpuSnapshots = Array((gpuSnapshots + [gpu]).suffix(3)) }
    }

    /// 后台快照：只为菜单栏上显示的指标采集；面板正在看的那类由面板自己更新。
    private func takeSnapshots() {
        guard !sleeping, !snapshotInProgress else { return }
        var traffic = Metric.network.isShown
        var processes = Metric.allCases.contains { $0.usesProcesses && $0.isShown }
        var gpu = Metric.gpu.isShown
        if let shownMetric {
            if shownMetric == .network { traffic = false }
            if shownMetric == .gpu { gpu = false }
            if shownMetric.usesProcesses { processes = false }
        }
        guard traffic || processes || gpu else { return }
        snapshotInProgress = true
        let trafficBase = trafficSnapshots.last
        let processBase = processSnapshots.last
        let gpuBase = gpuSnapshots.last
        let resolver = appResolver
        sampleQueue.async { [weak self] in
            // 顺便与上一份快照对比，预先算好排行，点开面板时直接显示
            var rankings: [Metric: [RankedApp]] = [:]
            let trafficSample = traffic ? AppTraffic.sample() : nil
            if let trafficSample, let trafficBase {
                rankings[.network] = trafficSample.ranked(since: trafficBase, resolver: resolver)
            }
            let processSample = processes ? ProcessSample.sample() : nil
            if let processSample {
                rankings[.memory] = processSample.memoryRanking()
                if let processBase {
                    rankings[.cpu] = processSample.cpuRanking(since: processBase)
                    rankings[.disk] = processSample.diskRanking(since: processBase)
                    let power = processSample.powerRanking(since: processBase)
                    rankings[.power] = power
                    rankings[.fan] = power
                }
            }
            let gpuSample = gpu ? GPUSample.read(includeClients: true) : nil
            if let gpuSample, let gpuBase {
                rankings[.gpu] = gpuSample.ranking(since: gpuBase, resolver: resolver)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.snapshotInProgress = false
                self.store(traffic: trafficSample, processes: processSample, gpu: gpuSample)
                for (metric, ranking) in rankings where metric != self.shownMetric {
                    self.cachedRankings[metric] = ranking
                }
            }
        }
    }

    // MARK: - 风扇控制

    /// 切换风扇策略：非“自动”时先确保控制组件已安装且是最新版。
    private func selectStrategy(_ strategy: FanStrategy) {
        panel.strategyError = nil
        if strategy != .auto, !ensureFanHelper(title: "启用风扇调速") { return }
        FanHelperClient.shared.update({ $0.strategy = strategy }) { [weak self] error in
            self?.panel.strategyError = error
            self?.refresh()
        }
    }

    /// 确保组件可用；需要安装或更新时先征得同意，再弹系统密码框。返回是否就绪。
    private func ensureFanHelper(title: String) -> Bool {
        let client = FanHelperClient.shared
        guard client.isRunningFromApplications else {
            showAlert("无法启用风扇调速", "请把 islet 放在“应用程序”文件夹里运行。")
            return false
        }
        if client.isInstalled && client.isHelperCurrent { return true }
        let first = !client.isInstalled
        guard confirm(first ? title : "更新风扇控制组件",
                      (first ? "需要安装一个以管理员权限运行的小组件来调节风扇，接下来会请你输入一次登录密码。\n\n"
                             : "组件版本与当前程序不一致，需要重新安装（会再要一次密码）。\n\n")
                      + "安全措施：转速始终在系统允许的范围内，温度过高时会强制提速、绝不停转；本程序退出、崩溃或电脑睡眠时，风扇会自动交还系统控制。随时可以切回“自动”，或在设置里卸载组件。",
                      button: first ? "安装并启用" : "更新") else { return false }
        popover.performClose(nil)
        if let error = client.install() {
            if error != "已取消" { showAlert("安装失败", error) }
            return false
        }
        settingsModel.refresh()
        return true
    }

    private func uninstallFanHelper() {
        guard confirm("卸载风扇控制组件", "风扇会立即交还系统控制，组件会从系统中移除。以后需要时可以在风扇面板里重新启用。",
                      button: "卸载") else { return }
        if let error = FanHelperClient.shared.uninstall(), error != "已取消" {
            showAlert("卸载失败", error)
        }
        settingsModel.refresh()
        refresh()
    }

    private func confirm(_ title: String, _ text: String, button: String) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showAlert(_ title: String, _ text: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    // MARK: - 菜单栏刷新

    @objc private func volumesChanged() {
        if shownMetric == .disk { panel.volumes = ExternalVolumes.list() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        LongHistory.shared.save()
        TrafficLedger.shared.save()
        FanHelperClient.shared.releaseBeforeQuit()
    }

    @objc private func willSleep() {
        LongHistory.shared.save()
        if !sleeping {
            FanHelperClient.shared.suspend()
            SpectrumController.shared.suspend()
        }
        TrafficLedger.shared.save()
        sleeping = true
        floatingPanel?.orderOut(nil)
        cpuLoad.reset()
        previousDisk = nil
        trafficSnapshots.removeAll()
        processSnapshots.removeAll()
        gpuSnapshots.removeAll()
        cachedRankings.removeAll()
        resetSampling()
    }

    @objc private func didWake() {
        if sleeping {
            FanHelperClient.shared.resume()
            SpectrumController.shared.resume()
        }
        sleeping = false
        resetSampling()
        refresh()
        updateIsland()   // 睡眠时收起了悬浮窗：唤醒后直接放回来，不等指标数值变化
    }

    private func resetSampling() {
        previous = nil
        physicalInterfaces = nil
        display(upload: "—", download: "—", detail: "等待网络数据…")
    }

    /// 网卡列表只在启动和网络变化时枚举一次。
    private func readTraffic() -> Traffic? {
        if physicalInterfaces == nil { physicalInterfaces = Traffic.physicalInterfaces() }
        return Traffic.read(physicalInterfaces ?? [])
    }

    private func refresh() {
        guard !sleeping else { return }
        tick += 1
        refreshSystem()
        let sample = readTraffic()
        defer { previous = sample }
        guard let sample else {
            display(upload: "—", download: "—", detail: "未检测到可用的网卡")
            return
        }
        guard let previous, let rates = sample.rates(since: previous) else {
            display(upload: "—", download: "—", detail: "正在读取 \(sample.interface) 的网速…")
            return
        }
        let upload = Units.networkRate(rates.upload)
        let download = Units.networkRate(rates.download)
        let names = sample.interface.split(separator: "+")
        interfaceLabel = names.count > 1 ? "\(names[0]) 等 \(names.count) 个" : sample.interface
        lastRates = rates
        peakDownload = max(peakDownload, rates.download)
        record(.network, rates.download, rates.upload)
        TrafficLedger.shared.add(down: Double(sample.download - previous.download), up: Double(sample.upload - previous.upload))
        if shownMetric == .network { panel.traffic = TrafficLedger.shared.current() }
        display(upload: upload, download: download, detail: "上传 \(upload)   下载 \(download)", rates: rates)
    }

    /// 只采集菜单栏上显示的、或面板正在看的指标。
    private func wants(_ metric: Metric) -> Bool { metric.isShown || shownMetric == metric }

    /// 更新各指标的菜单栏图标，以及对应面板的主数据卡。
    private func refreshSystem() {
        let shown = shownMetric
        // 功耗：菜单栏、风扇、温度以及多数面板的数据卡都会用到，读一次 SMC 键即可
        let watts = wants(.power) || wants(.fan) || wants(.temperature) || shown != nil ? PowerStats.systemWatts() : nil
        if let watts { peakWatts = max(peakWatts, watts) }
        let fan = Fan.readAll().first
        // 面板打开时读完整温度分组（数据卡、宫格要用），否则只按需读菜单栏那一组
        let groups = shown == nil ? [] : temperatures.read()
        if !groups.isEmpty { lastTemperature = Temperatures.headline(groups) }
        func groupAverage(_ name: String) -> Double? { groups.first { $0.name == name }?.average }
        func degrees(_ value: Double?) -> String { value.map(Units.degrees) ?? "—" }

        if wants(.cpu) {
            let usage = cpuLoad.usage()
            record(.cpu, usage.map { $0 * 100 })
            let text = Self.percent(usage)
            let level = sustainedLevel(.cpu, usage)
            setIcon(.cpu, key: "\(text)|\(level)", value: text) {
                StatusIcons.labeled("CPU", value: text, level: level, widest: "100%")
            }
            let performance = Self.sysctlInt("hw.perflevel0.physicalcpu") ?? 0
            let efficiency = Self.sysctlInt("hw.perflevel1.physicalcpu") ?? 0
            heroes[.cpu] = HeroData(fraction: usage, tone: .load, toneValue: usage,
                                    value: usage.map { "\(Int(($0 * 100).rounded()))" } ?? "—", unit: "% 占用",
                                    rows: [("核心", performance > 0 ? "\(performance) 性能 + \(efficiency) 能效" : "\(ProcessInfo.processInfo.activeProcessorCount) 核"),
                                           ("温度", degrees(groupAverage("CPU 性能核"))),
                                           ("功耗", watts.map { String(format: "%.1f W", $0) } ?? "—")])
        }
        if wants(.gpu) {
            let usage = GPUSample.read(includeClients: false).utilization
            record(.gpu, usage.map { $0 * 100 })
            let text = Self.percent(usage)
            let level = sustainedLevel(.gpu, usage)
            setIcon(.gpu, key: "\(text)|\(level)", value: text) {
                StatusIcons.labeled("GPU", value: text, level: level, widest: "100%")
            }
            heroes[.gpu] = HeroData(fraction: usage, tone: .load, toneValue: usage,
                                    value: usage.map { "\(Int(($0 * 100).rounded()))" } ?? "—", unit: "% 占用",
                                    rows: [("核心", gpuCores.map { "\($0) 核" } ?? "—"),
                                           ("温度", degrees(groupAverage("GPU"))),
                                           ("功耗", watts.map { String(format: "%.1f W", $0) } ?? "—")])
        }
        if wants(.memory), let memory = MemoryStats.read() {
            let text = Self.compactMemory(memory.used)
            // 只有“严重”才变红；“偏高”在很多 Mac 上是常态，不提示
            let level: StatusIcons.Level = memory.pressure == 4 ? .critical : .normal
            setIcon(.memory, key: "\(text)|\(level)", value: "已用 \(text)，内存压力\(memory.pressureText)") {
                StatusIcons.labeled("MEM", value: text, level: level, widest: "88.8G")
            }
            let gib = 1_073_741_824.0
            let fraction = Double(memory.used) / Double(max(memory.total, 1))
            record(.memory, Double(memory.used) / 1_073_741_824)
            heroes[.memory] = HeroData(fraction: fraction, tone: .load,
                                       toneValue: memory.pressure == 4 ? 0.95 : memory.pressure == 2 ? 0.75 : 0.3,
                                       value: String(format: "%.1f", Double(memory.used) / gib), unit: "GB 已用",
                                       rows: [("总量", String(format: "%.0f GB", Double(memory.total) / gib)),
                                              ("压力", memory.pressureText),
                                              ("交换", Self.swapUsed().map { String(format: "%.1f GB", Double($0) / gib) } ?? "—")])
        }
        if wants(.disk) {
            // 容量变化很慢，约每 30 次刷新才查询一次；读写字节每次都取
            let needsCapacity = diskCapacity.total == nil || tick % 30 == 0
            let disk = DiskStats.read(includeCapacity: needsCapacity)
            if needsCapacity { diskCapacity = (disk.available, disk.total, disk.usedFraction) }
            let rates = previousDisk.flatMap { disk.rates(since: $0) }
            record(.disk, rates?.read, rates?.write)
            previousDisk = disk
            let used = diskCapacity.used
            let text = Self.percent(used)
            setIcon(.disk, key: text, value: "已用 \(text)") {
                StatusIcons.labeled("DISK", value: text, level: .init(used, warn: 0.85, alarm: 0.95), widest: "100%")
            }
            heroes[.disk] = HeroData(fraction: used, tone: .load, toneValue: used.map { $0 >= 0.95 ? 0.95 : $0 >= 0.85 ? 0.75 : 0.3 },
                                     value: used.map { "\(Int(($0 * 100).rounded()))" } ?? "—", unit: "% 已用",
                                     rows: [("可用", diskCapacity.available.map(Self.diskSize) ?? "—"),
                                            ("读取", rates.map { "\(Self.compactRate($0.read))/s" } ?? "—"),
                                            ("写入", rates.map { "\(Self.compactRate($0.write))/s" } ?? "—")])
        } else {
            previousDisk = nil
        }
        if wants(.power) {
            record(.power, watts)
            let text = watts.map(Self.compactWatts) ?? "—"
            // 保持唤醒期间，标签由 PWR 换成 AWAKE，一眼可见
            let awake = KeepAwake.shared.isActive
            setIcon(.power, key: "\(text)|\(awake)", value: awake ? "\(text)，保持唤醒中" : text) {
                StatusIcons.labeled(awake ? "AWAKE" : "PWR", value: text, level: .normal, widest: "88W")
            }
            heroes[.power] = HeroData(fraction: watts.map { $0 / peakWatts }, tone: .accent,
                                      value: watts.map { String(format: $0 >= 10 ? "%.0f" : "%.1f", $0) } ?? "—", unit: "瓦",
                                      rows: [("峰值", String(format: "%.0f W", peakWatts)),
                                             ("温度", degrees(groupAverage("CPU 性能核") ?? lastTemperature)),
                                             ("风扇", fan.map { "\(Int($0.current.rounded())) 转" } ?? "—")])
        }
        if wants(.temperature) {
            // 读 SMC 较慢（每个键约 0.1 毫秒），温度变化又慢：面板关闭时每 5 次刷新才读一次菜单栏那一组
            if groups.isEmpty, lastTemperature == nil || tick % 5 == 0 {
                lastTemperature = temperatures.headline()
            }
            let headline = lastTemperature
            record(.temperature, headline)
            let text = headline.map(Units.degrees) ?? "—"
            let level = sustainedLevel(.temperature, headline, threshold: 95)
            setIcon(.temperature, key: "\(text)|\(level)", value: headline.map { "\(Int($0.rounded())) 摄氏度" } ?? "暂无数据") {
                StatusIcons.labeled("TEMP", value: text, level: level, widest: "108°")
            }
            let hottest = groups.max { $0.maximum < $1.maximum }
            heroes[.temperature] = HeroData(fraction: headline.map { $0 / 110 }, tone: .temperature, toneValue: headline,
                                            value: headline.map { "\(Int(Units.temperature($0).rounded()))" } ?? "—", unit: "\(Units.temperatureUnit) 性能核",
                                            rows: [("最热", hottest.map { "\(Units.degrees($0.maximum)) \($0.name)" } ?? "—"),
                                                   ("风扇", fan.map { "\(Int($0.current.rounded())) 转" } ?? "—"),
                                                   ("功耗", watts.map { String(format: "%.1f W", $0) } ?? "—")])
        }
        if wants(.fan) {
            let text = fan.map { String(Int($0.current.rounded())) } ?? "—"
            record(.fan, fan?.current)
            setIcon(.fan, key: text, value: fan == nil ? "没有风扇" : "\(text) 转每分钟") {
                StatusIcons.labeled("FAN", value: text, level: .normal, widest: "8888")
            }
            let client = FanHelperClient.shared
            if shown == .fan { client.refreshStatus() }
            // 以硬件状态为准：模式键为 1 才说明辅助程序真的接管了
            let manual = SMC.shared.value("F0Md") == 1
            let target = manual ? SMC.shared.value("F0Tg") : nil
            let mode: String
            if client.config.strategy == .auto {
                mode = "系统自动"
            } else {
                mode = client.config.strategy.label + (manual ? "" : "（系统控制中）")
            }
            heroes[.fan] = HeroData(fraction: fan.map { ($0.current - $0.minimum) / max($0.maximum - $0.minimum, 1) },
                                    tone: .accent, value: text, unit: "RPM",
                                    rows: [("目标", target.map { "\(Int($0.rounded()))" } ?? "—"),
                                           ("区间", fan.map { "\(Int($0.minimum))–\(Int($0.maximum))" } ?? "—"),
                                           ("模式", mode)])
        }
        if shown == .fan || shown == .temperature {
            panel.fan = fan.map { FanData(current: $0.current, minimum: $0.minimum, maximum: $0.maximum) }
            panel.groups = groups
        }
        if windows.isOpen("settings") || windows.isOpen("curve"), tick % 2 == 0 { updateControlTemperatures() }
        updateHero()
    }

    private func updateHero() {
        guard let shownMetric else { return }
        panel.hero = heroes[shownMetric] ?? HeroData()
        // 走势范围：5 分钟（每次刷新一个点）/ 1 小时 / 24 小时（每分钟一个点）
        let series: (a: [Double], b: [Double]?)
        switch panel.historyRange {
        case 1: series = LongHistory.shared.recent("\(shownMetric)", minutes: 60)
        case 2: series = LongHistory.shared.recent("\(shownMetric)", minutes: 1440)
        default: series = history[shownMetric] ?? ([], nil)
        }
        panel.history = series.a
        panel.history2 = series.b
        if panel.historyRange == 0 {
            let seconds = Double(series.a.count) * Double(SpeedSetting.interval.selection + 1)
            panel.historyCaption = seconds >= 90 ? "最近 \(Int((seconds / 60).rounded())) 分钟" : "最近 \(Int(seconds)) 秒"
        } else {
            panel.historyCaption = series.a.count < 2 ? "积累中" : ""
        }
        let peak = (series.a + (series.b ?? [])).max() ?? 0
        panel.historyPeak = "峰值 " + Self.historyFormat(shownMetric, peak)
    }

    /// 记录一个历史点（最多 300 个：刷新间隔 1 秒时约 5 分钟）。
    private func record(_ metric: Metric, _ value: Double?, _ value2: Double? = nil) {
        guard let value else { return }
        var series = history[metric] ?? ([], value2 == nil ? nil : [])
        series.a = Array((series.a + [value]).suffix(300))
        if let value2 { series.b = Array(((series.b ?? []) + [value2]).suffix(300)) }
        history[metric] = series
        LongHistory.shared.add("\(metric)", value, value2)
        AlertCenter.shared.check(metric, value)
    }

    private static func historyFormat(_ metric: Metric, _ value: Double) -> String {
        switch metric {
        case .cpu, .gpu: return String(format: "%.0f%%", value)
        case .memory: return String(format: "%.1f GB", value)
        case .disk: return compactRate(value) + "/s"
        case .network: return Units.networkRate(value) + "/s"
        case .power: return String(format: "%.1f W", value)
        case .fan: return "\(Int(value)) 转"
        case .temperature: return "\(Int(Units.temperature(value).rounded()))\(Units.temperatureUnit)"
        }
    }

    /// 温度宫格、分组与探测点（风扇、温度面板）。
    private func updateThermal() {
        guard shownMetric == .fan || shownMetric == .temperature else { return }
        panel.groups = temperatures.read()
        panel.sensorCount = temperatures.sensorCount
        panel.details = panel.expanded && shownMetric == .temperature ? temperatures.details() : []
        if let fan = Fan.readAll().first {
            panel.fan = FanData(current: fan.current, minimum: fan.minimum, maximum: fan.maximum)
        }
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }

    /// 已用交换空间（字节）。
    private static func swapUsed() -> UInt64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        return sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 ? usage.xsu_used : nil
    }

    /// key 没变就不重绘，避免每秒都让菜单栏重新布局。
    /// 连续 5 秒以上不低于阈值才变红（CPU / GPU 90%，温度 95°），避免瞬时冲高时闪烁。
    private func sustainedLevel(_ metric: Metric, _ value: Double?, threshold: Double = 0.9) -> StatusIcons.Level {
        guard let value, value >= threshold else {
            hotSince[metric] = nil
            return .normal
        }
        let now = ProcessInfo.processInfo.systemUptime
        let since = hotSince[metric] ?? now
        hotSince[metric] = since
        return now - since >= 5 ? .critical : .normal
    }

    private func setIcon(_ metric: Metric, key: String, value: String, image: () -> NSImage) {
        guard renderRequest == nil else { return }
        accessibilityValues[metric] = value
        guard iconKeys[metric] != key else { return }
        iconKeys[metric] = key
        iconImages[metric] = image()
        updateIsland()
    }


    /// 自动模式：另一方超过当前方 1.5 倍（且至少 1KB/s）才切换，避免两者接近时来回跳。
    private func autoShowsUpload(_ rates: (upload: Double, download: Double)?) -> Bool {
        guard let rates else { return showingUpload }
        if max(rates.upload, rates.download) < 1_000 {
            showingUpload = false  // 空闲时默认显示下载
        } else if showingUpload {
            if rates.download > rates.upload * 1.5 + 1_000 { showingUpload = false }
        } else if rates.upload > rates.download * 1.5 + 1_000 {
            showingUpload = true
        }
        return showingUpload
    }

    private func display(upload: String, download: String, detail: String, rates: (upload: Double, download: Double)? = nil) {
        let (number, unit) = Self.splitRate(download)
        heroes[.network] = HeroData(fraction: lastRates.map { $0.download / peakDownload }, value: number, unit: unit.isEmpty ? "下载" : "\(unit)/s 下载",
                                    rows: [("上传", upload == "—" ? "—" : "\(upload)/s"),
                                           ("下载", download == "—" ? "—" : "\(download)/s"),
                                           ("网卡", interfaceLabel)])
        if shownMetric == .network { updateHero() }
        // 有效速率才算活动；"—"（等待数据）和 "0KB" 都显示为暗箭头
        let down = StatusIcons.RateRow(arrow: "↓", value: download, active: download != "—" && !download.hasPrefix("0K"))
        let up = StatusIcons.RateRow(arrow: "↑", value: upload, active: upload != "—" && !upload.hasPrefix("0K"))
        // 自动：只显示较快的一方；上传和下载：两列都显示
        let rows = SpeedSetting.direction.selection == 1 ? [up, down] : [autoShowsUpload(rates) ? up : down]
        let key = rows.map { "\($0.arrow)\($0.value)\($0.active)" }.joined(separator: "|")
        setIcon(.network, key: key, value: detail) { StatusIcons.network(rows) }
    }

    // MARK: - 格式化

    static func formatter(for metric: Metric) -> (Double) -> String {
        switch metric {
        case .network: return Units.networkRate
        case .disk: return compactRate
        case .cpu, .gpu: return { String(format: $0 >= 10 ? "%.0f%%" : "%.1f%%", $0) }
        case .memory: return memorySize
        case .power, .fan: return { String(format: $0 >= 10 ? "%.0f W" : "%.1f W", $0) }
        case .temperature: return { Units.degrees($0) }
        }
    }

    /// "1.6MB" → ("1.6", "MB")，用于主数据卡的大数字与单位。
    static func splitRate(_ text: String) -> (String, String) {
        guard let index = text.firstIndex(where: { $0.isLetter }) else { return (text, "") }
        return (String(text[..<index]), String(text[index...]))
    }

    /// 菜单栏上的功耗，如 "33W"、"4.2W"。
    static func compactWatts(_ watts: Double) -> String {
        String(format: watts >= 9.95 ? "%.0fW" : "%.1fW", watts)
    }

    static func percent(_ fraction: Double?) -> String {
        fraction.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
    }

    static func compactRate(_ bytes: Double) -> String {
        switch bytes {
        case 99_950_000...: return String(format: "%.0fMB", bytes / 1_000_000)
        case 999_500...: return String(format: "%.1fMB", bytes / 1_000_000)
        case 9_950...: return String(format: "%.0fKB", bytes / 1_000)
        case 50...: return String(format: "%.1fKB", bytes / 1_000)
        default: return "0KB"
        }
    }

    /// 面板中的进程内存，按活动监视器的二进制单位显示。
    static func memorySize(_ bytes: Double) -> String {
        let mib = bytes / 1_048_576
        return mib >= 1024 ? String(format: "%.2f GB", mib / 1024) : String(format: "%.0f MB", mib)
    }

    /// 菜单栏上的已用内存，如 "13.3G"（二进制单位，与活动监视器一致）。
    static func compactMemory(_ bytes: UInt64) -> String {
        let gib = Double(bytes) / 1_073_741_824
        return String(format: gib >= 99.95 ? "%.0fG" : "%.1fG", gib)
    }

    /// 磁盘容量，按访达的十进制单位显示。
    static func diskSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1e9
        return gb >= 1000 ? String(format: "%.2f TB", gb / 1000) : String(format: "%.0f GB", gb)
    }
}

// 更换应用标识后，首次启动时继承旧版设置。
let defaults = UserDefaults.standard
if let domain = Bundle.main.bundleIdentifier, domain == FanControl.clientIdentifier,
   defaults.persistentDomain(forName: domain)?["didMigratePreferences"] as? Bool != true {
    let previous = defaults.persistentDomain(forName: "local.codex.compact-speed-bar") ?? [:]
    var settings = defaults.persistentDomain(forName: domain) ?? [:]
    for (key, value) in previous {
        let migratedKey = key.replacingOccurrences(of: "SpeedBar.", with: "islet.")
        if settings[migratedKey] == nil { settings[migratedKey] = value }
    }
    settings["didMigratePreferences"] = true
    defaults.setPersistentDomain(settings, forName: domain)
}

let app = NSApplication.shared
let delegate = AppDelegate()
let launchArguments = CommandLine.arguments
RenderTargets.runIfRequested(launchArguments)
// 走查：--test-alert 只发一条示例低电量通知然后退出（和设置里的“发送测试通知”相同），不创建菜单栏图标
if launchArguments.count >= 2, launchArguments[1] == "--test-alert" {
    app.setActivationPolicy(.accessory)
    AlertCenter.shared.sendTest(device: (name: "BKB02_1", symbol: "keyboard", level: 18))
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
    app.run()
}
if launchArguments.count >= 4, launchArguments[1] == "--render" {
    delegate.renderRequest = (launchArguments[2], launchArguments[3],
                              !launchArguments.contains("light"), launchArguments.contains("expanded"))
}
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

extension AppDelegate: SpectrumHost {
    func embed(_ view: SpectrumBarsView?) {
        if view == nil { island.view.audio = nil }
        updateIsland()
    }
    func spectrumLayoutChanged() { updateIsland() }
}

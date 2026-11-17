import AppKit
import ApplicationServices
import Combine

/// 鼠标平滑滚动：把有刻度的滚轮事件拦下来，换成一串连续的小步滚动。
/// 拦截和平滑都在独立线程上跑：islet 的界面再忙，也不会让整台电脑的滚动变卡。
/// 触控板、Magic Mouse 等本来就连续的滚动不处理；按住 ⌘ / ⌃ / ⌥ 时原样放行（缩放等快捷操作不受影响）。
final class SmoothScrollController: ObservableObject {
    static let shared = SmoothScrollController()

    enum State: Equatable {
        case off, permissionRequired, pausedForMos, unavailable, active

        var description: String {
            switch self {
            case .off: return "让有刻度的鼠标滚轮像触控板一样顺滑"
            case .permissionRequired: return "需要辅助功能权限"
            case .pausedForMos: return "Mos 正在运行，退出 Mos 后自动启用"
            case .unavailable: return "未能开始，请重新检查辅助功能权限"
            case .active: return "已启用，触控板不受影响"
            }
        }
    }

    /// 每格滚动的距离。“中”与 Mos 默认一致。
    enum Distance: Int, CaseIterable {
        case short, medium, long
        var label: String { ["短", "中", "长"][rawValue] }
        var speed: Double { [1.6, 2.7, 4.2][rawValue] }
    }

    /// 平滑程度：越高，每格滚动拖得越长、越柔和。“中”与 Mos 默认一致。
    enum Smoothness: Int, CaseIterable {
        case low, medium, high
        var label: String { ["低", "中", "高"][rawValue] }
        var duration: Double { [2.6, 4.35, 6.5][rawValue] }
    }

    struct Options: Equatable {
        var distance = Distance.medium
        var smoothness = Smoothness.medium
        var reverse = false
    }

    private enum Key {
        static let enabled = "smoothMouseScroll"
        static let distance = "smoothScrollDistance"
        static let smoothness = "smoothScrollSmoothness"
        static let reverse = "smoothScrollReverse"
        static let legacyProfile = "mouseScrollSettings"   // 旧版的数值设置（默认反转了方向），不再使用
    }

    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: Key.enabled)
    @Published private(set) var state = State.off
    @Published private(set) var options: Options
    private let worker = ScrollWorker()

    private init() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Key.legacyProfile)
        options = Options(distance: (defaults.object(forKey: Key.distance) as? Int).flatMap(Distance.init) ?? .medium,
                          smoothness: (defaults.object(forKey: Key.smoothness) as? Int).flatMap(Smoothness.init) ?? .medium,
                          reverse: defaults.bool(forKey: Key.reverse))
        worker.apply(options)
    }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(environmentChanged(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(environmentChanged(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        // 用户在系统设置里刚授权回来：切回 islet 时重新检查
        NotificationCenter.default.addObserver(self, selector: #selector(recheck), name: NSApplication.didBecomeActiveNotification, object: nil)
        reconcile()
    }

    func stop() { worker.uninstall() }

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: Key.enabled)
        if on, !AXIsProcessTrusted() { openPermissionSettings() }
        reconcile()
    }

    func setDistance(_ value: Distance) { update { $0.distance = value }; UserDefaults.standard.set(value.rawValue, forKey: Key.distance) }
    func setSmoothness(_ value: Smoothness) { update { $0.smoothness = value }; UserDefaults.standard.set(value.rawValue, forKey: Key.smoothness) }
    func setReverse(_ value: Bool) { update { $0.reverse = value }; UserDefaults.standard.set(value, forKey: Key.reverse) }

    private func update(_ change: (inout Options) -> Void) {
        change(&options)
        worker.apply(options)
    }

    func openPermissionSettings() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        if !AXIsProcessTrustedWithOptions([key: true] as CFDictionary),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func environmentChanged(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier?.lowercased() == Self.mosBundle else { return }
        reconcile()
    }

    @objc private func recheck() { reconcile() }

    private static let mosBundle = "com.caldis.mos"

    private func reconcile() {
        let next: State
        if !enabled {
            next = .off
        } else if NSWorkspace.shared.runningApplications.contains(where: { !$0.isTerminated && $0.bundleIdentifier?.lowercased() == Self.mosBundle }) {
            next = .pausedForMos     // 两个程序同时平滑会叠加成双倍距离
        } else if !AXIsProcessTrusted() {
            next = .permissionRequired
        } else {
            next = worker.install() ? .active : .unavailable
        }
        if next != .active { worker.uninstall() }
        if state != next { state = next }
    }
}

/// 在独立线程的运行循环里拦截滚轮事件、按时间分段发出平滑后的滚动。所有状态只在这条线程上读写。
private final class ScrollWorker {
    private var loop: CFRunLoop?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: CFRunLoopTimer?

    private struct Tuning { var step = 33.6, speed = 2.7, duration = 4.35, reverse = false }
    private var tuning = Tuning()

    private struct Pulse {
        let started: TimeInterval
        var x: Double
        var y: Double
        var progress: Double = 0
    }

    private struct Scroll {
        var target: pid_t
        var flags: CGEventFlags
        var pulses: [Pulse] = []
        var xCarry: Double = 0
        var yCarry: Double = 0
    }
    private var pending: Scroll?

    /// 自己发出的事件打上记号，拦截时放行，避免再被平滑一次。
    private static let marker: Int64 = 0x4953_4C45_5453_4352

    init() {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            self?.loop = CFRunLoopGetCurrent()
            // 运行循环里没有任何来源时会立刻退出：放一个永不触发的定时器让它一直等着
            let keepAlive = CFRunLoopTimerCreateWithHandler(nil, 1e12, 0, 0, 0) { _ in }
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), keepAlive, .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "islet.smoothScroll"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    /// 在工作线程上执行，并等它执行完（只用于开关这种很快的操作）。
    private func sync<T>(_ work: @escaping () -> T) -> T {
        guard let loop else { return work() }
        var result: T!
        let done = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { result = work(); done.signal() }
        CFRunLoopWakeUp(loop)
        done.wait()
        return result
    }

    func apply(_ options: SmoothScrollController.Options) {
        let next = Tuning(step: 33.6, speed: options.distance.speed, duration: options.smoothness.duration, reverse: options.reverse)
        sync { self.tuning = next; self.clear() }
    }

    func install() -> Bool { sync { self.installTap() } }
    func uninstall() { sync { self.removeTap() } }

    private func installTap() -> Bool {
        if let tap, CFMachPortIsValid(tap) { return true }
        removeTap()
        let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let worker = Unmanaged<ScrollWorker>.fromOpaque(context).takeUnretainedValue()
                return worker.handle(type, event: event) ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return false }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func removeTap() {
        clear()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }

    /// 返回 true 表示原始滚轮事件由平滑事件接替（吞掉原事件）。
    private func handle(_ type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard type == .scrollWheel, event.getIntegerValueField(.eventSourceUserData) != Self.marker else { return false }
        // 触控板、Magic Mouse（连续滚动、带阶段）和按住修饰键的滚动原样放行
        if event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            || event.getIntegerValueField(.scrollWheelEventScrollPhase) != 0
            || event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0
            || !event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty {
            clear()
            return false
        }
        func distance(_ point: CGEventField, _ line: CGEventField) -> Double {
            let pixels = event.getDoubleValueField(point)
            let value = pixels != 0 ? pixels : Double(event.getIntegerValueField(line)) * 10
            guard value.isFinite, value != 0 else { return 0 }
            let direction = (value < 0) == tuning.reverse ? 1.0 : -1.0
            return direction * max(tuning.step, abs(value)) * tuning.speed
        }
        let x = distance(.scrollWheelEventPointDeltaAxis2, .scrollWheelEventDeltaAxis2)
        let y = distance(.scrollWheelEventPointDeltaAxis1, .scrollWheelEventDeltaAxis1)
        let target = pid_t(clamping: event.getIntegerValueField(.eventTargetUnixProcessID))
        guard x != 0 || y != 0, target > 0 else { return false }
        if let scroll = pending, scroll.target != target || scroll.flags != event.flags { clear() }
        var scroll = pending ?? Scroll(target: target, flags: event.flags)
        // 快速反向：只取消对应轴还没发出的位移，另一个轴照常滚动
        if x != 0, scroll.pulses.contains(where: { $0.x * x < 0 }) {
            for index in scroll.pulses.indices { scroll.pulses[index].x = 0 }
            scroll.xCarry = 0
        }
        if y != 0, scroll.pulses.contains(where: { $0.y * y < 0 }) {
            for index in scroll.pulses.indices { scroll.pulses[index].y = 0 }
            scroll.yCarry = 0
        }
        scroll.pulses.append(Pulse(started: ProcessInfo.processInfo.systemUptime, x: x, y: y))
        pending = scroll
        if timer == nil {
            let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent(), 1.0 / 120, 0, 0) { [weak self] _ in self?.tick() }
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
            self.timer = timer
        }
        return true
    }

    private func tick() {
        guard var scroll = pending else { clear(); return }
        let now = ProcessInfo.processInfo.systemUptime
        let timeScale = max(0.028, tuning.duration * 0.011)
        for index in scroll.pulses.indices {
            let t = max(0, now - scroll.pulses[index].started) / timeScale
            // 三阶响应：每格滚动先加速再减速；连续滚动时各格自然叠加
            let progress = t >= 9 ? 1 : 1 - exp(-t) * (1 + t + t * t / 2)
            let delta = progress - scroll.pulses[index].progress
            scroll.xCarry += scroll.pulses[index].x * delta
            scroll.yCarry += scroll.pulses[index].y * delta
            scroll.pulses[index].progress = progress
        }
        scroll.pulses.removeAll { $0.progress >= 1 }
        let done = scroll.pulses.isEmpty
        let x = Int32(clamping: Int(scroll.xCarry.rounded(done ? .toNearestOrAwayFromZero : .towardZero)))
        let y = Int32(clamping: Int(scroll.yCarry.rounded(done ? .toNearestOrAwayFromZero : .towardZero)))
        if x != 0 || y != 0 { post(scroll, x: x, y: y) }
        scroll.xCarry -= Double(x)
        scroll.yCarry -= Double(y)
        if done { clear() } else { pending = scroll }
    }

    private func clear() {
        pending = nil
        if let timer { CFRunLoopTimerInvalidate(timer) }
        timer = nil
    }

    private func post(_ scroll: Scroll, x: Int32, y: Int32) {
        guard let cursor = CGEvent(source: nil)?.location,
              let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0) else { return }
        event.location = cursor   // 跟随当前指针，不把光标拉回滚动开始的位置
        event.flags = scroll.flags
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        event.post(tap: .cgSessionEventTap)
    }
}

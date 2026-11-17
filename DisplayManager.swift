import AppKit
import Combine
import IOKit.graphics

/// 显示器：列出每块屏的可用分辨率，切换分辨率、为外接屏添加 HiDPI 档位。
/// 真正改系统设置的操作都交给辅助程序 islet-display（见 tools/display-helper.swift）。
final class DisplayManager: ObservableObject {
    static let shared = DisplayManager()

    struct Mode: Identifiable, Equatable {
        let id: Int32
        let width: Int
        let height: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let hz: Double
        let native: Bool
        let preferred: Bool
        let stretched: Bool

        init(_ mode: CGDisplayMode) {
            id = mode.ioDisplayModeID
            width = mode.width
            height = mode.height
            pixelWidth = mode.pixelWidth
            pixelHeight = mode.pixelHeight
            hz = mode.refreshRate
            native = mode.ioFlags & UInt32(kDisplayModeNativeFlag) != 0
            preferred = mode.ioFlags & UInt32(kDisplayModeDefaultFlag) != 0
            stretched = mode.ioFlags & UInt32(kDisplayModeStretchedFlag) != 0
        }

        var hiDPI: Bool { pixelWidth >= width * 2 && pixelHeight >= height * 2 }
        var size: String { "\(width)×\(height)" }
        var renderingSize: String { "\(pixelWidth)×\(pixelHeight)" }
        /// 同一尺寸、同一清晰度算一档（不同刷新率合并）。
        var group: String { "\(size):\(hiDPI)" }
        var rate: String { hz > 0 ? String(format: "%g Hz", (hz * 100).rounded() / 100) : "" }
    }

    struct Display: Identifiable {
        let id: CGDirectDisplayID
        let name: String
        let builtIn: Bool
        let current: Mode
        let modes: [Mode]
        let native: Mode?
        let isMain: Bool
        let mirrored: Bool
        let active: Bool
        /// 屏幕物理宽度（毫米），读不到时为 0。
        let widthMM: Double

        var canSwitch: Bool { active && !mirrored }

        /// 下拉里的档位：与屏幕同宽高比、不拉伸的分辨率，每档取最接近当前刷新率的那个；当前模式总在里面。
        var choices: [Mode] {
            guard let native, native.height > 0 else { return [current] }
            let ratio = Double(native.width) / Double(native.height)
            var best: [String: Mode] = [:]
            for mode in modes where !mode.stretched && mode.height > 0
                && abs(Double(mode.width) / Double(mode.height) / ratio - 1) <= 0.01
                && (mode.hiDPI || mode.native) {   // 只列 HiDPI 档位和原生分辨率，低分辨率的普通档位看起来发虚，不列
                if let existing = best[mode.group], abs(existing.hz - current.hz) <= abs(mode.hz - current.hz) { continue }
                best[mode.group] = mode
            }
            best[current.group] = current
            return best.values.sorted { ($0.width, $0.hiDPI ? 1 : 0) > ($1.width, $1.hiDPI ? 1 : 0) }
        }

        /// 有没有实用的 HiDPI 档位：比原生一半更大的那些。
        /// 2K、带鱼屏通常只有“原生的一半”这一档 HiDPI（东西大得没法用），这种算没有，可以添加。
        var hasHiDPIChoices: Bool {
            guard let native else { return choices.contains(where: \.hiDPI) }
            return choices.contains { $0.hiDPI && $0.width > native.width / 2 + 8 }
        }

        /// 推荐的大小，规则固定：
        /// 1. 系统给某个 HiDPI 档位标了默认（Mac 内建屏、多数 4K 屏），就用它；
        /// 2. 否则按屏幕物理宽度，选最接近每英寸 90 点的 HiDPI 档位（约等于 24 寸 1080p 屏原生的文字大小，桌面距离下读起来舒服）；
        /// 3. 读不到物理尺寸时，取最宽的 HiDPI 档位。
        var recommended: Mode? {
            let hiDPI = choices.filter(\.hiDPI)
            if let preferred = hiDPI.first(where: \.preferred) { return preferred }
            guard widthMM > 0 else { return hiDPI.max { $0.width < $1.width } }
            let target = widthMM / 25.4 * 90
            return hiDPI.min { abs(Double($0.width) - target) < abs(Double($1.width) - target) }
        }

        /// 全部可选的文字大小：原生在最前，往后文字越来越大。
        var allSizes: [Mode] {
            choices.sorted { ($0.width, $0.hiDPI ? 0 : 1) > ($1.width, $1.hiDPI ? 0 : 1) }
        }

        /// 默认展示的核心档位，最多 5 个：原生、推荐、当前必留，其余挑紧挨着推荐的。
        var sizeOptions: [Mode] {
            let all = allSizes
            let limit = 5
            guard all.count > limit else { return all }
            var keep = Set<Int>()
            for mode in [native, recommended, current].compactMap({ $0 }) {
                if let index = all.firstIndex(where: { $0.group == mode.group }) { keep.insert(index) }
            }
            let center = all.firstIndex { $0.group == recommended?.group } ?? all.count / 2
            // 放大不超过 200% 的优先（再小就是把画面拉大显示，发虚），其次离推荐最近，距离相同先取“更多空间”一侧
            let half = (native?.width ?? 0) / 2 - 8
            let key = { (i: Int) in (all[i].width < half ? 1 : 0, abs(i - center), i) }
            let near = all.indices.sorted { key($0) < key($1) }
            for index in near where keep.count < limit { keep.insert(index) }
            return keep.sorted().map { all[$0] }
        }

        /// 档位的文字说明：原生、推荐（系统默认时叫“默认”），其余按比推荐大还是小。
        func label(_ mode: Mode) -> String {
            if mode.group == recommended?.group { return mode.preferred ? "默认" : "推荐" }
            if mode.native && !mode.hiDPI { return "原生" }
            guard let recommended else { return "" }
            return mode.width > recommended.width ? "更多空间" : "更大文字"
        }

        /// 界面相对原生放大多少，例如 “125%”。
        func scale(_ mode: Mode) -> String {
            guard let native, mode.width > 0 else { return "" }
            return String(format: "%g%%", (Double(native.width) / Double(mode.width) * 1000).rounded() / 10)
        }
    }

    @Published private(set) var displays: [Display] = []
    /// 各块屏的覆盖配置状态（来自辅助程序）。
    @Published private(set) var overrides: [CGDirectDisplayID: OverrideStatus] = [:]
    @Published private(set) var busy = false
    /// 设置里展开了“更多分辨率”的屏幕
    @Published private(set) var expanded: Set<CGDirectDisplayID> = []

    func toggleExpanded(_ id: CGDirectDisplayID) {
        if expanded.remove(id) == nil { expanded.insert(id) }
    }
    func collapseAll() { expanded = [] }
    @Published private(set) var message: String?

    struct OverrideStatus: Decodable {
        let external: Bool
        let installed: Bool
        let owned: Bool
        let sizes: [String]
    }

    private var helper: URL? { Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("islet-display") }
    private var decision: FileHandle?
    private var confirmation: NSAlert?

    private init() {}

    func refresh() {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return }
        let names = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, String)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (number.uint32Value, screen.localizedName)
        })
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        displays = ids.prefix(Int(count)).compactMap { id in
            guard let active = CGDisplayCopyDisplayMode(id) else { return nil }
            let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? [])
                .filter { $0.isUsableForDesktopGUI() }.map(Mode.init)
            let native = modes.filter { $0.native && !$0.hiDPI }.max { $0.width * $0.height < $1.width * $1.height }
                ?? modes.filter { !$0.hiDPI }.max { $0.width * $0.height < $1.width * $1.height }
            return Display(id: id, name: names[id] ?? "显示器", builtIn: CGDisplayIsBuiltin(id) != 0,
                           current: Mode(active), modes: modes, native: native,
                           isMain: CGDisplayIsMain(id) != 0, mirrored: CGDisplayIsInMirrorSet(id) != 0,
                           active: CGDisplayIsActive(id) != 0, widthMM: Double(CGDisplayScreenSize(id).width))
        }.sorted { $0.isMain != $1.isMain ? $0.isMain : $0.id < $1.id }
        refreshOverrides()
    }

    /// 读外接屏的覆盖配置状态（辅助程序很快，放后台读）。
    private func refreshOverrides() {
        guard let helper else { return }
        let ids = displays.filter { !$0.builtIn }.map(\.id)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var result: [CGDirectDisplayID: OverrideStatus] = [:]
            for id in ids {
                let (code, data) = Self.run(helper, ["status", String(id)])
                if code == 0, let status = try? JSONDecoder().decode(OverrideStatus.self, from: data) { result[id] = status }
            }
            DispatchQueue.main.async { self?.overrides = result }
        }
    }

    private static func run(_ helper: URL, _ arguments: [String]) -> (Int32, Data) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = helper
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (1, Data(error.localizedDescription.utf8)) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }

    // MARK: 添加 / 移除 HiDPI 档位

    /// 添加后需要重新连接这块屏，新档位才会出现：有另一块屏在用时自动用软件重连，否则提示手动插拔。
    /// 新档位出现后自动切到推荐的大小（同样 15 秒内确认才保留）。
    func addHiDPI(_ display: Display) {
        pendingRecommend = display.id
        perform(["install"], then: ["reconnect"], on: display)
    }
    func removeHiDPI(_ display: Display) {
        pendingRecommend = nil
        perform(["remove"], then: ["reconnect"], on: display)
    }

    /// 开启 HiDPI 后等新档位出现，切到推荐大小。重连要一两秒，最多等几秒；要手动插拔的情况就不自动切了。
    private var pendingRecommend: CGDirectDisplayID?

    private func applyRecommendation(attempts: Int) {
        guard let id = pendingRecommend, !busy else { return }
        if let display = displays.first(where: { $0.id == id }), display.hasHiDPIChoices, let mode = display.recommended {
            pendingRecommend = nil
            if mode.group != display.current.group { choose(mode, on: display) }
        } else if attempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.refresh()
                self?.applyRecommendation(attempts: attempts - 1)
            }
        } else {
            pendingRecommend = nil
        }
    }

    private func perform(_ command: [String], then follow: [String], on display: Display) {
        guard !busy, let helper else { return }
        busy = true
        message = nil
        let id = String(display.id)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var (code, data) = Self.run(helper, command + [id])
            var text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let succeeded = code == 0
            if code == 0 {
                (code, data) = Self.run(helper, follow + [id])
                let follow = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                text = code == 0 ? text : "\(text)。\(follow)"
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                // 成功不提示（开关状态已经说明了），只留失败或需要手动插拔的说明
                self.message = code == 0 || text.isEmpty ? nil : text
                self.refresh()
                if succeeded { self.applyRecommendation(attempts: 6) } else { self.pendingRecommend = nil }
            }
        }
    }

    // MARK: 切换分辨率（先临时生效，15 秒内确认才保留）

    func choose(_ mode: Mode, on display: Display) {
        guard !busy, display.canSwitch, mode.id != display.current.id, let helper else { return }
        let decision = Pipe()
        // 用户恰好在超时那一刻点按钮：写端不能让 SIGPIPE 结束 islet
        _ = fcntl(decision.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let output = Pipe()
        let process = Process()
        process.executableURL = helper
        process.arguments = ["mode", String(display.id), String(mode.id)]
        process.standardInput = decision
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch { message = error.localizedDescription; return }
        self.decision = decision.fileHandleForWriting
        busy = true
        message = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ready = Data("READY\n".utf8)
            let reader = output.fileHandleForReading
            let prefix = reader.readData(ofLength: ready.count)
            if prefix == ready { DispatchQueue.main.async { self?.askToKeep() } }
            let rest = reader.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: (prefix == ready ? Data() : prefix) + rest, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init)
            DispatchQueue.main.async {
                guard let self else { return }
                self.decision = nil
                if let alert = self.confirmation {
                    self.confirmation = nil
                    if let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .abort) } else { NSApp.abortModal() }
                }
                self.busy = false
                // 切换成功不用提示（选中的档位已经变了），只留失败和自动恢复的说明
                self.message = process.terminationStatus == 0 && text == "已切换" ? nil : text
                self.refresh()
            }
        }
    }

    private func askToKeep() {
        guard decision != nil else { return }
        let alert = NSAlert()
        alert.messageText = "保留这个分辨率？"
        // 倒计时与辅助程序的 15 秒超时对应；画面若黑屏看不到弹窗，到时也会自动恢复
        var remaining = 15
        let text = { "\(remaining) 秒后自动恢复原来的分辨率。" }
        alert.informativeText = text()
        alert.addButton(withTitle: "保留")
        alert.addButton(withTitle: "恢复")
        confirmation = alert
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self, weak alert] timer in
            guard let alert, self?.confirmation === alert, remaining > 1 else { timer.invalidate(); return }
            remaining -= 1
            alert.informativeText = text()
        }
        RunLoop.main.add(timer, forMode: .common)   // 独立弹窗是模态运行，普通模式的计时器不走
        // 从右键菜单切换时设置窗口没开：弹独立的对话框
        guard let window = NSApp.windows.first(where: { $0.title == "islet 设置" && $0.isVisible }) else {
            NSApp.activate()
            let response = alert.runModal()
            guard confirmation === alert else { return }   // 已超时恢复
            confirmation = nil
            answer(response == .alertFirstButtonReturn)
            return
        }
        window.makeKeyAndOrderFront(nil)
        alert.beginSheetModal(for: window) { [weak self, weak alert] response in
            guard let self, let alert, self.confirmation === alert else { return }
            self.confirmation = nil
            self.answer(response == .alertFirstButtonReturn)
        }
    }

    private func answer(_ keep: Bool) {
        guard let decision else { return }
        try? decision.write(contentsOf: Data((keep ? "yes\n" : "no\n").utf8))
        try? decision.close()
        self.decision = nil
    }
}

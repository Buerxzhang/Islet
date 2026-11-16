import AppKit
import AVFoundation

// 动态壁纸：系统的动态壁纸在桌面上只播放片刻就停（为省电的设计，没有公开开关），
// 这里由程序自己在桌面层播放同样的视频（系统已下载到本机的航拍视频）。
// 视频层位于系统壁纸之上、桌面图标之下，鼠标直接穿透，不影响图标和点击。

/// 本机已下载的系统动态壁纸视频。
struct AerialVideo: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
}

enum Aerials {
    static var videosDirectory: URL { root.appendingPathComponent("videos") }

    private static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials")
    }

    /// 本机有视频文件的条目，按名称排序。名称取系统字符串表中的简体中文。
    static func list() -> [AerialVideo] {
        let manifest = root.appendingPathComponent("manifest")
        guard let data = try? Data(contentsOf: manifest.appendingPathComponent("entries.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [[String: Any]] else { return [] }
        let strings = localizedStrings(manifest.appendingPathComponent("TVIdleScreenStrings.bundle"))
        var seen = Set<String>()
        return assets.compactMap { asset -> AerialVideo? in
            guard let id = asset["id"] as? String else { return nil }
            let url = root.appendingPathComponent("videos/\(id).mov")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let key = asset["localizedNameKey"] as? String ?? ""
            var name = strings[key] ?? asset["accessibilityLabel"] as? String ?? id
            // 同名的（如“macOS”浅色 / 深色多段）加序号区分
            var index = 2
            let base = name
            while seen.contains(name) { name = "\(base) \(index)"; index += 1 }
            seen.insert(name)
            return AerialVideo(id: id, name: name, url: url)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 系统设置里当前选中的桌面动态壁纸（编号）；选的不是动态壁纸时为 nil。
    static func systemChoice() -> String? {
        let index = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        guard let data = try? Data(contentsOf: index),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let all = plist["AllSpacesAndDisplays"] as? [String: Any],
              let desktop = all["Desktop"] as? [String: Any],
              let content = desktop["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]],
              let choice = choices.first, choice["Provider"] as? String == "com.apple.wallpaper.choice.aerials",
              let configuration = choice["Configuration"] as? Data,
              let decoded = try? PropertyListSerialization.propertyList(from: configuration, format: nil) as? [String: Any]
        else { return nil }
        return decoded["assetID"] as? String
    }

    /// 名称表是一个汇总的 .loctable（各语言放在同一个属性列表里），取简体中文，没有则取英文。
    private static func localizedStrings(_ bundle: URL) -> [String: String] {
        let table = bundle.appendingPathComponent("Contents/Resources/Localizable.nocache.loctable")
        guard let data = try? Data(contentsOf: table),
              let all = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [:] }
        for language in ["zh_CN", "zh-Hans", "zh_Hans", "en"] {
            if let strings = all[language] as? [String: String] { return strings }
        }
        return [:]
    }
}

/// 播放策略。
enum WallpaperMode: Int, CaseIterable {
    case off, desktopOnly, always

    var label: String { ["关闭", "仅纯桌面时", "始终播放"][rawValue] }

    static var current: WallpaperMode {
        WallpaperMode(rawValue: UserDefaults.standard.object(forKey: "wallpaperMode") as? Int ?? 1) ?? .desktopOnly
    }
}

final class WallpaperController: ObservableObject {
    static let shared = WallpaperController()

    @Published private(set) var mode = WallpaperMode.current
    /// 选中的视频编号；nil 表示跟随系统设置里的选择。
    @Published private(set) var videoID = UserDefaults.standard.string(forKey: "wallpaperVideo")
    @Published private(set) var status = "未启用"
    @Published private(set) var videos: [AerialVideo] = []

    private var windows: [NSWindow] = []
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var loadedURL: URL?
    private var playing = false
    private var suspended = false        // 锁屏、屏幕关闭、切换用户
    private var timer: Timer?
    private var syncTimer: Timer?
    private var lastSystemChoice: String?
    private var lastVideoCount = 0

    private init() {
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false  // 壁纸不该阻止屏幕休眠
    }

    /// 当前要播放的视频：用户指定的；“跟随系统”时为系统设置里选的那段。
    /// 跟随系统而系统选的是静态图片、或视频还没下载完时为 nil——此时不播放，直接显示系统壁纸。
    var effectiveVideo: AerialVideo? {
        if let videoID { return videos.first { $0.id == videoID } }
        guard let choice = Aerials.systemChoice() else { return nil }
        return videos.first { $0.id == choice }
    }

    var systemChoiceName: String? {
        Aerials.systemChoice().flatMap { id in videos.first { $0.id == id }?.name }
    }

    func start() {
        videos = Aerials.list()
        lastSystemChoice = Aerials.systemChoice()
        lastVideoCount = videos.count
        // 系统设置里换了壁纸、或新下载了视频，都没有通知可监听：每 5 秒读一次（约 1 毫秒）
        let sync = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.syncWithSystem() }
        sync.tolerance = 1
        RunLoop.main.add(sync, forMode: .common)
        syncTimer = sync
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(evaluate), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(evaluate), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(suspend), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(suspend), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(suspend), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(resume), name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(resume), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(suspend), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        distributed.addObserver(self, selector: #selector(resume), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        apply()
    }

    /// 系统选择或本地视频有变化时，重新读取列表并切换。
    private func syncWithSystem() {
        let choice = Aerials.systemChoice()
        let count = (try? FileManager.default.contentsOfDirectory(atPath: Aerials.videosDirectory.path))?
            .filter { $0.hasSuffix(".mov") }.count ?? 0
        guard choice != lastSystemChoice || count != lastVideoCount else { return }
        lastSystemChoice = choice
        lastVideoCount = count
        videos = Aerials.list()
        apply()
    }

    func setMode(_ mode: WallpaperMode) {
        self.mode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "wallpaperMode")
        apply()
    }

    /// nil：跟随系统设置。
    func setVideo(_ id: String?) {
        videoID = id
        UserDefaults.standard.set(id, forKey: "wallpaperVideo")
        apply()
    }

    /// 根据模式建立或拆除视频层，并开始评估播放条件。
    func apply() {
        timer?.invalidate()
        timer = nil
        guard mode != .off, let video = effectiveVideo else {
            tearDown()
            if mode == .off {
                status = "未启用"
            } else if videoID == nil {
                status = Aerials.systemChoice() == nil
                    ? "系统壁纸不是动态壁纸，显示系统壁纸"
                    : "系统选的动态壁纸还没下载完，下载后自动播放"
            } else {
                status = "选的视频已不在本机"
            }
            return
        }
        // 直接播放原片（4K、每秒 240 帧）：播放时约占 GPU 一半、CPU 两成，台式机上可以接受
        if loadedURL != video.url {
            let item = AVPlayerItem(url: video.url)
            looper = AVPlayerLooper(player: player, templateItem: item)  // 无缝循环
            loadedURL = video.url
        }
        if windows.isEmpty { buildWindows() }
        if mode == .desktopOnly {
            // 关闭窗口、最小化等没有系统通知，每 2 秒补查一次（约 1 毫秒）
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.evaluate() }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        evaluate()
    }

    private func buildWindows() {
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            // 系统壁纸之上、桌面图标之下
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            window.ignoresMouseEvents = true
            window.isOpaque = true
            window.hasShadow = false
            window.backgroundColor = .black
            window.isReleasedWhenClosed = false
            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            view.layer?.addSublayer(layer)
            window.contentView = view
            window.setFrame(screen.frame, display: false)
            window.alphaValue = 0
            window.orderFront(nil)
            windows.append(window)
        }
    }

    private func tearDown() {
        player.pause()
        playing = false
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        looper = nil
        player.removeAllItems()
        loadedURL = nil
    }

    @objc private func screensChanged() {
        guard mode != .off else { return }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        apply()
    }

    @objc private func suspend() {
        suspended = true
        windows.forEach { $0.alphaValue = 0 }  // 解锁回来时淡入
        evaluate()
    }

    @objc private func resume() {
        suspended = false
        evaluate()
    }

    /// 按当前状况决定播放还是暂停。
    @objc func evaluate() {
        guard mode != .off, !windows.isEmpty else { return }
        let reason: String?
        if suspended {
            reason = "已暂停：锁屏或屏幕关闭"
        } else if mode == .desktopOnly, !Self.desktopIsFocused() {
            reason = "已暂停：其他程序在前台"
        } else {
            reason = nil
        }
        if let reason {
            if playing { player.pause() }
            playing = false
            status = reason
        } else {
            if !playing {
                player.play()
                playing = true
                // 恢复时淡入：解锁等场景下画面位置会与锁屏不同，淡入比直接跳变自然
                for window in windows where window.alphaValue < 1 {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.6
                        window.animator().alphaValue = 1
                    }
                }
            }
            status = "正在播放：\(effectiveVideo?.name ?? "")"
        }
    }

    /// 纯桌面：前台程序是访达（点了桌面），或屏幕上没有任何普通窗口（都最小化 / 隐藏了）。
    static func desktopIsFocused() -> Bool {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" {
            // 访达在前台且有打开的访达窗口时，算“在用访达”，不算纯桌面
            return !hasVisibleWindows(ownedBy: "com.apple.finder")
        }
        return !hasVisibleWindows(ownedBy: nil)
    }

    /// 屏幕上是否有普通窗口（层级 0、足够大、可见）。ownedBy 为 nil 时统计除本程序外的所有程序。
    private static func hasVisibleWindows(ownedBy bundleID: String?) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let targetPID = bundleID.flatMap { id in NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.processIdentifier }
        return list.contains { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  (bounds["Width"] ?? 0) > 120, (bounds["Height"] ?? 0) > 120 else { return false }
            if let targetPID { return pid == targetPID }
            return true
        }
    }
}

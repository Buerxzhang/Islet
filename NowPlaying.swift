import AppKit
import Combine

/// 正在播放的信息（来自 NowPlaying/adapter.m，由系统 perl 托管的读取组件推送）。
struct NowPlayingInfo {
    var title = ""
    var artist = ""
    var album = ""
    var duration: Double?
    var elapsed: Double?
    var rate: Double = 1
    var timestamp: Double?
    var playing = false
    var bundle: String?
    var mediaType: String?
    var artwork: NSImage?
    var tint: NSColor?          // 封面主色；视频、拿不到封面、黑白封面时为 nil（显示白色）
    var commands: Set<Int>?     // 应用支持的命令编号（系统报告）；nil 表示没报告

    /// 显示上一首 / 下一首：以应用报告的支持命令为准（语音消息、网页视频等只支持播放暂停）；
    /// 没报告时按老规则，视频不显示。
    var canSkip: Bool {
        if let commands { return commands.contains(NowPlayingMonitor.Command.next.rawValue) || commands.contains(NowPlayingMonitor.Command.previous.rawValue) }
        return !isVideo
    }

    /// 视频播放器或标记为视频的内容：不取封面颜色。
    var isVideo: Bool {
        if mediaType?.localizedCaseInsensitiveContains("video") == true { return true }
        let videoApps = ["com.bilibili", "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox", "com.microsoft.edgemac",
                         "com.colliderli.iina", "org.videolan.vlc", "com.apple.QuickTimePlayerX", "com.apple.TV", "com.firecore.infuse"]
        return bundle.map { id in videoApps.contains { id.hasPrefix($0) } } ?? false
    }

    /// 当前进度（秒），播放中按时间戳推算。
    func position(at date: Date = Date()) -> Double? {
        guard let elapsed else { return nil }
        guard playing, let timestamp else { return elapsed }
        let value = elapsed + (date.timeIntervalSince1970 - timestamp) * rate
        return duration.map { min(value, $0) } ?? value
    }
}

final class NowPlayingMonitor: ObservableObject {
    static let shared = NowPlayingMonitor()

    enum Command: Int {
        case pause = 1, togglePlayPause = 2, next = 4, previous = 5
        case openApp = -1   // 不是系统命令：打开正在播放的应用
    }

    @Published private(set) var info: NowPlayingInfo?
    /// 出现过的音乐播放器：它们发声时按音乐处理，不当作“其他程序”。
    static var musicPlayers: Set<String> = ["com.netease.163music", "com.apple.Music", "com.spotify.client", "com.tencent.QQMusicMac",
                                            "com.kugou.mac.kugouMusic", "com.kuwo.mac.KwMusic", "com.apple.podcasts"]

    private var process: Process?
    private var buffer = Data()
    private var running = false
    private var artworkCache: (id: String, image: NSImage, tint: NSColor?)?
    private var artworkPendingSince: Date?   // 切歌后新封面还没到的时刻
    private var clearWork: DispatchWorkItem?
    private var pauseWork: DispatchWorkItem?
    private var pausedSince: Date?                 // 播放器开始报告“暂停”的时刻
    private var userPausedAt = Date.distantPast   // 刚用我们的按钮暂停：立即显示，不做防抖

    private static let script = """
    use DynaLoader; my $l = DynaLoader::dl_load_file($ARGV[0], 0) or exit 1; \
    my $f = DynaLoader::dl_find_symbol($l, $ARGV[1]) or exit 1; \
    DynaLoader::dl_install_xsub("main::run", $f); run();
    """

    private var adapterPath: String? { Bundle.main.path(forResource: "NowPlayingAdapter", ofType: "dylib") }

    func start() {
        guard !running else { return }
        running = true
        launch()
    }

    func stop() {
        running = false
        process?.terminate()
        process = nil
        clearWork?.cancel()
        info = nil
    }


    /// 媒体控制：起一个短命的 perl 进程发送命令。
    func send(_ command: Command) {
        guard command.rawValue >= 0, let adapterPath else { return }
        if command == .togglePlayPause, info?.playing == true { userPausedAt = Date() }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        task.arguments = ["-e", Self.script, adapterPath, "adapter_command"]
        task.environment = ["NP_COMMAND": String(command.rawValue)]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
    }

    private func launch() {
        guard running, let adapterPath else { return }
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        task.arguments = ["-e", Self.script, adapterPath, "adapter_stream"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                // 意外退出：5 秒后重启
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.launch() }
            }
        }
        do {
            try task.run()
            process = task
        } catch {
            NSLog("正在播放读取组件启动失败：%@", error.localizedDescription)
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            apply(object)
        }
    }

    private func apply(_ object: [String: Any]) {
        var next = NowPlayingInfo()
        next.title = object["title"] as? String ?? ""
        next.artist = object["artist"] as? String ?? ""
        next.album = object["album"] as? String ?? ""
        next.duration = (object["duration"] as? NSNumber)?.doubleValue
        next.elapsed = (object["elapsed"] as? NSNumber)?.doubleValue
        next.rate = (object["rate"] as? NSNumber)?.doubleValue ?? 1
        next.timestamp = (object["timestamp"] as? NSNumber)?.doubleValue
        // 有的播放器（如网易云）切换时“是否在播放”会报错，进度在走（rate > 0）也算在播放
        next.playing = (object["playing"] as? NSNumber)?.boolValue == true || next.rate > 0 && object["rate"] != nil
        next.bundle = object["bundle"] as? String
        next.mediaType = object["mediaType"] as? String
        next.commands = (object["commands"] as? [NSNumber]).map { Set($0.map(\.intValue)) }
        // 封面：新封面随数据一起来；之后只带编号，沿用缓存
        let artworkID = object["artworkID"] as? String
        if let base64 = object["artwork"] as? String, let data = Data(base64Encoded: base64), let image = NSImage(data: data) {
            artworkCache = (artworkID ?? UUID().uuidString, image, Self.dominantColor(of: image))
        }
        if let cache = artworkCache {
            if cache.id == artworkID {
                artworkPendingSince = nil
                next.artwork = cache.image
                next.tint = cache.tint
            } else if info?.artwork != nil {
                // 切歌时新封面通常晚一点才到：最多 3 秒内先沿用上一张，避免封面消失又出现、面板和菜单栏宽度跳动
                let since = artworkPendingSince ?? Date()
                artworkPendingSince = since
                if Date().timeIntervalSince(since) < 3 {
                    next.artwork = cache.image
                    next.tint = cache.tint
                }
            }
        }
        if next.isVideo { next.tint = nil } else if let bundle = next.bundle { Self.musicPlayers.insert(bundle) }
        let value: NowPlayingInfo? = next.title.isEmpty && next.artwork == nil ? nil : next
        clearWork?.cancel()
        clearWork = nil
        pauseWork?.cancel()
        pauseWork = nil
        // 切歌时播放器会短暂报告“暂停”：先按播放中显示，1 秒后仍是暂停才切换图标（自己点的暂停除外）
        if value?.playing != false { pausedSince = nil }
        if var paused = value, !paused.playing, info?.playing == true, Date().timeIntervalSince(userPausedAt) > 2 {
            let since = pausedSince ?? Date()
            pausedSince = since
            let wait = 1 - Date().timeIntervalSince(since)   // 从第一次报告暂停算起，而不是每次更新重新计时
            let real = paused
            guard wait > 0 else { info = real; return }
            let work = DispatchWorkItem { [weak self] in self?.info = real }
            pauseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
            paused.playing = true
            paused.rate = max(paused.rate, 1)
            info = paused
            return
        }
        if value == nil, info != nil {
            // 切歌瞬间信息会短暂为空：等 2 秒仍为空才清掉
            let work = DispatchWorkItem { [weak self] in self?.info = nil }
            clearWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
            return
        }
        info = value
    }

    /// 封面主色：缩到 24×24，按饱和度加权平均较鲜艳的像素；整体偏灰（黑白封面）时返回 nil。
    /// 结果提亮，保证在深色菜单栏上清晰可见。
    static func dominantColor(of image: NSImage) -> NSColor? {
        let side = 24
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        let pixels = (0..<side).flatMap { x in (0..<side).compactMap { y in bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) } }
        // 先找鲜艳的颜色；没有（暗色封面，如深蓝夜景）再放宽，暗而带色的像素也算，最后把亮度提上来
        let passes: [(minSaturation: CGFloat, minBrightness: CGFloat, saturation: ClosedRange<CGFloat>)] = [
            (0.25, 0.25, 0.45...0.85),
            (0.12, 0.06, 0.35...0.7),
        ]
        for pass in passes {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, weight: CGFloat = 0
            for color in pixels {
                let saturation = color.saturationComponent, brightness = color.brightnessComponent
                guard saturation > pass.minSaturation, brightness > pass.minBrightness else { continue }
                let w = saturation * saturation * brightness
                red += color.redComponent * w
                green += color.greenComponent * w
                blue += color.blueComponent * w
                weight += w
            }
            // 第二轮的像素都很暗，权重天然小，门槛按亮度下限同比降低
            guard weight > CGFloat(pixels.count) * 0.02 * pass.minBrightness / 0.25 else { continue }
            let average = NSColor(srgbRed: red / weight, green: green / weight, blue: blue / weight, alpha: 1)
            return NSColor(hue: average.hueComponent,
                           saturation: min(max(average.saturationComponent, pass.saturation.lowerBound), pass.saturation.upperBound),
                           brightness: max(average.brightnessComponent, 0.9), alpha: 1)
        }
        // 黑白灰封面：用中性浅灰，而不是借用播放器图标的颜色
        return pixels.isEmpty ? nil : NSColor(srgbRed: 0.82, green: 0.82, blue: 0.84, alpha: 1)
    }
}

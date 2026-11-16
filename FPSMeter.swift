import AppKit
import CoreMedia
import ScreenCaptureKit

/// 帧率：用 ScreenCaptureKit 盯住一个窗口（或整块屏幕），统计每秒画面实际变化了几次。
/// 只数帧、不看画面：捕获尺寸压到很小，每帧只算一个内容指纹用来比较，算完就丢，不保存、不上传。
/// 需要“屏幕录制”权限。测的是画面变化次数——画面静止时会掉到很低，上限是屏幕刷新率。
///
/// 为什么要比较内容：系统送来的“完整帧”远多于窗口真正重画的次数（实测 30 帧的窗口会收到 50～140 帧），
/// 有变化区域的标记也一样不准；按缩略图内容是否变化来数，30 / 60 / 100 帧分别测得 30 / 57～63 / 93～99。
final class FPSMeter: NSObject, SCStreamOutput, SCStreamDelegate {
    enum Target {
        case frontmostWindow      // 前台程序最大的那个窗口
        case display              // 整块主屏幕
    }

    enum MeterError: Error { case noWindow, noDisplay }

    /// 每秒回调一次（主线程）：画面变化次数、正在测的对象名称（程序名或“整块屏幕”）。
    /// 帧数为 -1 表示捕获意外停止（窗口关闭等），调用方可以重新开始。
    var onSample: (Int, String) -> Void = { _, _ in }
    /// 走查用：启动过程中的每一步。
    var onStep: (String) -> Void = { _ in }
    private(set) var targetName = ""
    /// 被测窗口所在屏幕的最高刷新率（帧率不会超过它）。
    private(set) var refreshRate = 60
    /// 被测程序（前台程序变了就要换目标）。
    private(set) var targetPID: pid_t?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "islet.fps")
    private var frames = 0                 // 只在 queue 上读写
    private var lastFingerprint: UInt64 = 0
    private var ticker: DispatchSourceTimer?

    func start(_ target: Target) async throws {
        onStep("读取窗口列表")
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        onStep("窗口 \(content.windows.count) 个，屏幕 \(content.displays.count) 块")
        let filter: SCContentFilter
        let aspect: CGFloat
        var displayID = CGMainDisplayID()
        switch target {
        case .frontmostWindow:
            let pid = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
            let candidates = content.windows.filter {
                $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width >= 100 && $0.frame.height >= 100
            }
            guard let window = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                targetPID = pid
                throw MeterError.noWindow
            }
            targetPID = pid
            targetName = window.owningApplication?.applicationName ?? "前台窗口"
            filter = SCContentFilter(desktopIndependentWindow: window)
            aspect = window.frame.height / max(window.frame.width, 1)
            // 窗口中心落在哪块屏幕上（两者都是左上角为原点的全局坐标）
            let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
            if let display = content.displays.first(where: { $0.frame.contains(center) }) { displayID = display.displayID }
        case .display:
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                throw MeterError.noDisplay
            }
            targetName = "整块屏幕"
            filter = SCContentFilter(display: display, excludingWindows: [])
            aspect = CGFloat(display.height) / CGFloat(max(display.width, 1))
            displayID = display.displayID
        }
        let screenID = displayID
        refreshRate = await MainActor.run {
            NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == screenID }?
                .maximumFramesPerSecond ?? 60
        }

        let config = SCStreamConfiguration()
        config.width = 64                                          // 只数帧：画面越小越省
        config.height = max(16, Int((64 * aspect).rounded()))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 240)   // 不限速：画面变一次就送一帧
        config.queueDepth = 4
        config.showsCursor = false                                  // 鼠标移动不算画面变化
        config.capturesAudio = false

        onStep("目标：\(targetName)，开始捕获")
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        onStep("捕获已开始")

        let ticker = DispatchSource.makeTimerSource(queue: queue)
        ticker.schedule(deadline: .now() + 1, repeating: 1)
        ticker.setEventHandler { [weak self] in
            guard let self else { return }
            let count = self.frames
            self.frames = 0
            let name = self.targetName
            DispatchQueue.main.async { self.onSample(count, name) }
        }
        ticker.resume()
        self.ticker = ticker
    }

    func stop() async {
        ticker?.cancel()
        ticker = nil
        try? await stream?.stopCapture()
        stream = nil
    }

    /// 只数内容真的变了的完整帧
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let print = Self.fingerprint(pixels)
        guard print != lastFingerprint else { return }
        lastFingerprint = print
        frames += 1
    }

    /// 小图的内容指纹（FNV-1a）：画面没变时指纹相同。
    private static func fingerprint(_ buffer: CVPixelBuffer) -> UInt64 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let length = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
        var hash: UInt64 = 0xcbf29ce484222325
        for i in 0..<length { hash = (hash ^ UInt64(bytes[i])) &* 0x100000001b3 }
        return hash
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onSample(-1, self.targetName) }
    }
}

/// 走查：--fps-probe <输出文件> <秒数> [display]
/// 测前台窗口（或整块屏幕）的帧率，每秒写一行到文件，结束后退出。不创建菜单栏图标。
enum FPSProbe {
    private static var current: FPSMeter?

    static func run(_ arguments: [String]) {
        let output = URL(fileURLWithPath: arguments[2])
        let seconds = Int(arguments[3]) ?? 10
        let target: FPSMeter.Target = arguments.contains("display") ? .display : .frontmostWindow
        FileManager.default.createFile(atPath: output.path, contents: nil)
        func write(_ line: String) {
            guard let handle = try? FileHandle(forWritingTo: output) else { return }
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        }
        let meter = FPSMeter()
        current = meter   // 留住：否则启动完就被释放，每秒的计数也跟着停了
        meter.onStep = { write("STEP\t\($0)") }
        var count = 0
        meter.onSample = { fps, name in
            write("\(fps)\t\(name)\t\(meter.refreshRate)Hz")
            count += 1
            if count >= seconds || fps < 0 { exit(0) }
        }
        Task {
            do { try await meter.start(target) }
            catch { write("ERROR\t\(error)"); exit(1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds + 15)) { write("TIMEOUT"); exit(2) }
    }
}

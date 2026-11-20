import AppKit
import SwiftUI

/// 离屏渲染（设计走查）：--render island / spectrumbar <输出.png>，画完直接退出。
/// 其余目标（面板、设置页等）由 AppDelegate.runRender 处理。
enum RenderTargets {
    static func runIfRequested(_ launchArguments: [String]) {
        guard launchArguments.count >= 4, launchArguments[1] == "--render" else { return }
        switch launchArguments[2] {
        case "island": island(launchArguments)
        case "islandstates": islandStates(launchArguments)
        case "spectrumbar": spectrumBar(launchArguments)
        default: return
        }
    }

    private static func island(_ launchArguments: [String]) {
    // 指标灵动岛：未选中 / 选中 GPU 两行，画在菜单栏底色上
    let scale: CGFloat = 3, rowHeight: CGFloat = 24
    let probe = MetricsIslandView(frame: .zero)
    probe.segments = MetricsIslandView.demoSegments()
    if launchArguments.contains("netboth") {
        probe.segments[probe.segments.count - 1].image = StatusIcons.network([.init(arrow: "↑", value: "0KB", active: false), .init(arrow: "↓", value: "1.2MB", active: true)])
    }
    // 第三行：有声音时向左展开出音频部分
    let art = NSImage(size: NSSize(width: 100, height: 100), flipped: false) { rect in
        NSGradient(starting: NSColor(srgbRed: 1, green: 0.45, blue: 0.3, alpha: 1),
                   ending: NSColor(srgbRed: 0.55, green: 0.15, blue: 0.5, alpha: 1))!.draw(in: rect, angle: -45)
        return true
    }
    let bars = SpectrumBarsView(frame: NSRect(x: 0, y: 0, width: 200, height: rowHeight))
    bars.embedded = true
    bars.artwork = art
    bars.tint = NowPlayingMonitor.dominantColor(of: art)
    bars.hasMedia = true
    bars.playing = true
    bars.appIcon = SpectrumController.appIcon(bundle: "com.netease.163music")
    let levels = (0..<SpectrumAnalyzer.bandCount).map { i in Float(max(0.08, 0.85 * exp(-pow(Double(i) - 7, 2) / 30) + 0.15)) }
    bars.layer?.contentsScale = scale
    bars.layer?.sublayers?.forEach { $0.contentsScale = scale }
    bars.frame.size.width = bars.preferredWidth
    bars.update(levels, audible: true)
    let expanded = MetricsIslandView(frame: .zero)
    expanded.segments = probe.segments
    expanded.trailing = StatusIcons.bluetooth([(symbol: "keyboard", battery: 41), (symbol: "computermouse", battery: 15), (symbol: "headphones", battery: nil)])
    expanded.audio = (bars, bars.preferredWidth)
    let tint = bars.tint!
    expanded.backdrop = SpectrumLook(backdrop: .gradient).backdropColors(tint: tint)
    expanded.frame = NSRect(x: 0, y: 0, width: 10, height: rowHeight)
    let width = expanded.preferredWidth + 20
    let rows: CGFloat = 3
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(rowHeight * rows * scale),
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: width, height: rowHeight * rows)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor(srgbRed: 0.16, green: 0.27, blue: 0.5, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: rowHeight * rows).fill()
    for (row, selected) in [Metric?.none, .gpu].enumerated() {
        let view = MetricsIslandView(frame: NSRect(x: 0, y: 0, width: probe.preferredWidth, height: rowHeight))
        view.segments = probe.segments
        view.selected = selected
        NSGraphicsContext.current?.cgContext.saveGState()
        NSGraphicsContext.current?.cgContext.translateBy(x: 10, y: rowHeight * CGFloat(2 - row))
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { view.draw(view.bounds) }
        NSGraphicsContext.current?.cgContext.restoreGState()
    }
    expanded.frame = NSRect(x: 0, y: 0, width: 10, height: rowHeight)   // 先定高度再取宽度
    expanded.frame.size.width = expanded.preferredWidth
    expanded.layout()
    bars.update(levels, audible: true)
    if let context = NSGraphicsContext.current?.cgContext {
        context.saveGState()
        context.translateBy(x: 10, y: 0)
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { expanded.draw(expanded.bounds) }
        let origin = bars.convert(NSPoint.zero, to: expanded)   // 频谱在裁切容器里，换算到岛的坐标
        context.translateBy(x: origin.x, y: origin.y)
        bars.renderSnapshot(in: context)
        context.restoreGState()
    }
    NSGraphicsContext.restoreGraphicsState()
    try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: launchArguments[3]))
    print("已渲染：\(launchArguments[3])")
    exit(0)
    }

    /// README 用：灵动岛的各种状态，每种一张图（3 倍），画在菜单栏底色上。
    /// --render islandstates <输出目录> [split]（split：画成分体胶囊，新装默认的样子）
    private static func islandStates(_ launchArguments: [String]) {
        let dir = URL(fileURLWithPath: launchArguments[3], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let scale: CGFloat = 3, rowHeight: CGFloat = 24, margin: CGFloat = 14
        let menuBar = NSColor(srgbRed: 0.16, green: 0.27, blue: 0.5, alpha: 1)
        let art = NSImage(size: NSSize(width: 100, height: 100), flipped: false) { rect in
            NSGradient(starting: NSColor(srgbRed: 1, green: 0.45, blue: 0.3, alpha: 1),
                       ending: NSColor(srgbRed: 0.55, green: 0.15, blue: 0.5, alpha: 1))!.draw(in: rect, angle: -45)
            return true
        }
        let levels = (0..<SpectrumAnalyzer.bandCount).map { i in
            Float(min(max(0.2 + 0.6 * exp(-pow(Double(i) - 4, 2) / 12) + 0.35 * exp(-pow(Double(i) - 12, 2) / 16) + 0.06 * sin(Double(i) * 2.1), 0.1), 0.95))
        }
        func icon(path: String) -> NSImage { NSWorkspace.shared.icon(forFile: path) }

        enum Audio { case music, paused, video, other }
        func makeBars(_ kind: Audio) -> SpectrumBarsView {
            let bars = SpectrumBarsView(frame: NSRect(x: 0, y: 0, width: 200, height: rowHeight))
            bars.embedded = true
            switch kind {
            case .music, .paused:
                bars.artwork = art
                bars.tint = NowPlayingMonitor.dominantColor(of: art)
                bars.hasMedia = true
                bars.playing = kind == .music
                bars.appIcon = SpectrumController.appIcon(bundle: "com.netease.163music")
            case .video:
                bars.hasMedia = true
                bars.playing = true
                bars.playPauseOnly = true
                let chrome = icon(path: "/Applications/Google Chrome.app")
                bars.appIcon = SpectrumController.rasterizedIcon(chrome, inset: 0.12)
                bars.iconTint = NowPlayingMonitor.dominantColor(of: chrome)
            case .other:
                let game = icon(path: "/Applications/VideoFusion-macOS.app")
                bars.appIcon = SpectrumController.rasterizedIcon(game, inset: 0.12)
                bars.iconTint = NowPlayingMonitor.dominantColor(of: game)
            }
            bars.layer?.contentsScale = scale
            bars.layer?.sublayers?.forEach { $0.contentsScale = scale }
            bars.frame.size.width = bars.preferredWidth
            bars.update(kind == .paused ? levels.map { _ in 0 } : levels, audible: kind != .paused)
            return bars
        }

        let all = MetricsIslandView.demoSegments()
        let compact = all.filter { [.cpu, .memory, .temperature, .network].contains($0.metric) }   // 刘海屏机型默认
        let rings = StatusIcons.bluetooth([(symbol: "keyboard", battery: 64), (symbol: "computermouse", battery: 15), (symbol: "headphones", battery: 80)])
        // 两组：刘海屏（默认只留常用指标，左边画刘海）与非刘海屏（全部指标）
        var states: [(name: String, segments: [(metric: Metric, image: NSImage)], audio: Audio?, trailing: NSImage?, notch: Bool)] = []
        for notch in [true, false] {
            let prefix = notch ? "notch" : "desktop"
            let segments = notch ? compact : all
            states += [
                ("\(prefix)-metrics", segments, nil, rings, notch),
                ("\(prefix)-no-bluetooth", segments, nil, nil, notch),
                ("\(prefix)-music", segments, .music, rings, notch),
                ("\(prefix)-paused", segments, .paused, rings, notch),
                ("\(prefix)-video", segments, .video, rings, notch),
                ("\(prefix)-other", segments, .other, rings, notch),
                ("\(prefix)-music-only", [], .music, nil, notch),
            ]
        }
        for state in states {
            let view = MetricsIslandView(frame: .zero)
            view.split = launchArguments.contains("split")
            view.segments = state.segments
            view.trailing = state.trailing
            var bars: SpectrumBarsView?
            if let kind = state.audio {
                let b = makeBars(kind)
                bars = b
                view.audio = (b, b.preferredWidth)
                view.audioLeadsWithCircle = b.leadsWithCircle
                view.backdrop = SpectrumLook(backdrop: .gradient).backdropColors(tint: b.effectiveTint)
            } else {
                view.backdrop = SpectrumLook(backdrop: .gradient).backdropColors(tint: nil)   // 没播放：默认的主题蓝渐变
            }
            // 先定高度再取宽度：两端圆形的留白按高度计算，高度为 0 时宽度会少算
            view.frame = NSRect(x: 0, y: 0, width: 10, height: rowHeight)
            view.frame.size.width = view.preferredWidth
            view.layout()
            let notchWidth: CGFloat = state.notch ? 190 : 0
            let width = view.preferredWidth + margin * 2 + notchWidth
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(rowHeight * scale),
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            bitmap.size = NSSize(width: width, height: rowHeight)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            menuBar.setFill()
            NSRect(x: 0, y: 0, width: width, height: rowHeight).fill()
            if state.notch {
                // 刘海：顶边贴屏幕边缘、下边两角圆
                let notch = NSRect(x: margin, y: -10, width: notchWidth - margin * 2, height: rowHeight + 10)
                NSColor.black.setFill()
                NSBezierPath(roundedRect: notch, xRadius: 9, yRadius: 9).fill()
            }
            if let context = NSGraphicsContext.current?.cgContext {
                context.saveGState()
                context.translateBy(x: margin + notchWidth, y: 0)
                NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { view.draw(view.bounds) }
                if let bars {
                    let origin = bars.convert(NSPoint.zero, to: view)
                    context.translateBy(x: origin.x, y: origin.y)
                    bars.renderSnapshot(in: context)
                }
                context.restoreGState()
            }
            NSGraphicsContext.restoreGraphicsState()
            let url = dir.appendingPathComponent("island-\(state.name).png")
            try! bitmap.representation(using: .png, properties: [:])!.write(to: url)
            print("已渲染：\(url.path)")
        }
        exit(0)
    }

    private static func spectrumBar(_ launchArguments: [String]) {
    // 菜单栏频谱各外观组合，竖排画在深色菜单栏底上
    let art = NSImage(size: NSSize(width: 100, height: 100), flipped: false) { rect in
        NSGradient(starting: NSColor(srgbRed: 0.3, green: 0.55, blue: 1, alpha: 1),
                   ending: NSColor(srgbRed: 0.75, green: 0.85, blue: 1, alpha: 1))!.draw(in: rect, angle: -45)
        return true
    }
    let looks: [SpectrumLook] = [
        .init(shape: .bars, tint: .white, backdrop: .black, controls: false),
        .init(shape: .bars, tint: .album, backdrop: .gradient, controls: false),
        .init(shape: .bars, tint: .album, backdrop: .black, controls: true),
        .init(shape: .dots, tint: .album, backdrop: .gradient, controls: true),
        .init(shape: .bars, tint: .album, backdrop: .gradient, controls: false),
        .init(shape: .bars, tint: .album, backdrop: .gradient, controls: true),
        .init(shape: .bars, tint: .album, backdrop: .gradient, controls: true),
    ]
    let rowHeight: CGFloat = 24, width: CGFloat = 200, scale: CGFloat = 3
    let levels = (0..<SpectrumAnalyzer.bandCount).map { i in Float(max(0.08, 0.85 * exp(-pow(Double(i) - 7, 2) / 30) + 0.15)) }
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(rowHeight * CGFloat(looks.count) * scale),
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
    context.scaleBy(x: scale, y: scale)
    context.setFillColor(NSColor(srgbRed: 0.16, green: 0.27, blue: 0.5, alpha: 1).cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: rowHeight * CGFloat(looks.count)))
    for (index, look) in looks.enumerated() {
        let view = SpectrumBarsView(frame: NSRect(x: 0, y: 0, width: width, height: rowHeight))
        view.appearance = NSAppearance(named: .darkAqua)
        view.look = look
        view.artwork = art
        view.tint = NowPlayingMonitor.dominantColor(of: art)
        view.hasMedia = true
        view.playing = true
        view.appIcon = SpectrumController.appIcon(bundle: "com.netease.163music")
        // 最后两行：其他程序发声（有图标 / 无图标）
        if index >= looks.count - 2 {
            view.artwork = nil; view.tint = nil; view.hasMedia = false; view.playing = false
            view.appIcon = index == looks.count - 2 ? SpectrumController.appIcon(bundle: "com.apple.FinalCut") ?? SpectrumController.appIcon(bundle: "com.apple.Safari")
                : SoundSource(pid: 0, bundle: nil, name: "原神", icon: nil).cgIcon
        }
        view.layer?.contentsScale = scale
        view.layer?.sublayers?.forEach { $0.contentsScale = scale }
        view.update(levels, audible: true)
        view.frame.size.width = view.preferredWidth
        view.update(levels, audible: true)
        context.saveGState()
        context.translateBy(x: 10, y: rowHeight * CGFloat(looks.count - 1 - index))
        view.layer?.render(in: context)
        context.restoreGState()
    }
    try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: launchArguments[3]))
    print("已渲染：\(launchArguments[3])")
    exit(0)
    }
}

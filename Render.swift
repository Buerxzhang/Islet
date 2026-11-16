import AppKit
import SwiftUI

/// 离屏渲染（设计走查）：--render island / spectrumbar <输出.png>，画完直接退出。
/// 其余目标（面板、设置页等）由 SpeedBar.runRender 处理。
enum RenderTargets {
    static func runIfRequested(_ launchArguments: [String]) {
        guard launchArguments.count >= 4, launchArguments[1] == "--render" else { return }
        switch launchArguments[2] {
        case "island": island(launchArguments)
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
    if launchArguments.contains("spark") {
        let wave = (0..<30).map { 20 + 25 * sin(Double($0) / 4) + Double($0) }
        probe.segments[0].image = StatusIcons.sparkline("CPU", value: "18%", values: wave, level: .normal)
        probe.segments[1].image = StatusIcons.sparkline("GPU", value: "92%", values: wave.map { $0 + 30 }, level: .critical)
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
    if launchArguments.contains("hud") { expanded.setHUDImmediately(.init(symbol: "speaker.wave.2.fill", fraction: 0.45, text: "45%")) }
    expanded.trailing = StatusIcons.bluetooth([(symbol: "keyboard", battery: 41), (symbol: "computermouse", battery: 15), (symbol: "headphones", battery: nil)])
    expanded.audio = (bars, bars.preferredWidth)
    let tint = bars.tint!
    expanded.backdrop = SpectrumLook(backdrop: .gradient).backdropColors(tint: tint)
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
    expanded.frame = NSRect(x: 0, y: 0, width: expanded.preferredWidth, height: rowHeight)
    expanded.layout()
    bars.update(levels, audible: true)
    if let context = NSGraphicsContext.current?.cgContext {
        context.saveGState()
        context.translateBy(x: 10, y: 0)
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { expanded.draw(expanded.bounds) }
        let origin = bars.convert(NSPoint.zero, to: expanded)   // 频谱在裁切容器里，换算到岛的坐标
        context.translateBy(x: origin.x, y: origin.y)
        bars.layer?.render(in: context)
        context.restoreGState()
    }
    NSGraphicsContext.restoreGraphicsState()
    try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: launchArguments[3]))
    print("已渲染：\(launchArguments[3])")
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
        .init(shape: .dots, tint: .album, backdrop: .album, controls: true),
        .init(shape: .bars, tint: .album, backdrop: .album, controls: false),
        .init(shape: .bars, tint: .album, backdrop: .album, controls: true),
        .init(shape: .bars, tint: .album, backdrop: .album, controls: true),
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

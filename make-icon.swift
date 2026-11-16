import AppKit
import SwiftUI

// 生成 islet 的应用图标：深蓝底上一枚米白色胶囊（灵动岛），里面左边一个圆点（正在播放），
// 右边一条脉搏线（系统指标）。纯色扁平，没有光晕和阴影。
// 用法：swift make-icon.swift <输出 .iconset 目录>
// 坐标系为 1024×1024（苹果图标网格），按目标像素缩放绘制。

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let sizes = [16, 32, 128, 256, 512]
let canvas: CGFloat = 1024

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

let tileColor = color(0x0C1033)   // 深蓝
let pillColor = color(0xF4EEE3)   // 米白
let inkColor = tileColor          // 圆点和脉搏线与底色同色，像在胶囊上挖出来的

/// 苹果图标网格：1024 画布里 824 的连续圆角方块。形状不标准时程序坞会把图标缩小放进灰底框。
func squircle() -> NSBezierPath {
    let side: CGFloat = 824, inset = (canvas - side) / 2
    return NSBezierPath(cgPath: RoundedRectangle(cornerRadius: side * 0.2237, style: .continuous)
        .path(in: CGRect(x: inset, y: inset, width: side, height: side)).cgPath)
}

func capsule(_ rect: NSRect) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
}

func drawIcon(pixels: Int) {
    tileColor.setFill()
    squircle().fill()

    // 胶囊
    let pill = NSRect(x: 512 - 360, y: 512 - 150, width: 720, height: 300)
    pillColor.setFill()
    capsule(pill).fill()

    // 圆点 + 脉搏线，整体在胶囊里居中
    let dot: CGFloat = 160, gap: CGFloat = 46, pulse: CGFloat = 330
    var x = 512 - (dot + gap + pulse) / 2
    let y: CGFloat = 512
    inkColor.setFill()
    NSBezierPath(ovalIn: NSRect(x: x, y: y - dot / 2, width: dot, height: dot)).fill()
    x += dot + gap

    let line = NSBezierPath()
    line.move(to: NSPoint(x: x + 8, y: y))
    line.line(to: NSPoint(x: x + pulse * 0.28, y: y))
    line.line(to: NSPoint(x: x + pulse * 0.42, y: y - 70))
    line.line(to: NSPoint(x: x + pulse * 0.62, y: y + 82))
    line.line(to: NSPoint(x: x + pulse * 0.76, y: y))
    line.line(to: NSPoint(x: x + pulse - 8, y: y))
    // 小尺寸（16 / 32 像素）下线条加粗，否则缩小后断成细丝
    line.lineWidth = pixels <= 64 ? 56 : 40
    line.lineCapStyle = .round
    line.lineJoinStyle = .round
    inkColor.setStroke()
    line.stroke()
}

func render(pixels: Int) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current!.cgContext.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
    drawIcon(pixels: pixels)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

for size in sizes {
    for scale in [1, 2] {
        let pixels = size * scale
        let suffix = scale == 2 ? "@2x" : ""
        try render(pixels: pixels).representation(using: .png, properties: [:])!.write(
            to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        )
    }
}

import AppKit

/// 菜单栏图标：统一为两行排版，与网速的两行文字等高、同节奏。
/// - CPU / GPU / 内存 / 磁盘：上行小号标签，下行数值；持续高负载等异常时数值才变色
/// - 网速：上传、下载两行（单方向时为 NET 标签 + 速率），有流量时箭头亮起（下载蓝、上传绿）
/// 带颜色所以不用模板图，绘制时按菜单栏当前明暗选择前景色。
enum StatusIcons {
    private struct Palette {
        let fg: NSColor
        let dim: NSColor
    }

    /// 数值的状态色。
    enum Level {
        case normal, warning, critical

        init(_ fraction: Double?, warn: Double = 0.7, alarm: Double = 0.9) {
            guard let fraction else { self = .normal; return }
            self = fraction >= alarm ? .critical : fraction >= warn ? .warning : .normal
        }
    }

    /// 数值字体：系统字体的窄体（SF Pro Condensed）+ 等宽数字，每段比常规字宽窄约 15%，数值变化时宽度不变。
    private static let valueFont: NSFont = {
        let condensed = NSFont.systemFont(ofSize: 10.5, weight: .semibold, width: .condensed)
        let descriptor = condensed.fontDescriptor.addingAttributes([
            .featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]],
        ])
        return NSFont(descriptor: descriptor, size: 10.5) ?? NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    }()
    private static let labelFont = NSFont.systemFont(ofSize: 7, weight: .bold)

    /// 绘制时读取当前外观（即菜单栏按钮的外观），明暗切换后重绘即自动适配。
    private static func palette() -> Palette {
        let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let base = dark ? NSColor.white : NSColor.black
        return Palette(fg: base.withAlphaComponent(dark ? 1 : 0.85),
                       dim: base.withAlphaComponent(dark ? 0.55 : 0.5))
    }

    private static func make(width: CGFloat, _ draw: @escaping (NSRect, Palette) -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: 22), flipped: false) { rect in
            draw(rect, palette())
            return true
        }
        image.cacheMode = .never  // 每次显示都按当前明暗重绘；实测与缓存模式开销相同
        return image
    }

    // MARK: - 标签 + 数值

    /// widest：该指标可能出现的最宽数值（如 100%、108°、↓88.8MB），用来固定宽度，
    /// 数值变化时宽度不变，整组菜单栏不会来回跳动。
    static func labeled(_ label: String, value: String, level: Level, widest: String) -> NSImage {
        let bottom = NSAttributedString(string: value, attributes: [.font: valueFont])
        return labeled(label, value: bottom, level: level, widest: widest)
    }

    private static func labeled(_ label: String, value: NSAttributedString, level: Level, widest: String) -> NSImage {
        let labelAttributes: [NSAttributedString.Key: Any] = [.font: labelFont, .kern: 0.5]
        let width = ceil(max(widest.size(withAttributes: [.font: value.attribute(.font, at: 0, effectiveRange: nil) ?? valueFont]).width,
                             value.size().width,
                             label.size(withAttributes: labelAttributes).width))
        return make(width: width) { rect, palette in
            var top = labelAttributes
            top[.foregroundColor] = palette.dim
            let labelSize = label.size(withAttributes: top)
            label.draw(at: NSPoint(x: rect.midX - labelSize.width / 2, y: 12.2), withAttributes: top)

            let color: NSColor
            switch level {
            case .normal: color = palette.fg
            case .warning: color = .systemOrange
            case .critical: color = .systemRed
            }
            // 未单独着色的部分（数字）用前景 / 状态色，已着色的部分（箭头）保留
            let text = NSMutableAttributedString(attributedString: value)
            text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { existing, range, _ in
                if existing == nil { text.addAttribute(.foregroundColor, value: color, range: range) }
                else if let marker = existing as? NSColor, marker == .clear {
                    text.addAttribute(.foregroundColor, value: palette.dim, range: range)
                }
            }
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: 0))
        }
    }

    struct RateRow {
        let arrow: String       // "↓" 或 "↑"
        let value: String       // 如 "1.6MB"
        let active: Bool
    }

    /// 一个方向：与其他指标一致，如 NET / ↓1.6MB。
    /// 两个方向：两行紧凑排版（上传在上、下载在下），宽 41pt，不加标签以免过宽。
    /// 网速：与其他指标同样的两行排版。一个方向时标签为 NET；两个方向时并排两列 UP / DOWN。
    /// 有流量时箭头点亮（下载蓝、上传绿），空闲时变暗。
    static func network(_ rows: [RateRow]) -> NSImage {
        func value(_ row: RateRow) -> NSAttributedString {
            // 活动箭头用固定色；空闲箭头用 .clear 作标记，绘制时换成当前外观的暗色
            let arrowColor: NSColor = row.active ? (row.arrow == "↓" ? .systemBlue : .systemGreen) : .clear
            let text = NSMutableAttributedString(string: row.arrow, attributes: [.font: valueFont, .foregroundColor: arrowColor])
            // 菜单栏里省掉单位中的“B”：1.6MB → 1.6M（面板里仍写全）
            let number = row.value.hasSuffix("B") || row.value.hasSuffix("b") ? String(row.value.dropLast()) : row.value
            text.append(NSAttributedString(string: number, attributes: [.font: valueFont]))
            return text
        }
        guard rows.count == 2 else {
            return rows.first.map { labeled("NET", value: value($0), level: .normal, widest: "↓88.8M") } ?? labeled("NET", value: "—", level: .normal, widest: "↓88.8M")
        }
        let columns = rows.map { labeled($0.arrow == "↑" ? "UP" : "DOWN", value: value($0), level: .normal, widest: "↓88.8M") }
        let gap: CGFloat = 6
        let width = columns.reduce(0) { $0 + $1.size.width } + gap
        let image = NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
            var x: CGFloat = 0
            for column in columns {
                column.draw(in: NSRect(x: x, y: 0, width: column.size.width, height: column.size.height))
                x += column.size.width + gap
            }
            return true
        }
        image.cacheMode = .never
        return image
    }
}

extension StatusIcons {
    /// 通知右侧的大图：深色圆底 + 电量环 + 设备图标（和灵动岛上的圈一致）。
    static func batteryBadge(symbol: String, level: Int) -> NSImage {
        let side: CGFloat = 160
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            NSColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: side, height: side)).fill()
            let ring = NSRect(x: 24, y: 24, width: side - 48, height: side - 48)
            let track = NSBezierPath(ovalIn: ring)
            track.lineWidth = 12
            NSColor(white: 1, alpha: 0.16).setStroke()
            track.stroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: side / 2, y: side / 2), radius: ring.width / 2, startAngle: 90,
                          endAngle: 90 - 360 * CGFloat(max(level, 2)) / 100, clockwise: true)
            arc.lineWidth = 12
            arc.lineCapStyle = .round
            batteryColor(level).setStroke()
            arc.stroke()
            if let g = glyph(symbol, size: 40, color: .white) {
                g.draw(in: NSRect(x: (side - g.size.width) / 2, y: (side - g.size.height) / 2, width: g.size.width, height: g.size.height))
            }
            return true
        }
    }

    private static func batteryColor(_ level: Int?) -> NSColor {
        guard let level else { return NSColor(white: 1, alpha: 0.5) }
        return level <= 20 ? .systemRed : level <= 40 ? .systemOrange : .systemGreen
    }

    private static func glyph(_ name: String, size: CGFloat, color: NSColor) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .bold).applying(.init(paletteColors: [color])))
    }

    /// 蓝牙设备：每台已连接设备一个圆环，环是电量（绿 > 40%、橙 ≤ 40%、红 ≤ 20%），中间是设备图标；
    /// 不显示数字（点开蓝牙面板看具体值），与文字型的指标明显区分。读不到电量时只画灰色底环。
    static func bluetooth(_ devices: [(symbol: String, battery: Int?)]) -> NSImage {
        // 圈外径 16（含描边），和封面一样大：在 21 高的胶囊里上下各留 2.5，排在最右时和圆头同心
        let d: CGFloat = 16, gap: CGFloat = 6
        let width = CGFloat(devices.count) * d + CGFloat(max(devices.count - 1, 0)) * gap
        return NSImage(size: NSSize(width: max(width, 1), height: 22), flipped: false) { _ in
            for (i, dev) in devices.enumerated() {
                let rect = NSRect(x: CGFloat(i) * (d + gap) + 1, y: 11 - (d - 2) / 2, width: d - 2, height: d - 2)
                let track = NSBezierPath(ovalIn: rect)
                track.lineWidth = 2
                NSColor(white: 1, alpha: 0.18).setStroke()
                track.stroke()
                if let level = dev.battery {
                    let arc = NSBezierPath()
                    arc.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2, startAngle: 90,
                                  endAngle: 90 - 360 * CGFloat(level) / 100, clockwise: true)
                    arc.lineWidth = 2
                    arc.lineCapStyle = .round
                    batteryColor(level).setStroke()
                    arc.stroke()
                }
                // 设备图标纯白：先按模板画，再整体填白（多层符号的次要层也不会变灰）
                if let g = glyph(dev.symbol, size: 7.5, color: .white) {
                    let white = NSImage(size: g.size, flipped: false) { bounds in
                        g.draw(in: bounds)
                        NSColor.white.set()
                        bounds.fill(using: .sourceIn)
                        return true
                    }
                    white.draw(in: NSRect(x: rect.midX - g.size.width / 2, y: rect.midY - g.size.height / 2, width: g.size.width, height: g.size.height))
                }
            }
            return true
        }
    }

}

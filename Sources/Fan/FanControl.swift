import Foundation

/// 风扇控制：菜单栏程序与 root 辅助程序共用的定义与算法。
/// 设计参考 FunFan（MIT）：四种策略（自动 / 固定 / 曲线 / 规则）+ 降温滞后 + 斜率限制 + 动态安全下限 + 租约看门狗。
enum FanControl {
    /// 辅助程序的 launchd 标签与 XPC 服务名。
    static let label = "local.codex.islet.fanhelper"
    /// 协议版本：不一致时提示重新安装组件。
    static let version = 2
    /// 只接受这个程序的连接（另有代码签名标识校验）。
    static let clientPath = "/Applications/islet.app/Contents/MacOS/islet"
    static let clientIdentifier = "local.codex.islet"
    static let helperPath = "/Library/PrivilegedHelperTools/\(label)"
    static let plistPath = "/Library/LaunchDaemons/\(label).plist"
    /// 租约：菜单栏程序每 5 秒续一次，15 秒没续约辅助程序就把风扇交还系统。
    static let leaseSeconds: Double = 15
    static let heartbeatSeconds: Double = 5
    /// 调速参考的温度分组（CPU 性能核、GPU）。
    static let controlGroups = ["CPU 性能核", "GPU"]
}

// MARK: - 策略与配置

/// 风扇策略。rawValue 会持久化并经 XPC 传给辅助程序，不能随意改名。
enum FanStrategy: String, CaseIterable, Codable {
    case auto, fixed, curve, rules

    var label: String {
        switch self {
        case .auto: return "自动"
        case .fixed: return "固定"
        case .curve: return "曲线"
        case .rules: return "规则"
        }
    }
}

/// 调速依据：取参考分组的平均温度还是最热传感器。安全下限同样按这个口径计算。
enum TemperatureBasis: String, CaseIterable, Codable {
    case average, peak

    var label: String { self == .average ? "平均温度" : "最高温度" }
}

struct CurvePoint: Codable, Equatable {
    var celsius: Double
    var rpm: Double
}

/// 曲线预设。转速按系统最低～最高转速的比例给出，换机型也适用。
enum CurvePreset: String, CaseIterable, Codable {
    case quiet, balanced, performance

    var label: String {
        switch self {
        case .quiet: return "静音"
        case .balanced: return "均衡"
        case .performance: return "性能"
        }
    }

    var detail: String {
        switch self {
        case .quiet: return "75℃ 以下几乎不介入，温度换噪音"
        case .balanced: return "60℃ 起提速，90℃ 全速"
        case .performance: return "35℃ 起就给基础转速，优先压温"
        }
    }

    private var fractions: [(Double, Double)] {
        switch self {
        case .quiet: return [(75, 0), (85, 0.3), (95, 0.7), (100, 1)]
        case .balanced: return [(60, 0), (70, 0.25), (80, 0.55), (90, 1)]
        case .performance: return [(35, 0.15), (55, 0.4), (70, 0.75), (80, 1)]
        }
    }

    func points(minimum: Double, maximum: Double) -> [CurvePoint] {
        fractions.map { CurvePoint(celsius: $0.0, rpm: (minimum + (maximum - minimum) * $0.1).rounded()) }
    }
}

/// 一条规则：当 [分组] 的 [平均 / 最高] 温度 ≥ 阈值时，转速至少为 rpm；回落到 阈值 − 迟滞 以下才解除。
struct FanRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var enabled = true
    var group = "CPU 性能核"
    var peak = false
    var threshold: Double = 80
    var hysteresis: Double = 2
    var rpm: Double = 3500
}

/// 完整的控制配置：菜单栏程序持久化它，并整份发给辅助程序。
struct FanConfig: Codable, Equatable {
    var strategy: FanStrategy = .auto
    var basis: TemperatureBasis = .average
    var fixedRPM: Double = 2500
    var curve: [CurvePoint] = []
    var preset: CurvePreset? = .balanced   // 曲线未被手动修改时记录来自哪个预设
    var rules: [FanRule] = []

    /// 辅助程序侧校验：数量、范围不合理的内容丢弃或截断。转速最终还会经过安全策略。
    func sanitized(minimum: Double, maximum: Double) -> FanConfig {
        var config = self
        config.fixedRPM = min(max(fixedRPM.isFinite ? fixedRPM : maximum, minimum), maximum)
        config.curve = Array(curve.filter { $0.celsius.isFinite && $0.rpm.isFinite && (0...120).contains($0.celsius) }
            .map { CurvePoint(celsius: $0.celsius, rpm: min(max($0.rpm, minimum), maximum)) }
            .sorted { $0.celsius < $1.celsius }
            .prefix(12))
        if config.curve.isEmpty { config.curve = CurvePreset.balanced.points(minimum: minimum, maximum: maximum) }
        config.rules = Array(rules.filter { $0.threshold.isFinite && (20...120).contains($0.threshold) && $0.rpm.isFinite }
            .map { rule in
                var rule = rule
                rule.rpm = min(max(rule.rpm, minimum), maximum)
                rule.hysteresis = min(max(rule.hysteresis, 0), 20)
                return rule
            }
            .prefix(16))
        return config
    }
}

/// 辅助程序回报的状态。
struct FanStatus: Codable {
    var strategy: FanStrategy = .auto
    var controlling = false      // 风扇当前是否处于本程序控制（规则未触发时为 false）
    var target: Double = 0
    var celsius: Double?
    var triggered: [UUID] = []
    var version = FanControl.version
    var message: String?         // 最近一次交还系统的原因等
}

// MARK: - 曲线

enum FanCurve {
    /// 线性插值；区间外取端点值。空曲线返回 nil。
    static func rpm(_ points: [CurvePoint], at celsius: Double) -> Double? {
        guard let first = points.first, let last = points.last else { return nil }
        if celsius <= first.celsius { return first.rpm }
        if celsius >= last.celsius { return last.rpm }
        for index in 1..<points.count where celsius <= points[index].celsius {
            let lower = points[index - 1]
            let upper = points[index]
            let span = upper.celsius - lower.celsius
            guard span > 0 else { return upper.rpm }
            return lower.rpm + (upper.rpm - lower.rpm) * (celsius - lower.celsius) / span
        }
        return last.rpm
    }
}

// MARK: - 安全策略

/// 任何策略的输出都要经过这里：
/// - 动态下限：85℃ 以下为系统最低转速，105℃（M4 降频温度附近）及以上为最高转速，中间线性；
/// - 输出始终在系统最低～最高转速之间，绝不为 0；
/// - 温度读数异常时按最高转速处理（宁可吵，不可过热）。
enum FanSafety {
    static let floorStart: Double = 85
    static let floorEnd: Double = 105

    static func floor(celsius: Double, minimum: Double, maximum: Double) -> Double {
        guard celsius.isFinite else { return maximum }
        if celsius <= floorStart { return minimum }
        if celsius >= floorEnd { return maximum }
        return minimum + (maximum - minimum) * (celsius - floorStart) / (floorEnd - floorStart)
    }

    static func clamp(_ rpm: Double, celsius: Double, minimum: Double, maximum: Double) -> Double {
        let lower = floor(celsius: celsius, minimum: minimum, maximum: maximum)
        let value = rpm.isFinite ? rpm : maximum
        return Swift.min(Swift.max(value, lower, minimum), maximum)
    }
}

// MARK: - 平滑引擎

/// 在目标转速之上叠加降温滞后与斜率限制，避免风扇忽快忽慢。
struct FanSmoother {
    /// 降温方向的死区：比上次调整时低这么多度才降速。升温立即响应。（只用于曲线）
    var hysteresis: Double = 2
    /// 每秒最多加速 / 减速多少转。减速更慢，听感更平顺。
    var rampUp: Double = 400
    var rampDown: Double = 200

    private var lastOutput: Double?
    private var referenceCelsius: Double?

    mutating func reset() {
        lastOutput = nil
        referenceCelsius = nil
    }

    /// 推进一步，返回实际下发的转速（已过安全策略）。
    mutating func update(target: Double, celsius: Double, minimum: Double, maximum: Double,
                         elapsed: Double, useHysteresis: Bool) -> Double {
        let safeTarget = FanSafety.clamp(target, celsius: celsius, minimum: minimum, maximum: maximum)
        guard let last = lastOutput, let reference = referenceCelsius else {
            lastOutput = safeTarget  // 首次直接到位，不从 0 慢慢爬
            referenceCelsius = celsius
            return safeTarget
        }
        var desired = safeTarget
        if useHysteresis, safeTarget < last, celsius > reference - hysteresis { desired = last }
        let step = Swift.max(0, elapsed)
        let limited = Swift.min(Swift.max(desired, last - rampDown * step), last + rampUp * step)
        // 斜率限制可能让输出暂时低于新的安全下限（温度骤升时），以安全下限为准
        let safe = FanSafety.clamp(limited, celsius: celsius, minimum: minimum, maximum: maximum)
        if abs(safe - last) > 0.5 { referenceCelsius = celsius }
        lastOutput = safe
        return safe
    }
}

// MARK: - 规则引擎

/// 只持有“哪些规则已触发”这一份状态。多条同时触发取最大转速（最积极散热优先）。
struct FanRuleEngine {
    private(set) var armed: Set<UUID> = []

    mutating func reset() { armed.removeAll() }

    /// readings：分组名 → (平均, 最高)。返回所有触发规则中的最大转速，无触发为 nil。
    mutating func evaluate(_ rules: [FanRule], readings: [String: (average: Double, peak: Double)]) -> Double? {
        var result: Double?
        for rule in rules {
            guard rule.enabled, let reading = readings[rule.group] else {
                armed.remove(rule.id)
                continue
            }
            let value = rule.peak ? reading.peak : reading.average
            if armed.contains(rule.id) {
                if value < rule.threshold - rule.hysteresis { armed.remove(rule.id) }
            } else if value >= rule.threshold {
                armed.insert(rule.id)
            }
            if armed.contains(rule.id) { result = Swift.max(result ?? 0, rule.rpm) }
        }
        let valid = Set(rules.map(\.id))
        armed = armed.intersection(valid)
        return result
    }
}

// MARK: - XPC 接口

/// 菜单栏程序 → 辅助程序。配置整份以 JSON 传递，辅助程序会自行校验和截断。
@objc protocol FanHelperProtocol {
    /// 应用配置并续约。reply：错误信息，成功为 nil。
    func apply(_ config: Data, reply: @escaping (String?) -> Void)
    /// 当前状态（FanStatus 的 JSON）。
    func status(reply: @escaping (Data) -> Void)
}

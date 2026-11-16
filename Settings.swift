import AppKit

enum SpeedSetting: Int, CaseIterable {
    // 顺序即设置窗口中的排列顺序；存储用 key，不依赖 rawValue
    case direction, cpuItem, gpuItem, memoryItem, diskItem, powerItem, fanItem, temperatureItem, interval, count

    var key: String {
        switch self {
        case .direction: return "networkMode"
        case .interval: return "refreshInterval"
        case .count: return "appRowCount"
        case .cpuItem: return "showCPUItem"
        case .gpuItem: return "showGPUItem"
        case .memoryItem: return "showMemoryItem"
        case .diskItem: return "showDiskItem"
        case .powerItem: return "showPowerItem"
        case .fanItem: return "showFanItem"
        case .temperatureItem: return "showTemperatureItem"
        }
    }

    var title: String {
        switch self {
        case .direction: return "网速"
        case .cpuItem: return "CPU"
        case .gpuItem: return "GPU"
        case .memoryItem: return "内存"
        case .diskItem: return "磁盘"
        case .powerItem: return "功耗"
        case .fanItem: return "风扇"
        case .temperatureItem: return "温度"
        case .interval: return "菜单栏刷新频率"
        case .count: return "排行显示条数"
        }
    }

    var choices: [String] {
        switch self {
        case .direction: return ["自动", "上传和下载", "隐藏"]
        case .cpuItem, .gpuItem, .memoryItem, .diskItem, .powerItem, .fanItem, .temperatureItem: return ["在菜单栏显示", "隐藏"]
        case .interval: return ["每 1 秒", "每 2 秒", "每 3 秒"]
        case .count: return ["3 条", "5 条", "8 条"]
        }
    }

    /// 按机型决定的默认隐藏项（只在用户没改过时生效）：
    /// - 没有风扇的机型（MacBook Air 等）：风扇默认不显示；
    /// - 带刘海的屏幕（菜单栏右侧空间有限）：只默认显示 CPU、内存、温度、网速几项核心指标。
    static let hiddenByDefault: Set<SpeedSetting> = {
        var hidden: Set<SpeedSetting> = []
        if Fan.readAll().isEmpty { hidden.insert(.fanItem) }
        if NSScreen.screens.contains(where: { $0.safeAreaInsets.top > 0 }) {
            hidden.formUnion([.gpuItem, .diskItem, .powerItem, .fanItem])
        }
        return hidden
    }()

    var selection: Int {
        // 旧版网速有 6 种显示方式（自动 / 上传和下载 / 仅下载 / 仅上传 / 仅图标 / 隐藏），合并成 3 种
        if self == .direction, UserDefaults.standard.object(forKey: key) == nil,
           let old = UserDefaults.standard.object(forKey: "networkDisplay") as? Int {
            let mapped = old == 1 ? 1 : old == 5 ? 2 : 0
            UserDefaults.standard.set(mapped, forKey: key)
        }
        let fallback = self == .count ? 2 : (Self.hiddenByDefault.contains(self) ? 1 : 0)
        let value = UserDefaults.standard.object(forKey: key) as? Int ?? fallback
        return choices.indices.contains(value) ? value : fallback
    }

    func select(_ index: Int) {
        guard choices.indices.contains(index) else { return }
        UserDefaults.standard.set(index, forKey: key)
    }
}

extension Metric {
    var setting: SpeedSetting {
        switch self {
        case .network: return .direction
        case .cpu: return .cpuItem
        case .gpu: return .gpuItem
        case .memory: return .memoryItem
        case .disk: return .diskItem
        case .power: return .powerItem
        case .fan: return .fanItem
        case .temperature: return .temperatureItem
        }
    }

    /// 是否在菜单栏显示：每项的最后一个选项都是“隐藏”。
    var isShown: Bool {
        setting.selection != setting.choices.count - 1
    }
}

/// 外观：跟随系统 / 浅色 / 深色。只作用于本程序的面板和窗口，不影响菜单栏图标。
enum AppearanceSetting: Int, CaseIterable {
    case system, light, dark

    var label: String { ["跟随系统", "浅色", "深色"][rawValue] }

    static var current: AppearanceSetting {
        AppearanceSetting(rawValue: UserDefaults.standard.integer(forKey: "appearance")) ?? .system
    }

    static func select(_ value: AppearanceSetting) {
        UserDefaults.standard.set(value.rawValue, forKey: "appearance")
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// 菜单栏指标的顺序（从左到右），用户可在设置里拖动调整。
/// 灵动岛上各项从左到右的顺序（音乐、各指标、蓝牙都可拖动）。存为名称数组：music、cpu…、bluetooth。
enum IslandOrder {
    private static let key = "islandOrder"
    static let standard: [String] = ["music"] + MetricOrder.standard.map { "\($0)" } + ["bluetooth"]

    static var items: [String] {
        let defaults = UserDefaults.standard
        var saved = defaults.stringArray(forKey: key) ?? []
        if saved.isEmpty {
            // 旧版只存了指标顺序：音乐放最前、蓝牙放最后
            let metrics = defaults.stringArray(forKey: "metricOrder") ?? []
            saved = ["music"] + metrics + ["bluetooth"]
        }
        var order: [String] = []
        for id in saved + standard where standard.contains(id) && !order.contains(id) { order.append(id) }
        return order
    }

    static func save(_ items: [String]) { UserDefaults.standard.set(items, forKey: key) }
}

/// 指标的顺序（从灵动岛顺序里取出指标）。
enum MetricOrder {
    static let standard: [Metric] = [.cpu, .gpu, .memory, .disk, .power, .temperature, .fan, .network]
    static var current: [Metric] { IslandOrder.items.compactMap { id in Metric.allCases.first { "\($0)" == id } } }
}

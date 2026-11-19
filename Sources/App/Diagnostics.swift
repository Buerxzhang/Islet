import AppKit

/// 诊断：一句话自检结论（给普通用户）+ 可贴进问题反馈的完整 Markdown 报告（给开发者）。
enum Diagnostics {
    /// 一句话结论。
    static func summary() -> String {
        let client = FanHelperClient.shared
        if Fan.readAll().isEmpty { return "这台 Mac 没有可控制的风扇，其余功能正常" }
        if client.config.strategy != .auto {
            if !client.isRunningFromApplications { return "需要从“应用程序”文件夹运行才能调速" }
            if !client.isInstalled { return "已选择调速策略，但控制组件未安装" }
            if !client.isHelperCurrent { return "控制组件需要更新" }
            if let message = client.status?.message { return "风扇已交还系统：\(message)" }
        }
        return "自检通过，一切正常"
    }

    /// 完整报告（Markdown）。会枚举一次 SMC 键，约需 0.2 秒。
    static func report() -> String {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] ?? "?")（\(info?["CFBundleVersion"] ?? "?")）"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let keys = SMC.shared.allKeys()
        let temperatures = Temperatures()
        let groups = temperatures.read()
        let fans = Fan.readAll()
        let client = FanHelperClient.shared
        var lines: [String] = []
        lines.append("## islet 诊断报告")
        lines.append("")
        lines.append("| 项目 | 值 |")
        lines.append("|---|---|")
        lines.append("| 程序版本 | \(version) |")
        lines.append("| 机型 | \(sysctlString("hw.model") ?? "?") |")
        lines.append("| 芯片 | \(sysctlString("machdep.cpu.brand_string") ?? "?") |")
        lines.append("| 核心 | 性能核 \(sysctlInt("hw.perflevel0.physicalcpu") ?? 0) · 能效核 \(sysctlInt("hw.perflevel1.physicalcpu") ?? 0) |")
        lines.append("| 系统 | macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) |")
        lines.append("| SMC 键 | \(keys.count) 个 |")
        lines.append("| 温度探测点 | \(temperatures.sensorCount) 个 |")
        lines.append("| 整机功耗 | \(PowerStats.systemWatts().map { String(format: "%.1f W", $0) } ?? "读不到") |")
        lines.append("")
        lines.append("### 温度分组")
        for group in groups {
            lines.append(String(format: "- %@：平均 %.1f℃，最高 %.1f℃", group.name, group.average, group.maximum))
        }
        lines.append("")
        lines.append("### 风扇")
        if fans.isEmpty { lines.append("- 没有风扇") }
        for (index, fan) in fans.enumerated() {
            let mode = SMC.shared.value("F\(index)Md").map { $0 == 0 ? "系统控制" : "手动（\(Int($0))）" } ?? "无模式键"
            lines.append(String(format: "- 风扇 %d：%.0f 转（%.0f–%.0f），%@", index, fan.current, fan.minimum, fan.maximum, mode))
        }
        lines.append("- Ftst 解锁键：\(SMC.shared.exists("Ftst") ? "存在" : "不存在")")
        lines.append("")
        lines.append("### 风扇控制")
        lines.append("- 策略：\(client.config.strategy.label)；调速依据：\(client.config.basis.label)")
        lines.append("- 其他调速程序：\(client.conflict ?? "未发现")")
        lines.append("- 从“应用程序”运行：\(client.isRunningFromApplications ? "是" : "否")")
        lines.append("- 控制组件：\(client.isInstalled ? (client.isHelperCurrent ? "已安装（最新）" : "已安装（需更新）") : "未安装")")
        if let status = client.status {
            lines.append("- 组件状态：\(status.controlling ? "接管中，目标 \(Int(status.target)) 转" : "未接管")"
                         + (status.message.map { "；最近交还原因：\($0)" } ?? ""))
        }
        lines.append("")
        lines.append("> 自检：\(summary())")
        return lines.joined(separator: "\n")
    }

    static func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report(), forType: .string)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }
}

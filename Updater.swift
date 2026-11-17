import AppKit
import CryptoKit

/// 应用内更新：弹窗询问 → 下载 Release 里的 islet.zip（显示进度）→ 核对 SHA-256、包标识、版本和签名
/// → 退出后替换「应用程序」里的 islet 并重新打开。任何一步失败都不动现有程序，可改为打开下载页。
final class Updater: NSObject, URLSessionDownloadDelegate {
    static let shared = Updater()

    private var busy = false
    private var progress: (alert: NSAlert, bar: NSProgressIndicator)?
    private var downloaded: URL?
    private var failure: String?

    // MARK: 询问

    /// 有新版本时弹窗。automatic：自动检查触发的，选过“跳过这个版本”就不再弹。
    func prompt(_ release: UpdateChecker.Release, automatic: Bool = false) {
        guard !busy else { return }
        if automatic, UserDefaults.standard.string(forKey: "skippedUpdateVersion") == release.version { return }
        busy = true
        defer { busy = false }
        let alert = NSAlert()
        alert.messageText = "islet \(release.version) 可以更新"
        alert.informativeText = "当前是 \(UpdateChecker.currentVersion)。"
        if !release.notes.isEmpty { alert.accessoryView = Self.notesView(release.notes) }
        alert.addButton(withTitle: release.download == nil ? "打开下载页" : "更新并重启")
        alert.addButton(withTitle: "稍后")
        if automatic { alert.addButton(withTitle: "跳过这个版本") }
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if release.download == nil { NSWorkspace.shared.open(release.url) } else { update(release) }
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(release.version, forKey: "skippedUpdateVersion")
        default: break
        }
    }

    /// 更新说明：去掉 Markdown 记号，放进可滚动的文本框。
    private static func notesView(_ markdown: String) -> NSView {
        let text = markdown.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var line = String(line).replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            while line.hasPrefix("#") { line.removeFirst() }
            if line.hasPrefix("- ") { line = "• " + line.dropFirst(2) }
            return line.trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 360, height: 200)
        scroll.borderType = .bezelBorder
        if let view = scroll.documentView as? NSTextView {
            view.string = text
            view.isEditable = false
            view.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            view.textContainerInset = NSSize(width: 4, height: 6)
        }
        return scroll
    }

    // MARK: 下载

    private func update(_ release: UpdateChecker.Release) {
        guard let url = release.download else { return }
        downloaded = nil
        failure = nil
        let alert = NSAlert()
        alert.messageText = "正在下载 islet \(release.version)"
        alert.informativeText = "下载完成后会自动替换并重新打开。"
        let bar = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 300, height: 20))
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        alert.accessoryView = bar
        alert.addButton(withTitle: "取消")
        progress = (alert, bar)
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
        let task = session.downloadTask(with: url)
        task.resume()
        let response = alert.runModal()   // 下载结束时 abortModal 返回；点“取消”返回第一个按钮
        progress = nil
        session.invalidateAndCancel()
        if response == .alertFirstButtonReturn { return }
        do {
            guard let zip = downloaded else { throw UpdateError(failure ?? "下载没有完成") }
            try install(zip, release)
        } catch {
            let alert = NSAlert()
            alert.messageText = "没能自动更新"
            alert.informativeText = "\((error as? UpdateError)?.message ?? error.localizedDescription)。现有的 islet 没有改动，可以到下载页手动更新。"
            alert.addButton(withTitle: "打开下载页")
            alert.addButton(withTitle: "关闭")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.url) }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let progress, totalBytesExpectedToWrite > 0 else { return }
        progress.bar.doubleValue = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        progress.alert.informativeText = String(format: "%.1f / %.1f MB", Double(totalBytesWritten) / 1_048_576,
                                                Double(totalBytesExpectedToWrite) / 1_048_576)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // 临时文件在这个回调返回后就会被删：先挪走
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
            failure = "下载失败（服务器返回 \((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)）"
            return
        }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("islet-update-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: location, to: target)
            downloaded = target
        } catch {
            failure = "保存下载的文件失败"
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, (error as? URLError)?.code != .cancelled { failure = "下载失败：\(error.localizedDescription)" }
        if progress != nil { NSApp.abortModal() }
    }

    // MARK: 安装

    private struct UpdateError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// 核对下载的包，没问题就退出 islet，由一个小脚本等它退出后替换并重新打开。
    private func install(_ zip: URL, _ release: UpdateChecker.Release) throws {
        let fileManager = FileManager.default
        // 1. 文件完整：和 GitHub 记录的 SHA-256 一致
        if let digest = release.digest {
            let data = try Data(contentsOf: zip)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard hash == digest.lowercased() else { throw UpdateError("下载的文件校验不一致") }
        }
        // 2. 解压，确认是 islet、版本对得上、签名完整
        let folder = fileManager.temporaryDirectory.appendingPathComponent("islet-update-\(UUID().uuidString)")
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        guard Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path]) else { throw UpdateError("解压失败") }
        try? fileManager.removeItem(at: zip)
        let app = folder.appendingPathComponent("islet.app")
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError("下载的不是 islet")
        }
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard UpdateChecker.isNewer(version, than: UpdateChecker.currentVersion) else { throw UpdateError("下载的版本不比当前新") }
        guard Self.run("/usr/bin/codesign", ["--verify", "--strict", app.path]) else { throw UpdateError("下载的程序签名不完整") }
        _ = Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        // 3. 能写入现在的位置（通常是「应用程序」）
        let current = Bundle.main.bundleURL
        guard fileManager.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
            throw UpdateError("没有权限写入 \(current.deletingLastPathComponent().path)")
        }
        // 4. 退出后替换：先把旧版挪到备份，新版放进去；放不进去就把旧版挪回来。最后重新打开
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        backup="$2.update-backup"
        rm -rf "$backup"
        if mv "$2" "$backup"; then
            if mv "$3" "$2"; then rm -rf "$backup"; else mv "$backup" "$2"; fi
        fi
        rm -rf "$4"
        open "$2"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), current.path, app.path, folder.path]
        try process.run()
        NSApp.terminate(nil)
    }

    private static func run(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

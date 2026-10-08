// 在线更新：查 GitHub 最新 release，下载 zip，校验 sha256，替换自身后重启。
//
// 不引入 Sparkle 之类的框架：本项目零依赖，且 GitHub API 已经给出每个资产的
// sha256（digest 字段），够做完整性校验。adhoc 签名做不了 EdDSA 那种发布者
// 签名，所以信任边界就是 GitHub 仓库本身（HTTPS + digest）。
//
// URLSession 下载的文件不带 com.apple.quarantine，替换后重启不会被 Gatekeeper 拦。

import AppKit
import CryptoKit

enum Updater {
    static let repo = "nchao/wechat-multi-mac"
    private static let lastCheckKey = "lastUpdateCheck"
    private static let skipKey = "skippedVersion"

    struct Release {
        let version: String      // 不带 v 前缀
        let notes: String
        let pageURL: URL
        let zipURL: URL
        let sha256: String?      // GitHub 的 digest，老 release 可能没有
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // MARK: - 检查

    /// 启动时自动检查：一天最多一次，用户跳过的版本不再提示，失败静默
    static func checkOnLaunch(window: NSWindow?) {
        let d = UserDefaults.standard
        if let last = d.object(forKey: lastCheckKey) as? Date, Date().timeIntervalSince(last) < 86_400 { return }
        fetchLatest { result in
            guard case .success(let r) = result else { return }
            d.set(Date(), forKey: lastCheckKey)
            guard isNewer(r.version, than: currentVersion), d.string(forKey: skipKey) != r.version else { return }
            prompt(r, window: window)
        }
    }

    /// 菜单「检查更新」：无论结果都给反馈
    static func checkManually(window: NSWindow?) {
        fetchLatest { result in
            switch result {
            case .failure(let e):
                alert("检查更新失败", e.localizedDescription, window: window)
            case .success(let r):
                UserDefaults.standard.set(Date(), forKey: lastCheckKey)
                if isNewer(r.version, than: currentVersion) {
                    prompt(r, window: window)
                } else {
                    alert("已是最新版本", "当前版本 \(currentVersion)。", window: window)
                }
            }
        }
    }

    /// 环境变量 WXMULTI_UPDATE_URL 可指向本地假 release，只用于测试更新流程
    private static var latestURL: URL {
        if let s = ProcessInfo.processInfo.environment["WXMULTI_UPDATE_URL"], let u = URL(string: s) { return u }
        return URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    }

    private static func fetchLatest(_ done: @escaping (Result<Release, Error>) -> Void) {
        var req = URLRequest(url: latestURL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let r: Result<Release, Error>
            if let err {
                r = .failure(err)
            } else if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                r = .failure(fail("GitHub 返回 HTTP \(http.statusCode)"))
            } else if let data, let rel = parse(data) {
                r = .success(rel)
            } else {
                r = .failure(fail("release 信息里没有找到 app 安装包"))
            }
            DispatchQueue.main.async { done(r) }
        }.resume()
    }

    private static func parse(_ data: Data) -> Release? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String,
              let page = (j["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = j["assets"] as? [[String: Any]],
              let zip = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let zipURL = (zip["browser_download_url"] as? String).flatMap(URL.init(string:))
        else { return nil }
        let digest = (zip["digest"] as? String).flatMap { d in
            d.hasPrefix("sha256:") ? String(d.dropFirst(7)) : nil
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, notes: j["body"] as? String ?? "",
                       pageURL: page, zipURL: zipURL, sha256: digest)
    }

    /// 按数字逐段比较，"2.10.0" > "2.9.1"
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - 提示

    private static func prompt(_ r: Release, window: NSWindow?) {
        let a = NSAlert()
        a.messageText = "发现新版本 \(r.version)"
        a.informativeText = "当前版本 \(currentVersion)。\n\n" + trimNotes(r.notes)
        a.addButton(withTitle: "立即更新")
        a.addButton(withTitle: "稍后")
        a.addButton(withTitle: "跳过此版本")
        let handle: (NSApplication.ModalResponse) -> Void = { resp in
            switch resp {
            case .alertFirstButtonReturn: install(r, window: window)
            case .alertThirdButtonReturn: UserDefaults.standard.set(r.version, forKey: skipKey)
            default: break
            }
        }
        if let window { a.beginSheetModal(for: window, completionHandler: handle) } else { handle(a.runModal()) }
    }

    /// release notes 只取「相比上版」那段要点，去掉 markdown 标记，太长截断
    private static func trimNotes(_ s: String) -> String {
        let lines = s.components(separatedBy: .newlines)
            .filter { $0.hasPrefix("- ") }
            .map { "• " + $0.dropFirst(2).replacingOccurrences(of: "`", with: "") }
        let text = lines.prefix(8).joined(separator: "\n")
        return text.isEmpty ? "查看 release 页面了解改动。" : text
    }
}

// MARK: - 下载与安装

extension Updater {
    /// 自己所在的 .app 路径。从 build 目录直接跑的二进制没有 bundle，不支持自更新
    static var selfApp: URL? {
        let u = Bundle.main.bundleURL
        return u.pathExtension == "app" ? u : nil
    }

    /// 测试入口：WXMULTI_UPDATE_AUTO=1 时检查到新版直接安装，跳过确认弹窗
    static func autoInstallForTesting() {
        setvbuf(stdout, nil, _IOLBF, 0)   // 输出重定向到文件时也逐行写出，进程被杀前不丢日志
        fetchLatest { result in
            guard case .success(let r) = result, isNewer(r.version, than: currentVersion) else {
                print("[update-test] 无新版或获取失败: \(result)"); NSApp.terminate(nil); return
            }
            print("[update-test] 发现 \(r.version)，开始安装")
            install(r, window: nil)
        }
    }

    fileprivate static func install(_ r: Release, window: NSWindow?) {
        guard let app = selfApp else {
            alert("无法自动更新", "当前不是从 .app 启动的。请到 release 页面手动下载。", window: window)
            return
        }
        // 能写才能替换。放在 /Applications 时当前用户在 admin 组即可
        guard FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            alert("无法自动更新", "对 \(app.deletingLastPathComponent().path) 没有写权限。", window: window)
            return
        }

        let progress = DownloadPanel(version: r.version)
        progress.show(over: window)

        let task = URLSession.shared.downloadTask(with: r.zipURL) { loc, resp, err in
            let outcome: Result<URL, Error>
            do {
                if let err { throw err }
                guard let loc, (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    throw fail("下载失败（HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)）")
                }
                outcome = .success(try prepare(zip: loc, expect: r.sha256))
            } catch {
                outcome = .failure(error)
            }
            DispatchQueue.main.async {
                progress.close()
                if ProcessInfo.processInfo.environment["WXMULTI_UPDATE_AUTO"] != nil, case .failure(let e) = outcome {
                    print("[update-test] 失败: \(e.localizedDescription)")
                }
                switch outcome {
                case .failure(let e as URLError) where e.code == .cancelled:
                    break   // 用户点了取消，不必再弹窗
                case .failure(let e):
                    alert("更新失败", e.localizedDescription + "\n\n当前版本未受影响。", window: window)
                case .success(let newApp):
                    do {
                        try swap(old: app, new: newApp)
                        relaunch(app)
                    } catch {
                        alert("更新失败", error.localizedDescription, window: window)
                    }
                }
            }
        }
        progress.observe(task.progress)
        progress.onCancel = { task.cancel() }
        task.resume()
    }

    /// 校验 sha256、解压、检查解出的 app 完整可用。都在临时目录里做，失败不碰现有安装
    private static func prepare(zip: URL, expect sha: String?) throws -> URL {
        let data = try Data(contentsOf: zip)
        if let sha {
            let got = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard got == sha.lowercased() else { throw fail("安装包校验失败，sha256 不匹配，可能下载不完整或被篡改。") }
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("wxmulti-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let unzip = Core.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        guard unzip.ok else { throw fail("解压失败：\(unzip.out)") }

        let items = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
        guard let newApp = items.first(where: { $0.pathExtension == "app" }) else { throw fail("安装包里没有 .app") }
        guard Bundle(url: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw fail("安装包的 bundle id 与当前应用不一致，已拒绝。")
        }
        let verify = Core.run("/usr/bin/codesign", ["--verify", "--deep", newApp.path])
        guard verify.ok else { throw fail("新版本签名校验失败：\(verify.out)") }
        return newApp
    }

    /// 旧版移入废纸篓（出问题能捞回来），新版移到原位置。
    /// 运行中的二进制已加载进内存，挪走 bundle 不影响当前进程。
    private static func swap(old: URL, new: URL) throws {
        let fm = FileManager.default
        let staged = old.deletingLastPathComponent().appendingPathComponent(".\(old.lastPathComponent).new")
        try? fm.removeItem(at: staged)
        // 先跨卷挪到目标目录旁边，再做同卷 rename，保证最后一步是原子的
        try fm.moveItem(at: new, to: staged)
        var trashed: NSURL?
        try fm.trashItem(at: old, resultingItemURL: &trashed)
        do {
            try fm.moveItem(at: staged, to: old)
        } catch {
            // 新版放不进去，把旧版捞回来，别让用户手上什么都没有
            if let t = trashed as URL? { try? fm.moveItem(at: t, to: old) }
            throw error
        }
        Ops.registerWithLaunchServices(old.path)
    }

    /// 起一个 shell 等当前进程退出后再 open 新版，然后自己退出
    private static func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$1\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", app.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    fileprivate static func alert(_ title: String, _ msg: String, window: NSWindow?) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = msg
        if let window { a.beginSheetModal(for: window) } else { a.runModal() }
    }

    fileprivate static func fail(_ msg: String) -> NSError {
        NSError(domain: "wxmulti.update", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}

// MARK: - 下载进度面板

private final class DownloadPanel: NSObject {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 110),
                                styleMask: [.titled], backing: .buffered, defer: false)
    private let bar = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "正在下载…")
    private var kvo: NSKeyValueObservation?
    var onCancel: (() -> Void)?

    init(version: String) {
        super.init()
        let title = NSTextField(labelWithString: "正在更新到 \(version)")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        bar.isIndeterminate = false
        bar.minValue = 0; bar.maxValue = 1
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelTapped))
        let stack = NSStackView(views: [title, bar, label, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        bar.widthAnchor.constraint(equalToConstant: 320).isActive = true
        panel.contentView = stack
    }

    func show(over window: NSWindow?) {
        if let window { window.beginSheet(panel) } else { panel.center(); panel.makeKeyAndOrderFront(nil) }
    }

    func observe(_ p: Progress) {
        kvo = p.observe(\.fractionCompleted) { [weak self] p, _ in
            DispatchQueue.main.async {
                self?.bar.doubleValue = p.fractionCompleted
                let done = ByteCountFormatter.string(fromByteCount: p.completedUnitCount, countStyle: .file)
                let total = ByteCountFormatter.string(fromByteCount: p.totalUnitCount, countStyle: .file)
                self?.label.stringValue = p.totalUnitCount > 0 ? "\(done) / \(total)" : "正在下载…"
            }
        }
    }

    func close() {
        kvo = nil
        if let parent = panel.sheetParent { parent.endSheet(panel) } else { panel.orderOut(nil) }
    }

    @objc private func cancelTapped() { onCancel?() }
}

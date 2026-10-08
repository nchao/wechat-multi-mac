// 微信多开 — 原生 AppKit 界面
// 核心方法来自 https://github.com/engrecho/Mac_dual_wechat
//
// 复制 WeChat.app 为独立副本，改 CFBundleIdentifier 后 adhoc 重签名，
// 让 macOS 视其为不同应用，从而拥有独立的 Containers 数据目录。
// 不需要管理员密码：/Applications 对 admin 组可写，微信 app 归当前用户。

import AppKit

// MARK: - 模型

struct Instance {
    var name: String          // 副本名，不含 .app
    var appPath: String
    var bundleId: String
    var isBase: Bool          // 是否为原版微信
    var running: Bool
    var dataSize: String      // 人类可读的数据目录大小，"—" 表示还没有数据
    var idMismatch: Bool      // 签名 id 与期望不符：点图标会跳回原版窗口
    var customIcon: Bool = false
    var needsRepair: Bool = false   // 旧版工具签出来、丢了沙盒 entitlements 的副本

    var binPath: String { appPath + "/" + Core.binRel }
}

// MARK: - 核心逻辑

enum Core {
    static let baseApp = "/Applications/WeChat.app"
    static let baseId = "com.tencent.xinWeChat"
    static let binRel = "Contents/MacOS/WeChat"

    /// 副本名 → bundle id。规则必须与 ~/Library/Containers 下已有目录一致，
    /// 否则重建后接不回已登录的账号。
    static func id(for name: String) -> String {
        if name.hasPrefix("WeChat") {
            let suffix = String(name.dropFirst(6))
            if !suffix.isEmpty, suffix.allSatisfy(\.isNumber) {
                return baseId + suffix
            }
        }
        return baseId + "." + name
    }

    static func containerPath(for bundleId: String) -> String {
        NSHomeDirectory() + "/Library/Containers/" + bundleId
    }

    @discardableResult
    static func run(_ launchPath: String, _ args: [String]) -> (ok: Bool, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
        } catch {
            return (false, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        return (p.terminationStatus == 0, out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// adhoc 重签名，保留每个组件原有的 entitlements。
    ///
    /// 不能只用 --deep：它会把所有 entitlements 丢掉，副本主程序和内置的 WeChatAppEx
    /// （Chromium 内核，负责网页类窗口）都会跑在沙盒外。部分新号登录要做的滑块安全验证
    /// 就在副本里弹不出来。--preserve-metadata=entitlements 配合 --deep 会逐个组件
    /// 保留原 entitlements，实测 75 个可执行文件与原版完全一致。
    static let signArgs = ["--force", "--deep", "--sign", "-", "--preserve-metadata=entitlements"]

    /// 副本主程序是否带沙盒 entitlement。旧版本工具签出来的副本没有
    static func isSandboxed(_ appPath: String) -> Bool {
        run("/usr/bin/codesign", ["-d", "--entitlements", ":-", appPath]).out
            .contains("com.apple.security.app-sandbox")
    }

    static func isRunning(_ binPath: String) -> Bool {
        run("/usr/bin/pgrep", ["-f", "^" + binPath + "$"]).ok
    }

    static func currentId(_ appPath: String) -> String {
        run("/usr/libexec/PlistBuddy",
            ["-c", "Print :CFBundleIdentifier", appPath + "/Contents/Info.plist"]).out
    }

    static func signedId(_ appPath: String) -> String {
        let r = run("/usr/bin/codesign", ["-dv", appPath])
        for line in r.out.components(separatedBy: .newlines) where line.hasPrefix("Identifier=") {
            return String(line.dropFirst("Identifier=".count))
        }
        return ""
    }

    static func dirSize(_ path: String) -> String {
        guard FileManager.default.fileExists(atPath: path) else { return "—" }
        let r = run("/usr/bin/du", ["-sh", path])
        return r.out.components(separatedBy: "\t").first?
            .trimmingCharacters(in: .whitespaces) ?? "—"
    }

    /// 扫描 /Applications，原版排在最前，其余按名字排序。
    /// withSize=false 时跳过 du（几个 G 的目录冷启动要好几秒），数据大小显示为「…」，
    /// 由调用方随后补算，这样列表能先出来。
    static func scan(withSize: Bool = true) -> [Instance] {
        var result: [Instance] = []
        let fm = FileManager.default

        func make(_ appPath: String, isBase: Bool) -> Instance? {
            let name = (appPath as NSString).lastPathComponent
                .replacingOccurrences(of: ".app", with: "")
            guard fm.isExecutableFile(atPath: appPath + "/" + binRel) else { return nil }
            let wantId = isBase ? baseId : id(for: name)
            let real = signedId(appPath)
            return Instance(
                name: name,
                appPath: appPath,
                bundleId: currentId(appPath),
                isBase: isBase,
                running: isRunning(appPath + "/" + binRel),
                dataSize: withSize ? dirSize(containerPath(for: wantId)) : "…",
                idMismatch: !isBase && real != wantId,
                customIcon: !isBase && hasCustomIcon(appPath),
                needsRepair: !isBase && real == wantId && !isSandboxed(appPath)
            )
        }

        if let base = make(baseApp, isBase: true) { result.append(base) }

        let items = (try? fm.contentsOfDirectory(atPath: "/Applications")) ?? []
        var copies: [Instance] = []
        for item in items.sorted() where item.hasSuffix(".app") {
            let path = "/Applications/" + item
            if path == baseApp { continue }
            if let inst = make(path, isBase: false) { copies.append(inst) }
        }
        result.append(contentsOf: copies)
        return result
    }

    static func nextFreeName() -> String {
        for i in 2...30 {
            let candidate = "WeChat\(i)"
            if !FileManager.default.fileExists(atPath: "/Applications/\(candidate).app") {
                return candidate
            }
        }
        return "WeChat2"
    }

    static func appsWritable() -> Bool {
        FileManager.default.isWritableFile(atPath: "/Applications")
    }

    static func icon(for appPath: String) -> NSImage {
        NSWorkspace.shared.icon(forFile: appPath)
    }

    /// 微信原版靠 CFBundleIconName 从 Assets.car 取图标。换图标时会删掉这个键，
    /// 让系统改读 AppIcon.icns，所以键不存在就说明换过图标。
    static func hasCustomIcon(_ appPath: String) -> Bool {
        let plist = NSDictionary(contentsOfFile: appPath + "/Contents/Info.plist")
        return plist?["CFBundleIconName"] == nil
    }
}

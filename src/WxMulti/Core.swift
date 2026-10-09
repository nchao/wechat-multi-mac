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
    var needsRepair: Bool = false   // 旧版工具签出来的副本：丢了沙盒 entitlements，或用的是不带点的旧 id

    /// 数据实际所在容器的 id。旧规则副本迁移前还在旧 id 下
    var dataId: String {
        if isBase { return Core.baseId }
        if let l = Core.legacyId(for: name), bundleId == l { return l }
        return Core.id(for: name)
    }

    var binPath: String { appPath + "/" + Core.binRel }
}

// MARK: - 核心逻辑

enum Core {
    static let baseApp = "/Applications/WeChat.app"
    static let baseId = "com.tencent.xinWeChat"
    static let binRel = "Contents/MacOS/WeChat"

    /// 副本名 → bundle id，一律是 com.tencent.xinWeChat.<名字>。
    ///
    /// 以前 WeChatN 用的是 com.tencent.xinWeChatN（不带点）。这种 id 在保留沙盒
    /// entitlements 之后，微信内置的 WeChatAppEx 一启动就崩（EXC_BREAKPOINT，
    /// 线程 task_thread）。实测带点的 com.tencent.xinWeChat.2 / .WeChat2 正常，
    /// 不带点的 xinWeChat2 / xinWeChat9 / xinWeChatX 都崩，和包内容、数据都无关。
    static func id(for name: String) -> String {
        baseId + "." + name
    }

    /// 旧规则下 WeChatN 的 id。只用来识别、迁移旧副本，新副本不会再用它
    static func legacyId(for name: String) -> String? {
        guard name.hasPrefix("WeChat") else { return nil }
        let suffix = String(name.dropFirst(6))
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return nil }
        return baseId + suffix
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

    /// 指向腾讯开发者团队、adhoc 签名无权持有的两个 entitlement。重签时必须删掉
    static let teamEntitlementKeys = [
        "com.apple.application-identifier",
        "com.apple.developer.team-identifier",
    ]

    /// 导出原版 entitlements 并删掉团队标识键，写成临时文件，返回其路径。失败返回 nil。
    ///
    /// 原版带 com.apple.application-identifier 和 com.apple.developer.team-identifier，
    /// 都指向腾讯的 Team 5A4RE8SF68。adhoc 签名没有团队身份，却带着指向特定团队的标识，
    /// macOS 26 起 AMFI 在启动期判定非法直接杀进程：open 报 POSIX 163 /
    /// Launchd job spawn failed，直接执行二进制则被 SIGKILL。必须删掉这两个键。
    ///
    /// 但不能把 entitlements 全删：少了 com.apple.security.application-groups，微信的
    /// crashpad 组件注册 Mach 服务会被拒（bootstrap_check_in Permission denied 1100），
    /// 进程转为 SIGTRAP 崩溃。所以只删团队标识键，保留 app-sandbox、application-groups
    /// 及其余所有权限。所有副本都复制自同一个 WeChat.app，entitlements 一致，从原版导出即可。
    static func trimmedEntitlements() -> String? {
        let dst = NSTemporaryDirectory() + "wxmulti-ent-\(UUID().uuidString).plist"
        // --xml 保证写出干净 plist，不混 codesign 的提示行
        let dump = run("/usr/bin/codesign", ["-d", "--entitlements", dst, "--xml", baseApp])
        guard dump.ok, FileManager.default.fileExists(atPath: dst) else { return nil }
        for key in teamEntitlementKeys {
            // 键不存在时 PlistBuddy 报错无妨，忽略返回值
            run("/usr/libexec/PlistBuddy", ["-c", "Delete :\(key)", dst])
        }
        return dst
    }

    /// adhoc 重签名。只签主程序 bundle，嵌套组件（WeChatHelper、WeChatAppEx 等）保持
    /// 原版签名不动——它们没改过，资源封印仍然有效（codesign --verify --deep --strict
    /// 通过），且 WeChatAppEx（Chromium 内核，负责滑块安全验证等网页窗口）维持原版 runtime
    /// 签名反而更稳。adhoc 主程序不启用 Library Validation，照常加载这些原版签名的组件。
    ///
    /// 不再用 --deep + --preserve-metadata=entitlements：那样会把嵌套组件一起重签成 adhoc
    /// 并原样保留团队标识，启动即被 AMFI 杀。改成用 trimmedEntitlements() 的裁剪权限签主程序。
    static func sign(_ appPath: String) -> (ok: Bool, out: String) {
        guard let ent = trimmedEntitlements() else {
            return (false, "导出 entitlements 失败")
        }
        defer { try? FileManager.default.removeItem(atPath: ent) }
        return run("/usr/bin/codesign",
                   ["--force", "--sign", "-", "--entitlements", ent, appPath])
    }

    /// 副本主程序是否带沙盒 entitlement。旧版本工具签出来的副本没有
    static func isSandboxed(_ appPath: String) -> Bool {
        run("/usr/bin/codesign", ["-d", "--entitlements", ":-", appPath]).out
            .contains("com.apple.security.app-sandbox")
    }

    /// 副本是否带指向腾讯团队的 entitlement。旧版工具用 --preserve-metadata 签名会原样
    /// 保留 com.apple.developer.team-identifier，这种 adhoc + 团队标识的组合 macOS 26 起
    /// 启动即被 AMFI 杀。带这个键的副本需要重新签名修复。
    static func hasTeamEntitlement(_ appPath: String) -> Bool {
        run("/usr/bin/codesign", ["-d", "--entitlements", ":-", appPath]).out
            .contains("com.apple.developer.team-identifier")
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
            let real = signedId(appPath)
            // 旧规则的 WeChatN 副本（id 不带点）：数据还在旧 id 的容器里，按旧 id 算大小，
            // 并标为需修复，修复时迁移到新 id
            let legacy = isBase ? nil : legacyId(for: name)
            let onLegacy = legacy != nil && real == legacy
            let wantId = isBase ? baseId : (onLegacy ? legacy! : id(for: name))
            return Instance(
                name: name,
                appPath: appPath,
                bundleId: currentId(appPath),
                isBase: isBase,
                running: isRunning(appPath + "/" + binRel),
                dataSize: withSize ? dirSize(containerPath(for: wantId)) : "…",
                idMismatch: !isBase && real != wantId,
                customIcon: !isBase && hasCustomIcon(appPath),
                needsRepair: !isBase && real == wantId
                    && (onLegacy || !isSandboxed(appPath) || hasTeamEntitlement(appPath))
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

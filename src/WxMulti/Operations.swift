// 建立副本 / 启动 / 卸载。耗时步骤放后台线程，通过回调汇报进度。

import AppKit

enum Ops {
    struct Progress {
        var text: String
        var fraction: Double
    }

    /// 准备并启动一批副本。progress / done 都在主线程回调。
    static func launch(
        _ targets: [Instance],
        progress: @escaping (Progress) -> Void,
        done: @escaping ([String]) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            var errors: [String] = []
            let total = Double(targets.count)

            for (i, inst) in targets.enumerated() {
                let head = Double(i) / total
                let slice = 1.0 / total
                func report(_ text: String, _ local: Double) {
                    DispatchQueue.main.async {
                        progress(Progress(text: text, fraction: head + slice * local))
                    }
                }

                let tag = targets.count > 1 ? "(\(i + 1)/\(targets.count)) \(inst.name)" : inst.name

                // 原版或已在运行：直接激活窗口
                if inst.isBase || inst.running {
                    report("\(tag) 激活窗口", 0.5)
                    Core.run("/usr/bin/open", ["-a", inst.appPath])
                    continue
                }

                // 1. 复制（APFS 写时复制，1.4G 约 1 秒）
                if !FileManager.default.fileExists(atPath: inst.appPath) {
                    report("\(tag) 复制副本…", 0.1)
                    let r = Core.run("/bin/cp", ["-Rp", Core.baseApp, inst.appPath])
                    if !r.ok {
                        errors.append("\(inst.name)：复制失败 \(r.out)")
                        continue
                    }
                }
                guard FileManager.default.isExecutableFile(atPath: inst.binPath) else {
                    errors.append("\(inst.name)：\(Core.binRel) 不存在，不像是微信 app")
                    continue
                }

                // 2+3. 改 bundle id 并重签名。只在 id 还是原版时做，
                // 避免对已配置好的副本重复签名（一次约 3 秒）。
                let wantId = Core.id(for: inst.name)
                let curId = Core.currentId(inst.appPath)
                if curId == Core.baseId || curId.isEmpty {
                    report("\(tag) 设置标识 \(wantId)…", 0.35)
                    let r1 = Core.run("/usr/libexec/PlistBuddy",
                                      ["-c", "Set :CFBundleIdentifier \(wantId)",
                                       inst.appPath + "/Contents/Info.plist"])
                    if !r1.ok {
                        errors.append("\(inst.name)：改标识失败 \(r1.out)")
                        continue
                    }
                    report("\(tag) 重新签名…", 0.5)
                    let r2 = Core.run("/usr/bin/codesign", Core.signArgs + [inst.appPath])
                    if !r2.ok {
                        errors.append("\(inst.name)：签名失败 \(r2.out)")
                        continue
                    }
                    registerWithLaunchServices(inst.appPath)
                }

                // 校验：签名 id 与期望不符时，点图标会激活原版窗口而非副本。
                // 旧规则的不带点 id 也算对，它会被标为需修复，由修复流程迁移
                let real = Core.signedId(inst.appPath)
                if real != wantId && real != Core.legacyId(for: inst.name) {
                    errors.append("\(inst.name)：签名标识是 \(real.isEmpty ? "未知" : real)，应为 \(wantId)")
                }

                // 4. 启动并等进程真的起来。走 open（LaunchServices），和点 Dock 一样，
                // 不继承本进程的环境变量：从终端带着 LANG=en_US 启动时，直接执行二进制
                // 会让微信首次启动选成英文界面
                report("\(tag) 启动中…", 0.7)
                Core.run("/usr/bin/open", ["-n", inst.appPath])

                var alive = false
                for s in 1...20 {
                    Thread.sleep(forTimeInterval: 1)
                    if Core.isRunning(inst.binPath) { alive = true; break }
                    report("\(tag) 启动中… \(s)s", 0.7 + 0.3 * Double(s) / 20.0)
                }
                if !alive { errors.append("\(inst.name)：启动后进程未存活") }
            }

            DispatchQueue.main.async { done(errors) }
        }
    }

    /// 新建副本。名字合法性由调用方先校验。
    static func create(
        names: [String],
        progress: @escaping (Progress) -> Void,
        done: @escaping ([String]) -> Void
    ) {
        let targets = names.map { name in
            Instance(name: name, appPath: "/Applications/\(name).app",
                     bundleId: "", isBase: false, running: false,
                     dataSize: "—", idMismatch: false)
        }
        launch(targets, progress: progress, done: done)
    }

    /// 卸载：app 移入废纸篓（可恢复），数据目录按 purge 决定
    static func uninstall(
        _ targets: [Instance],
        purge: Bool,
        progress: @escaping (Progress) -> Void,
        done: @escaping ([String]) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            var errors: [String] = []
            let total = Double(targets.count)

            for (i, inst) in targets.enumerated() {
                DispatchQueue.main.async {
                    progress(Progress(text: "正在卸载 \(inst.name)…",
                                      fraction: Double(i) / total))
                }

                if inst.isBase {
                    errors.append("\(inst.name)：原版微信，拒绝卸载")
                    continue
                }
                if Core.isRunning(inst.binPath) {
                    errors.append("\(inst.name)：正在运行，请先退出")
                    continue
                }

                // 用 trashItem 而非 rm：误删可从废纸篓恢复
                do {
                    try FileManager.default.trashItem(
                        at: URL(fileURLWithPath: inst.appPath), resultingItemURL: nil)
                } catch {
                    errors.append("\(inst.name)：移入废纸篓失败 \(error.localizedDescription)")
                    continue
                }

                if purge {
                    let data = Core.containerPath(for: inst.dataId)
                    if FileManager.default.fileExists(atPath: data) {
                        do {
                            try FileManager.default.trashItem(
                                at: URL(fileURLWithPath: data), resultingItemURL: nil)
                        } catch {
                            errors.append("\(inst.name)：数据目录移入废纸篓失败")
                        }
                    }
                }
            }

            refreshLaunchServices()
            DispatchQueue.main.async { done(errors) }
        }
    }

    // MARK: - LaunchServices

    private static let lsregister =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    /// 不刷新的话 Dock/启动台可能仍按旧 id 把点击路由到原版窗口
    static func registerWithLaunchServices(_ appPath: String) {
        guard FileManager.default.isExecutableFile(atPath: lsregister) else { return }
        Core.run(lsregister, ["-f", appPath])
    }

    static func refreshLaunchServices() {
        guard FileManager.default.isExecutableFile(atPath: lsregister) else { return }
        Core.run(lsregister, ["-kill", "-r", "-domain", "local", "-domain", "user"])
    }
}

// MARK: - 修复旧副本

extension Ops {
    /// 修复旧版本工具签出来、丢了 entitlements 的副本。
    ///
    /// 只对已有副本重签修不好：旧签名里 entitlements 已经没了，--preserve-metadata
    /// 无从保留。做法是从原版重新复制一份（自带完整 entitlements），换上副本的
    /// bundle id 和自定义图标，再签名，最后原子替换。数据目录由 bundle id 决定，
    /// 不受影响，实测替换后原有数据完整接回。
    static func repair(
        _ targets: [Instance],
        progress: @escaping (Progress) -> Void,
        done: @escaping ([String]) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            var errors: [String] = []
            let fm = FileManager.default
            let total = Double(targets.count)

            for (i, inst) in targets.enumerated() {
                func report(_ t: String, _ f: Double) {
                    DispatchQueue.main.async { progress(Progress(text: "\(inst.name) \(t)", fraction: (Double(i) + f) / total)) }
                }
                if inst.isBase { continue }
                if Core.isRunning(inst.binPath) {
                    errors.append("\(inst.name)：正在运行，请先退出")
                    continue
                }

                let dir = (inst.appPath as NSString).deletingLastPathComponent
                let staged = dir + "/.\(inst.name).repair.app"
                try? fm.removeItem(atPath: staged)

                report("从原版重新复制…", 0.1)
                guard Core.run("/bin/cp", ["-Rp", Core.baseApp, staged]).ok else {
                    errors.append("\(inst.name)：复制失败"); continue
                }

                report("设置标识…", 0.3)
                let wantId = Core.id(for: inst.name)
                guard Core.run("/usr/libexec/PlistBuddy",
                               ["-c", "Set :CFBundleIdentifier \(wantId)", staged + "/Contents/Info.plist"]).ok else {
                    try? fm.removeItem(atPath: staged)
                    errors.append("\(inst.name)：改标识失败"); continue
                }

                // 自定义过图标的，把图标带过去
                if inst.customIcon {
                    let icns = "/Contents/Resources/AppIcon.icns"
                    try? fm.removeItem(atPath: staged + icns)
                    try? fm.copyItem(atPath: inst.appPath + icns, toPath: staged + icns)
                    Core.run("/usr/libexec/PlistBuddy", ["-c", "Delete :CFBundleIconName", staged + "/Contents/Info.plist"])
                }

                report("重新签名…", 0.5)
                let sign = Core.run("/usr/bin/codesign", Core.signArgs + [staged])
                guard sign.ok, Core.isSandboxed(staged) else {
                    try? fm.removeItem(atPath: staged)
                    errors.append("\(inst.name)：签名失败 \(sign.out)"); continue
                }

                // 旧副本进废纸篓，新副本挪到原位。失败就把旧的捞回来
                report("替换…", 0.85)
                var trashed: NSURL?
                do {
                    try fm.trashItem(at: URL(fileURLWithPath: inst.appPath), resultingItemURL: &trashed)
                    try fm.moveItem(atPath: staged, toPath: inst.appPath)
                } catch {
                    if !fm.fileExists(atPath: inst.appPath), let t = trashed as URL? {
                        try? fm.moveItem(at: t, to: URL(fileURLWithPath: inst.appPath))
                    }
                    try? fm.removeItem(atPath: staged)
                    errors.append("\(inst.name)：替换失败 \(error.localizedDescription)"); continue
                }
                registerWithLaunchServices(inst.appPath)

                // 旧规则副本：把数据容器从旧 id 改名到新 id，账号数据跟着走
                if inst.dataId != wantId {
                    report("迁移聊天数据…", 0.95)
                    if let e = migrateContainer(from: inst.dataId, to: wantId) {
                        errors.append("\(inst.name)：\(e)")
                    }
                }
            }
            DispatchQueue.main.async { done(errors) }
        }
    }
}

// MARK: - 数据容器迁移

extension Ops {
    /// 把沙盒数据容器从旧 bundle id 挪到新 bundle id。
    ///
    /// 同一个卷里改名是原子的，几个 G 的数据也是瞬间完成，不会复制一份。
    /// 实测改名后系统按新 id 接管这个容器，原有数据完整可用。
    /// 新 id 的容器已存在且有数据时不覆盖，交给用户处理，免得丢数据。
    static func migrateContainer(from oldId: String, to newId: String) -> String? {
        let fm = FileManager.default
        let src = Core.containerPath(for: oldId)
        let dst = Core.containerPath(for: newId)
        guard fm.fileExists(atPath: src) else { return nil }   // 旧容器不存在，没数据要迁

        if fm.fileExists(atPath: dst) {
            // 新容器只是空壳（比如修复前误启动过一次）就挪进废纸篓让位；有聊天数据则不动
            let files = (dst + "/Data/Documents/xwechat_files")
            let hasData = ((try? fm.contentsOfDirectory(atPath: files)) ?? []).contains { $0.hasPrefix("wxid_") }
            if hasData {
                return "数据迁移跳过：\(newId) 下已有聊天数据，旧数据仍在 \(oldId)，需要手动处理"
            }
            do {
                try fm.trashItem(at: URL(fileURLWithPath: dst), resultingItemURL: nil)
            } catch {
                return "数据迁移失败：无法腾出 \(newId)（\(error.localizedDescription)），旧数据仍在 \(oldId)"
            }
        }

        do {
            try fm.moveItem(atPath: src, toPath: dst)
        } catch {
            return "数据迁移失败：\(error.localizedDescription)，旧数据仍在 \(oldId)"
        }
        // containermanagerd 用这个属性认容器归属，改名后要同步
        Core.run("/usr/bin/xattr", ["-w", "com.apple.containermanager.identifier", newId, dst])
        return nil
    }
}

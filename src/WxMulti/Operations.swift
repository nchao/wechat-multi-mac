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
                    let r2 = Core.run("/usr/bin/codesign",
                                      ["--force", "--deep", "--sign", "-", inst.appPath])
                    if !r2.ok {
                        errors.append("\(inst.name)：签名失败 \(r2.out)")
                        continue
                    }
                    registerWithLaunchServices(inst.appPath)
                }

                // 校验：签名 id 与期望不符时，点图标会激活原版窗口而非副本
                let real = Core.signedId(inst.appPath)
                if real != wantId {
                    errors.append("\(inst.name)：签名标识是 \(real.isEmpty ? "未知" : real)，应为 \(wantId)")
                }

                // 4. 启动并等进程真的起来
                report("\(tag) 启动中…", 0.7)
                Core.run("/bin/sh", ["-c",
                    "/usr/bin/nohup '\(inst.binPath)' >/dev/null 2>&1 &"])

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
                    let data = Core.containerPath(for: Core.id(for: inst.name))
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

// 副本自定义图标：把任意尺寸的图片处理成 macOS 规格的图标并写进副本。
//
// macOS 图标规格：1024 画布内圆角方块约 824，四边留透明边，否则在 Dock 里
// 会比邻居大一圈。圆角半径约为方块边长的 22.4%。

import AppKit

enum IconFit: Int {
    case fill = 0   // 等比放大铺满方块，超出部分裁掉（照片类）
    case fit = 1    // 等比缩小完整放进方块，空白处补底色（Logo 类）
}

enum IconMaker {
    static let canvas: CGFloat = 1024
    static let box: CGFloat = 824
    static let radius: CGFloat = 824 * 0.224

    /// 按规格把图片绘制到 1024 画布上。zoom 在 fill 模式基础上再放大，
    /// offset 为平移量（单位：方块边长的比例，-0.5...0.5），用于手动调整裁切位置。
    static func render(_ src: NSImage, fit: IconFit, zoom: CGFloat = 1,
                       offset: CGPoint = .zero, background: NSColor = .white,
                       side: CGFloat = canvas) -> NSImage {
        let scale = side / canvas
        let b = box * scale
        let inset = (side - b) / 2
        let rect = NSRect(x: inset, y: inset, width: b, height: b)

        let img = NSImage(size: NSSize(width: side, height: side))
        img.lockFocus()
        defer { img.unlockFocus() }
        NSGraphicsContext.current?.imageInterpolation = .high

        let clip = NSBezierPath(roundedRect: rect, xRadius: radius * scale, yRadius: radius * scale)
        clip.addClip()
        background.setFill()
        rect.fill()

        let s = src.size
        guard s.width > 0, s.height > 0 else { return img }
        let base = fit == .fill ? max(b / s.width, b / s.height) : min(b / s.width, b / s.height)
        let k = base * max(zoom, 1)
        let w = s.width * k, h = s.height * k
        let x = rect.midX - w / 2 + offset.x * b
        let y = rect.midY - h / 2 + offset.y * b
        src.draw(in: NSRect(x: x, y: y, width: w, height: h),
                 from: .zero, operation: .sourceOver, fraction: 1)
        return img
    }

    /// 生成多尺寸 icns，用系统自带的 iconutil，无第三方依赖
    static func writeIcns(from icon: NSImage, to dest: String) throws {
        let fm = FileManager.default
        let work = NSTemporaryDirectory() + "wxmulti-\(UUID().uuidString).iconset"
        try fm.createDirectory(atPath: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: work) }

        for pt in [16, 32, 128, 256, 512] {
            for mult in [1, 2] {
                let px = pt * mult
                let name = mult == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
                try png(icon, px: px).write(to: URL(fileURLWithPath: work + "/" + name))
            }
        }
        let r = Core.run("/usr/bin/iconutil", ["-c", "icns", work, "-o", dest])
        if !r.ok { throw err("生成 icns 失败：\(r.out)") }
    }

    private static func png(_ img: NSImage, px: Int) throws -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw err("创建位图失败") }
        rep.size = NSSize(width: px, height: px)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:])
        else { throw err("编码 PNG 失败") }
        return data
    }

    /// 写入副本：覆盖 AppIcon.icns 并删掉 CFBundleIconName。
    /// 原版靠 CFBundleIconName 从 Assets.car 取图标，不删的话新 icns 不生效。
    /// 改了 bundle 内容必须重签，否则签名失效。
    static func apply(_ icon: NSImage, to inst: Instance) throws {
        try writeIcns(from: icon, to: inst.appPath + "/Contents/Resources/AppIcon.icns")
        try finish(inst)
    }

    /// 恢复微信原图标：从原版拷回 AppIcon.icns，并恢复 CFBundleIconName
    static func restore(_ inst: Instance) throws {
        let src = Core.baseApp + "/Contents/Resources/AppIcon.icns"
        let dst = inst.appPath + "/Contents/Resources/AppIcon.icns"
        let fm = FileManager.default
        try? fm.removeItem(atPath: dst)
        try fm.copyItem(atPath: src, toPath: dst)
        let orig = NSDictionary(contentsOfFile: Core.baseApp + "/Contents/Info.plist")
        let name = orig?["CFBundleIconName"] as? String ?? "AppIcon"
        let r = Core.run("/usr/libexec/PlistBuddy",
                         ["-c", "Add :CFBundleIconName string \(name)", plist(inst)])
        if !r.ok { throw err("恢复图标配置失败：\(r.out)") }
        try resign(inst)
    }

    private static func finish(_ inst: Instance) throws {
        if !inst.isBase, Core.hasCustomIcon(inst.appPath) == false {
            let r = Core.run("/usr/libexec/PlistBuddy", ["-c", "Delete :CFBundleIconName", plist(inst)])
            if !r.ok { throw err("修改图标配置失败：\(r.out)") }
        }
        try resign(inst)
    }

    private static func resign(_ inst: Instance) throws {
        let r = Core.sign(inst.appPath)
        if !r.ok { throw err("重新签名失败：\(r.out)") }
        // 刷新图标缓存：touch 改 mtime，lsregister 重新登记，Dock 才会换图标
        Core.run("/usr/bin/touch", [inst.appPath])
        Ops.registerWithLaunchServices(inst.appPath)
    }

    private static func plist(_ inst: Instance) -> String {
        inst.appPath + "/Contents/Info.plist"
    }

    private static func err(_ msg: String) -> NSError {
        NSError(domain: "wxmulti", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}

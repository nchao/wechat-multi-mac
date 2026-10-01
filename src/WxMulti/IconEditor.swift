// 图标编辑面板：选图 → 预览 → 自动或手动调整缩放与裁切 → 应用到副本

import AppKit

/// 可拖拽的预览视图：拖动平移裁切位置，滚轮或触控板缩放
final class IconPreview: NSView {
    var onPan: ((CGPoint) -> Void)?
    var onZoom: ((CGFloat) -> Void)?
    var image: NSImage? { didSet { needsDisplay = true } }
    private var last: NSPoint?

    override func draw(_ dirtyRect: NSRect) {
        // 棋盘格底，看得出透明留白
        let cell: CGFloat = 8
        for i in 0..<Int(bounds.width / cell) + 1 {
            for j in 0..<Int(bounds.height / cell) + 1 where (i + j) % 2 == 0 {
                NSColor.quaternaryLabelColor.setFill()
                NSRect(x: CGFloat(i) * cell, y: CGFloat(j) * cell, width: cell, height: cell).fill()
            }
        }
        image?.draw(in: bounds)
    }

    override func mouseDown(with e: NSEvent) { last = convert(e.locationInWindow, from: nil) }
    override func mouseUp(with e: NSEvent) { last = nil }
    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        guard let l = last else { return }
        last = p
        // 换算成方块边长的比例，与 IconMaker.render 的 offset 单位一致
        let box = bounds.width * IconMaker.box / IconMaker.canvas
        onPan?(CGPoint(x: (p.x - l.x) / box, y: (p.y - l.y) / box))
    }
    override func scrollWheel(with e: NSEvent) { onZoom?(e.scrollingDeltaY * 0.01) }
    override func magnify(with e: NSEvent) { onZoom?(e.magnification) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

final class IconEditor: NSObject {
    private let inst: Instance
    private var source: NSImage?
    private var fit: IconFit = .fill
    private var zoom: CGFloat = 1
    private var offset: CGPoint = .zero
    private var background: NSColor = .white

    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 400),
                                styleMask: [.titled], backing: .buffered, defer: false)
    private let preview = IconPreview()
    private let mode = NSSegmentedControl(labels: ["铺满裁切", "完整显示"], trackingMode: .selectOne,
                                          target: nil, action: nil)
    private let zoomSlider = NSSlider(value: 1, minValue: 1, maxValue: 4, target: nil, action: nil)
    private let colorWell = NSColorWell()
    private let hint = NSTextField(labelWithString: "")
    private let applyButton = NSButton(title: "应用", target: nil, action: nil)
    private var done: ((Bool) -> Void)?

    init(instance: Instance) {
        self.inst = instance
        super.init()
        build()
    }

    /// 以 sheet 形式挂在主窗口上。先让用户选图，取消就不弹面板。
    func begin(on window: NSWindow, done: @escaping (Bool) -> Void) {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.image]
        open.allowsMultipleSelection = false
        open.message = "选择「\(inst.name)」的图标图片（任意尺寸，下一步可调整）"
        open.beginSheetModal(for: window) { [self] r in
            guard r == .OK, let url = open.url, let img = NSImage(contentsOf: url),
                  img.size.width > 0 else { done(false); return }
            self.source = img
            self.autoFit(img)
            self.refresh()
            self.done = done
            window.beginSheet(self.panel)
        }
    }

    // MARK: - 界面

    private func build() {
        let title = NSTextField(labelWithString: "调整图标")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.onPan = { [weak self] d in
            guard let self, self.fit == .fill || self.zoom > 1 else { return }
            self.offset.x += d.x; self.offset.y += d.y
            self.clampOffset(); self.refresh()
        }
        preview.onZoom = { [weak self] d in
            guard let self else { return }
            self.zoom = min(4, max(1, self.zoom + d))
            self.zoomSlider.doubleValue = self.zoom
            self.clampOffset(); self.refresh()
        }

        mode.target = self
        mode.action = #selector(modeChanged)
        zoomSlider.target = self
        zoomSlider.action = #selector(zoomChanged)
        zoomSlider.translatesAutoresizingMaskIntoConstraints = false
        colorWell.target = self
        colorWell.action = #selector(colorChanged)
        colorWell.color = background
        colorWell.translatesAutoresizingMaskIntoConstraints = false

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 2

        let zoomRow = row([label("缩放"), zoomSlider])
        let colorRow = row([label("底色"), colorWell])

        let reset = NSButton(title: "自动", target: self, action: #selector(resetAuto))
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        applyButton.target = self
        applyButton.action = #selector(apply)
        applyButton.keyEquivalent = "\r"
        let buttons = row([reset, NSView(), cancel, applyButton])

        let stack = NSStackView(views: [title, preview, mode, zoomRow, colorRow, hint, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = stack

        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 340),
            preview.widthAnchor.constraint(equalToConstant: 200),
            preview.heightAnchor.constraint(equalToConstant: 200),
            preview.centerXAnchor.constraint(equalTo: stack.centerXAnchor),
            zoomSlider.widthAnchor.constraint(equalToConstant: 220),
            colorWell.widthAnchor.constraint(equalToConstant: 44),
            colorWell.heightAnchor.constraint(equalToConstant: 22),
            hint.widthAnchor.constraint(equalToConstant: 300),
            buttons.widthAnchor.constraint(equalToConstant: 300),
        ])
    }

    private func label(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: 12)
        t.widthAnchor.constraint(equalToConstant: 32).isActive = true
        return t
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = 8
        return s
    }

    // MARK: - 自动适配

    /// 自动判断：接近正方形（宽高比 0.8–1.25）铺满裁切；
    /// 明显偏长或偏宽的（如横幅 Logo）完整显示，底色取图片边缘的平均色，避免白边突兀。
    private func autoFit(_ img: NSImage) {
        let r = img.size.width / img.size.height
        fit = (0.8...1.25).contains(r) ? .fill : .fit
        zoom = 1
        offset = .zero
        background = edgeColor(img) ?? .white
        mode.selectedSegment = fit.rawValue
        zoomSlider.doubleValue = 1
        colorWell.color = background
    }

    private func edgeColor(_ img: NSImage) -> NSColor? {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              rep.pixelsWide > 2, rep.pixelsHigh > 2 else { return nil }
        let w = rep.pixelsWide, h = rep.pixelsHigh
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, n: CGFloat = 0
        let step = max(1, min(w, h) / 40)
        func add(_ x: Int, _ y: Int) {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                  c.alphaComponent > 0.5 else { return }
            r += c.redComponent; g += c.greenComponent; b += c.blueComponent; n += 1
        }
        for x in stride(from: 0, to: w, by: step) { add(x, 0); add(x, h - 1) }
        for y in stride(from: 0, to: h, by: step) { add(0, y); add(w - 1, y) }
        guard n > 0 else { return nil }   // 边缘全透明，用默认白底
        return NSColor(deviceRed: r / n, green: g / n, blue: b / n, alpha: 1)
    }

    /// 限制平移范围，不让图片拖出方块露出底色
    private func clampOffset() {
        guard let s = source?.size, s.width > 0, s.height > 0 else { return }
        let b = IconMaker.box
        let base = fit == .fill ? max(b / s.width, b / s.height) : min(b / s.width, b / s.height)
        let k = base * zoom
        let maxX = max(0, (s.width * k - b) / 2) / b
        let maxY = max(0, (s.height * k - b) / 2) / b
        offset.x = min(maxX, max(-maxX, offset.x))
        offset.y = min(maxY, max(-maxY, offset.y))
    }

    private func refresh() {
        guard let src = source else { return }
        preview.image = IconMaker.render(src, fit: fit, zoom: zoom, offset: offset,
                                         background: background, side: 400)
        let s = src.size
        let canPan = fit == .fill || zoom > 1
        // 图标最大用到 1024px，原图太小放大后会糊，提前说一声
        let small = min(s.width, s.height) < 256 ? "原图较小，放大后会模糊。" : ""
        hint.stringValue = "原图 \(Int(s.width))×\(Int(s.height))。\(small)"
            + (canPan ? "拖动预览调整裁切位置，滚轮或双指缩放。" : "图片完整显示，空白处用底色填充。")
        colorWell.isEnabled = fit == .fit || zoom == 1
    }

    // MARK: - 动作

    @objc private func modeChanged() {
        fit = IconFit(rawValue: mode.selectedSegment) ?? .fill
        offset = .zero
        clampOffset(); refresh()
    }

    @objc private func zoomChanged() {
        zoom = CGFloat(zoomSlider.doubleValue)
        clampOffset(); refresh()
    }

    @objc private func colorChanged() {
        background = colorWell.color
        refresh()
    }

    @objc private func resetAuto() {
        guard let src = source else { return }
        autoFit(src); refresh()
    }

    @objc private func cancel() { close(false) }

    @objc private func apply() {
        guard let src = source else { return }
        let icon = IconMaker.render(src, fit: fit, zoom: zoom, offset: offset, background: background)
        applyButton.isEnabled = false
        let target = inst
        DispatchQueue.global(qos: .userInitiated).async {
            let error: Error?
            do { try IconMaker.apply(icon, to: target); error = nil } catch let e { error = e }
            DispatchQueue.main.async {
                self.applyButton.isEnabled = true
                if let error {
                    let a = NSAlert(error: error)
                    a.beginSheetModal(for: self.panel)
                    return
                }
                self.close(true)
            }
        }
    }

    private func close(_ ok: Bool) {
        panel.sheetParent?.endSheet(panel)
        done?(ok)
        done = nil
    }
}

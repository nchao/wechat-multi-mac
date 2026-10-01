// 主窗口：NSTableView 列表 + 底部 +/− 分段按钮，对齐「系统设置 → 登录项」的观感。

import AppKit

final class MainWindowController: NSWindowController {
    private var rows: [Instance] = []

    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let addRemove = NSSegmentedControl()
    private let launchButton = NSButton()
    private let iconButton = NSButton()
    private var iconEditor: IconEditor?
    private let statusLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()

    convenience init() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        w.title = "微信多开"
        w.minSize = NSSize(width: 460, height: 300)
        w.center()
        self.init(window: w)
        buildUI()
        reload()
        observeApps()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// 微信启动或退出时系统会发通知，据此实时更新「状态」列。
    /// 以前只在 reload 时查一次进程，退出微信后列表仍显示运行中。
    private func observeApps() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(self, selector: #selector(appStateChanged(_:)), name: name, object: nil)
        }
    }

    @objc private func appStateChanged(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let exe = app.executableURL?.path,
              let i = rows.firstIndex(where: { $0.binPath == exe }) else { return }
        // 只改这一行的运行状态，不做全量 scan（scan 要跑 du，几个 G 的目录会卡）
        rows[i].running = (note.name == NSWorkspace.didLaunchApplicationNotification)
        table.reloadData(forRowIndexes: [i], columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        updateButtons()
    }

    // MARK: - 构建界面

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let title = NSTextField(labelWithString: "微信实例")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let subtitle = NSTextField(labelWithString: "双击一行启动。＋ 新建副本，－ 卸载，右键可更换图标。")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor

        // 表格
        table.rowHeight = 30
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(launchSelected)
        table.menu = rowMenu()

        let colName = NSTableColumn(identifier: .init("name"))
        colName.title = "名称"
        colName.width = 270
        colName.minWidth = 160
        table.addTableColumn(colName)

        let colState = NSTableColumn(identifier: .init("state"))
        colState.title = "状态"
        colState.width = 80
        colState.minWidth = 70
        table.addTableColumn(colState)

        let colSize = NSTableColumn(identifier: .init("size"))
        colSize.title = "聊天数据"
        colSize.width = 72
        colSize.minWidth = 64
        table.addTableColumn(colSize)

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // 底部 +/−，与系统设置一致的 small/texturedRounded 外观
        addRemove.segmentCount = 2
        addRemove.segmentStyle = .texturedRounded
        addRemove.controlSize = .small
        addRemove.setImage(NSImage(systemSymbolName: "plus", accessibilityDescription: "新建副本"), forSegment: 0)
        addRemove.setImage(NSImage(systemSymbolName: "minus", accessibilityDescription: "卸载副本"), forSegment: 1)
        addRemove.setWidth(30, forSegment: 0)
        addRemove.setWidth(30, forSegment: 1)
        addRemove.trackingMode = .momentary
        addRemove.target = self
        addRemove.action = #selector(addRemoveClicked)
        addRemove.translatesAutoresizingMaskIntoConstraints = false

        launchButton.title = "启动"
        launchButton.bezelStyle = .rounded
        launchButton.keyEquivalent = "\r"
        launchButton.target = self
        launchButton.action = #selector(launchSelected)
        launchButton.translatesAutoresizingMaskIntoConstraints = false

        iconButton.title = "更换图标…"
        iconButton.bezelStyle = .rounded
        iconButton.controlSize = .small
        iconButton.target = self
        iconButton.action = #selector(changeIcon)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.isHidden = true
        bar.controlSize = .small

        let header = NSStackView(views: [title, subtitle])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 2

        let footer = NSStackView(views: [addRemove, iconButton, NSView(), statusLabel, launchButton])
        footer.orientation = .horizontal
        footer.spacing = 8

        let root = NSStackView(views: [header, scroll, bar, footer])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
            bar.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            footer.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
        ])
    }

    // MARK: - 数据

    private var reloadGen = 0

    /// 两段加载：先出不含数据大小的列表，再逐个补算 du。
    /// 几个 G 的数据目录冷启动 du 要好几秒，不能让整张表等它。
    func reload() {
        reloadGen += 1
        let gen = reloadGen
        DispatchQueue.global(qos: .userInitiated).async {
            let fresh = Core.scan(withSize: false)
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.reloadGen else { return }
                let keep = Set(self.selected.map(\.name))
                self.rows = fresh
                self.table.reloadData()
                let restore = IndexSet(self.rows.indices.filter { keep.contains(self.rows[$0].name) })
                if !restore.isEmpty { self.table.selectRowIndexes(restore, byExtendingSelection: false) }
                self.updateButtons()
                self.fillSizes(gen)
            }
        }
    }

    private func fillSizes(_ gen: Int) {
        let targets = rows.map { ($0.name, Core.containerPath(for: $0.isBase ? Core.baseId : Core.id(for: $0.name))) }
        DispatchQueue.global(qos: .utility).async {
            for (name, path) in targets {
                let size = Core.dirSize(path)
                DispatchQueue.main.async { [weak self] in
                    guard let self, gen == self.reloadGen,
                          let i = self.rows.firstIndex(where: { $0.name == name }) else { return }
                    self.rows[i].dataSize = size
                    let col = self.table.column(withIdentifier: .init("size"))
                    if col >= 0 { self.table.reloadData(forRowIndexes: [i], columnIndexes: [col]) }
                }
            }
        }
    }

    private func updateButtons() {
        let sel = table.selectedRowIndexes
        launchButton.isEnabled = !sel.isEmpty
        // 只有选中非原版的行才能卸载
        let removable = sel.contains { rows.indices.contains($0) && !rows[$0].isBase }
        addRemove.setEnabled(removable, forSegment: 1)
        // 换图标只针对单个副本：原版不动，运行中改签名可能让进程异常
        iconButton.isEnabled = iconTarget != nil
    }

    /// 可换图标的目标：恰好选中一个、非原版、未运行的副本
    private var iconTarget: Instance? {
        let s = selected
        guard s.count == 1, let i = s.first, !i.isBase, !i.running else { return nil }
        return i
    }

    private var selected: [Instance] {
        table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
    }

    // MARK: - 动作

    @objc private func addRemoveClicked() {
        if addRemove.selectedSegment == 0 { createNew() } else { uninstallSelected() }
    }

    @objc private func launchSelected() {
        let targets = selected
        guard !targets.isEmpty else { return }
        setBusy(true)
        Ops.launch(targets, progress: { [weak self] p in
            self?.showProgress(p)
        }, done: { [weak self] errors in
            self?.finish(errors)
        })
    }

    private func createNew() {
        let alert = NSAlert()
        alert.messageText = "新建副本"
        alert.informativeText = "副本名决定数据目录。多个名字用空格分隔，不要带 .app。"
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = Core.nextFreeName()
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let names = field.stringValue
            .components(separatedBy: .whitespaces)
            .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }
            .filter { !$0.isEmpty }

        var valid: [String] = []
        var bad: [String] = []
        for n in names {
            if n.contains("/") || n.hasPrefix(".") || n == "WeChat" {
                bad.append(n)
            } else {
                valid.append(n)
            }
        }
        if !bad.isEmpty {
            warn("名字不合法", "不能含 /、不能以 . 开头、不能叫 WeChat：\n" + bad.joined(separator: "、"))
        }
        guard !valid.isEmpty else { return }

        setBusy(true)
        Ops.create(names: valid, progress: { [weak self] p in
            self?.showProgress(p)
        }, done: { [weak self] errors in
            self?.finish(errors)
        })
    }

    private func uninstallSelected() {
        let targets = selected.filter { !$0.isBase }
        guard !targets.isEmpty else { return }

        if let running = targets.first(where: { $0.running }) {
            warn("请先退出微信", "「\(running.name)」正在运行，退出后再卸载。")
            return
        }

        let names = targets.map(\.name).joined(separator: "、")
        let alert = NSAlert()
        alert.messageText = "卸载 \(names)？"
        alert.informativeText = "应用会移入废纸篓，可以恢复。\n聊天数据保存在 ~/Library/Containers，选择「一起删除」才会移走。"
        alert.addButton(withTitle: "保留数据")
        alert.addButton(withTitle: "一起删除")
        alert.addButton(withTitle: "取消")
        alert.buttons[1].hasDestructiveAction = true

        let r = alert.runModal()
        guard r != .alertThirdButtonReturn else { return }
        let purge = (r == .alertSecondButtonReturn)

        setBusy(true)
        Ops.uninstall(targets, purge: purge, progress: { [weak self] p in
            self?.showProgress(p)
        }, done: { [weak self] errors in
            self?.finish(errors)
        })
    }

    // MARK: - 图标

    @objc private func changeIcon() {
        guard let target = iconTarget, let win = window else {
            if let s = selected.first, s.running {
                warn("请先退出微信", "「\(s.name)」正在运行。换图标需要重新签名，退出后再换。")
            }
            return
        }
        let editor = IconEditor(instance: target)
        iconEditor = editor
        editor.begin(on: win) { [weak self] ok in
            self?.iconEditor = nil
            if ok { self?.reload() }
        }
    }

    @objc private func restoreIcon() {
        guard let target = iconTarget, target.customIcon else { return }
        do {
            try IconMaker.restore(target)
            reload()
        } catch {
            warn("恢复失败", error.localizedDescription)
        }
    }

    private func rowMenu() -> NSMenu {
        let m = NSMenu()
        m.delegate = self
        // 关掉自动启用，菜单项的 isEnabled 才由 menuNeedsUpdate 决定
        m.autoenablesItems = false
        return m
    }

    // MARK: - 状态显示

    private func setBusy(_ busy: Bool) {
        bar.isHidden = !busy
        bar.doubleValue = 0
        launchButton.isEnabled = !busy
        addRemove.isEnabled = !busy
        iconButton.isEnabled = !busy
        table.isEnabled = !busy
        if !busy { statusLabel.stringValue = "" }
    }

    private func showProgress(_ p: Ops.Progress) {
        statusLabel.stringValue = p.text
        bar.doubleValue = p.fraction
    }

    private func finish(_ errors: [String]) {
        setBusy(false)
        reload()
        if !errors.isEmpty {
            warn("部分未完成", errors.joined(separator: "\n"))
        }
    }

    private func warn(_ title: String, _ detail: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = detail
        a.alertStyle = .warning
        a.runModal()
    }
}

// MARK: - 表格数据源

extension MainWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let col = tableColumn else { return nil }
        let item = rows[row]

        switch col.identifier.rawValue {
        case "name":
            let cell = NSTableCellView()
            let icon = NSImageView(image: Core.icon(for: item.appPath))
            icon.translatesAutoresizingMaskIntoConstraints = false

            var label = item.name
            if item.isBase { label += "（原版）" }
            let text = NSTextField(labelWithString: label)
            text.font = .systemFont(ofSize: 13)
            if item.idMismatch {
                // 标识不对的副本点图标会跳回原版窗口，在列表里就标出来
                text.stringValue = label + "  ⚠︎ 标识未生效"
                text.textColor = .systemOrange
            }

            let stack = NSStackView(views: [icon, text])
            stack.orientation = .horizontal
            stack.spacing = 8
            stack.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(stack)
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 20),
                icon.heightAnchor.constraint(equalToConstant: 20),
                stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            ])
            return cell

        case "state":
            let text = NSTextField(labelWithString: item.running ? "● 运行中" : "○ 已停止")
            text.font = .systemFont(ofSize: 12)
            text.textColor = item.running ? .systemGreen : .secondaryLabelColor
            return wrap(text, in: .left)

        case "size":
            let text = NSTextField(labelWithString: item.dataSize)
            text.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            text.textColor = .secondaryLabelColor
            text.alignment = .right
            return wrap(text, in: .right)

        default:
            return nil
        }
    }

    /// 裸 NSTextField 不受列宽约束，包进 cell view 才能跟表头对齐
    private func wrap(_ field: NSTextField, in side: NSTextAlignment) -> NSTableCellView {
        let cell = NSTableCellView()
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        var c: [NSLayoutConstraint] = [
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ]
        if side == .right {
            c.append(field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4))
        } else {
            c.append(field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2))
        }
        NSLayoutConstraint.activate(c)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }
}

// MARK: - 右键菜单

extension MainWindowController: NSMenuDelegate {
    /// 右键点在未选中的行上时，先选中那一行，菜单才对它生效
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let r = table.clickedRow
        guard rows.indices.contains(r) else { return }
        if !table.selectedRowIndexes.contains(r) {
            table.selectRowIndexes([r], byExtendingSelection: false)
        }
        let item = rows[r]

        menu.addItem(withTitle: item.running ? "激活窗口" : "启动",
                     action: #selector(launchSelected), keyEquivalent: "").target = self
        if item.isBase { return }

        menu.addItem(.separator())
        let change = menu.addItem(withTitle: "更换图标…", action: #selector(changeIcon), keyEquivalent: "")
        change.target = self
        change.isEnabled = iconTarget != nil
        if item.customIcon {
            let restore = menu.addItem(withTitle: "恢复微信原图标", action: #selector(restoreIcon), keyEquivalent: "")
            restore.target = self
            restore.isEnabled = !item.running
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "在访达中显示", action: #selector(revealInFinder), keyEquivalent: "").target = self
    }

    @objc private func revealInFinder() {
        let urls = selected.map { URL(fileURLWithPath: $0.appPath) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

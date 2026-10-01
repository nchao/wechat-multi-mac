// 主窗口：NSTableView 列表 + 底部 +/− 分段按钮，对齐「系统设置 → 登录项」的观感。

import AppKit

final class MainWindowController: NSWindowController {
    private var rows: [Instance] = []

    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let addRemove = NSSegmentedControl()
    private let launchButton = NSButton()
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
    }

    // MARK: - 构建界面

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let title = NSTextField(labelWithString: "微信实例")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let subtitle = NSTextField(labelWithString: "双击一行启动，或选中后点「启动」。＋ 新建副本，－ 卸载。")
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

        let footer = NSStackView(views: [addRemove, NSView(), statusLabel, launchButton])
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

    func reload() {
        let keep = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].name : nil })
        rows = Core.scan()
        table.reloadData()
        let restore = IndexSet(rows.indices.filter { keep.contains(rows[$0].name) })
        if !restore.isEmpty { table.selectRowIndexes(restore, byExtendingSelection: false) }
        updateButtons()
    }

    private func updateButtons() {
        let sel = table.selectedRowIndexes
        launchButton.isEnabled = !sel.isEmpty
        // 只有选中非原版的行才能卸载
        let removable = sel.contains { rows.indices.contains($0) && !rows[$0].isBase }
        addRemove.setEnabled(removable, forSegment: 1)
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

    // MARK: - 状态显示

    private func setBusy(_ busy: Bool) {
        bar.isHidden = !busy
        bar.doubleValue = 0
        launchButton.isEnabled = !busy
        addRemove.isEnabled = !busy
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

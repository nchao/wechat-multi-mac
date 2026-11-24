// 主窗口：NSTableView 列表 + 底部 +/− 分段按钮，对齐「系统设置 → 登录项」的观感。

import AppKit

final class MainWindowController: NSWindowController {
    private var rows: [Instance] = []

    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let addRemove = NSSegmentedControl()
    private let launchButton = NSButton()
    private let quitAfterLaunch = NSButton(checkboxWithTitle: "启动后关闭本工具", target: nil, action: nil)
    private let iconButton = NSButton()

    /// 勾选状态记在偏好里，默认勾上
    private static let quitAfterLaunchKey = "quitAfterLaunch"
    private var iconEditor: IconEditor?
    private let statusLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()

    convenience init() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 610, height: 340),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        w.title = "微信多开"
        w.minSize = NSSize(width: 540, height: 300)
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
              let i = rows.firstIndex(where: { !$0.orphan && $0.binPath == exe }) else { return }
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
        colName.width = 210
        colName.minWidth = 140
        table.addTableColumn(colName)

        let colState = NSTableColumn(identifier: .init("state"))
        colState.title = "状态"
        colState.width = 80
        colState.minWidth = 70
        table.addTableColumn(colState)

        let colVersion = NSTableColumn(identifier: .init("version"))
        colVersion.title = "微信版本"
        colVersion.width = 66
        colVersion.minWidth = 56
        table.addTableColumn(colVersion)

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

        UserDefaults.standard.register(defaults: [Self.quitAfterLaunchKey: true])
        quitAfterLaunch.controlSize = .small
        quitAfterLaunch.font = .systemFont(ofSize: 11)
        quitAfterLaunch.state = UserDefaults.standard.bool(forKey: Self.quitAfterLaunchKey) ? .on : .off
        quitAfterLaunch.target = self
        quitAfterLaunch.action = #selector(quitAfterLaunchToggled)
        quitAfterLaunch.toolTip = "启动的副本都起来后自动退出「微信多开」。出错时不退出，方便查看原因。"

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

        let footer = NSStackView(views: [addRemove, iconButton, NSView(), statusLabel, quitAfterLaunch, launchButton])
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
                let keep = Set(self.selected.map(\.key))
                self.rows = fresh
                self.table.reloadData()
                let restore = IndexSet(self.rows.indices.filter { keep.contains(self.rows[$0].key) })
                if !restore.isEmpty { self.table.selectRowIndexes(restore, byExtendingSelection: false) }
                self.updateButtons()
                self.fillSizes(gen)
            }
        }
    }

    private func fillSizes(_ gen: Int) {
        let targets = rows.map { ($0.key, Core.containerPath(for: $0.dataId)) }
        DispatchQueue.global(qos: .utility).async {
            for (key, path) in targets {
                let size = Core.dirSize(path)
                DispatchQueue.main.async { [weak self] in
                    guard let self, gen == self.reloadGen,
                          let i = self.rows.firstIndex(where: { $0.key == key }) else { return }
                    self.rows[i].dataSize = size
                    let col = self.table.column(withIdentifier: .init("size"))
                    if col >= 0 { self.table.reloadData(forRowIndexes: [i], columnIndexes: [col]) }
                }
            }
        }
    }

    private func updateButtons() {
        let sel = table.selectedRowIndexes
        // 残留数据没有 app，不能启动；要用得先右键「重建副本」
        launchButton.isEnabled = selected.contains { !$0.orphan }
        // 只有选中非原版的行才能卸载（选中残留数据时「－」是删除数据）
        let removable = sel.contains { rows.indices.contains($0) && !rows[$0].isBase }
        addRemove.setEnabled(removable, forSegment: 1)
        // 换图标只针对单个副本：原版不动，运行中改签名可能让进程异常
        iconButton.isEnabled = iconTarget != nil
    }

    /// 可换图标的目标：恰好选中一个、非原版、未运行的副本
    private var iconTarget: Instance? {
        let s = selected
        guard s.count == 1, let i = s.first, !i.isBase, !i.orphan, !i.running else { return nil }
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
        let targets = selected.filter { !$0.orphan }
        guard !targets.isEmpty else { return }
        setBusy(true)
        Ops.launch(targets, progress: { [weak self] p in
            self?.showProgress(p)
        }, done: { [weak self] errors in
            guard let self else { return }
            self.finish(errors)
            // 出错时留着窗口，让用户看到提示；全部成功才退出
            if errors.isEmpty && self.quitAfterLaunch.state == .on {
                NSApp.terminate(nil)
            }
        })
    }

    @objc private func quitAfterLaunchToggled() {
        UserDefaults.standard.set(quitAfterLaunch.state == .on, forKey: Self.quitAfterLaunchKey)
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
        let targets = selected.filter { !$0.isBase && !$0.orphan }
        guard !targets.isEmpty else {
            // 只选了残留数据：「－」就是删除数据
            deleteOrphanData()
            return
        }

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

    // MARK: - 残留数据

    @objc private func deleteOrphanData() {
        let targets = selected.filter(\.orphan)
        guard !targets.isEmpty else { return }
        let a = NSAlert()
        a.messageText = "删除 \(targets.map(\.name).joined(separator: "、")) 的聊天数据？"
        a.informativeText = "这些数据的副本已经卸载。数据目录会移入废纸篓，清空废纸篓前都可以恢复。"
        a.addButton(withTitle: "移入废纸篓")
        a.addButton(withTitle: "取消")
        a.buttons[0].hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        setBusy(true)
        Ops.trashOrphans(targets, progress: { [weak self] p in self?.showProgress(p) },
                         done: { [weak self] errors in self?.finish(errors) })
    }

    /// 用同一个名字新建副本，副本的 bundle id 和残留容器一致，原来的账号和聊天记录直接接上
    @objc private func rebuildOrphan() {
        let targets = selected.filter(\.rebuildable)
        guard !targets.isEmpty else { return }
        if let t = targets.first(where: { FileManager.default.fileExists(atPath: $0.appPath) }) {
            warn("无法重建", "/Applications 里已经有 \(t.name).app，先改名或移走它。")
            return
        }
        setBusy(true)
        Ops.create(names: targets.map(\.name), progress: { [weak self] p in self?.showProgress(p) },
                   done: { [weak self] errors in self?.finish(errors) })
    }

    // MARK: - 清理缓存

    @objc private func cleanCacheSelected() {
        let targets = selected.filter { !$0.orphan }
        guard !targets.isEmpty else { return }
        if let r = targets.first(where: { $0.running }) {
            warn("请先退出微信", "「\(r.name)」正在运行，退出后再清理缓存。")
            return
        }
        // 统计大小要跑 du，几百 MB 的目录要一两秒，放后台
        setBusy(true)
        statusLabel.stringValue = "正在统计缓存…"
        DispatchQueue.global(qos: .userInitiated).async {
            let kinds = Ops.cacheKinds(for: targets)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.setBusy(false)
                self.confirmClean(kinds, targets)
            }
        }
    }

    private func confirmClean(_ kinds: [Ops.CacheKind], _ targets: [Instance]) {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        let a = NSAlert()
        a.messageText = "清理 \(targets.map(\.name).joined(separator: "、")) 的缓存"
        a.informativeText = "清掉的内容会移入废纸篓，清空废纸篓后才真正腾出空间。聊天记录和聊天里的图片、视频、文件不受影响，那些可以在微信「设置 → 存储空间」里管理。"
        a.addButton(withTitle: "移入废纸篓")
        a.addButton(withTitle: "取消")

        let boxes = kinds.map { k -> NSButton in
            let b = NSButton(checkboxWithTitle: "\(k.title)  \(fmt.string(fromByteCount: k.bytes))",
                             target: nil, action: nil)
            b.state = k.defaultOn && k.bytes > 0 ? .on : .off
            b.isEnabled = k.bytes > 0
            b.toolTip = k.detail
            return b
        }
        let rows = zip(kinds, boxes).map { k, b -> NSView in
            let hint = NSTextField(labelWithString: k.detail)
            hint.font = .systemFont(ofSize: 11)
            hint.textColor = .secondaryLabelColor
            let v = NSStackView(views: [b, hint])
            v.orientation = .vertical
            v.alignment = .leading
            v.spacing = 1
            return v
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: CGFloat(kinds.count) * 40)
        a.accessoryView = stack

        guard a.runModal() == .alertFirstButtonReturn else { return }
        let chosen = zip(kinds, boxes).filter { $1.state == .on }.map(\.0)
        guard !chosen.isEmpty else { return }
        setBusy(true)
        Ops.cleanCaches(chosen, of: targets, progress: { [weak self] p in self?.showProgress(p) },
                        done: { [weak self] errors in self?.finish(errors) })
    }

    // MARK: - 修复

    @objc private func repairSelected() {
        let targets = selected.filter { $0.needsRepair || $0.outdated }
        guard !targets.isEmpty else { return }
        let verb = targets.allSatisfy { !$0.needsRepair } ? "同步新版" : "修复"
        if let r = targets.first(where: { $0.running }) {
            warn("请先退出微信", "「\(r.name)」正在运行，退出后再\(verb)。")
            return
        }
        let a = NSAlert()
        a.messageText = "\(verb) \(targets.map(\.name).joined(separator: "、"))？"
        let reason = verb == "同步新版"
            ? "原版微信已升级，这些副本还是旧版本。副本已关闭微信自带的自动更新，需要在这里同步。"
            : "这些副本由旧版工具创建，可能缺少沙盒权限，或没有关闭微信自带的自动更新（装不上，会反复重试拖慢电脑）。"
        a.informativeText = """
            \(reason)

            会从原版微信重新复制一份，保留副本的名字和自定义图标。聊天数据不受影响。旧副本会移入废纸篓。
            """
        a.addButton(withTitle: verb)
        a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }

        setBusy(true)
        Ops.repair(targets, progress: { [weak self] p in self?.showProgress(p) },
                   done: { [weak self] errors in self?.finish(errors) })
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
        quitAfterLaunch.isEnabled = !busy
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
            text.lineBreakMode = .byTruncatingTail
            if item.orphan {
                // 副本已卸载、数据还在。app 不存在，用通用的微信图标
                icon.image = Core.icon(for: Core.baseApp)
                icon.alphaValue = 0.4
                // 旧标识残留可能和现有副本同名（如 WeChat2），文案上区分开
                text.stringValue = label + (item.rebuildable ? "（仅剩数据）" : "（旧标识残留数据）")
                text.textColor = .tertiaryLabelColor
                cell.toolTip = item.rebuildable
                    ? "副本已卸载，聊天数据还在 ~/Library/Containers/\(item.bundleId)。右键「重建副本」可直接接上原来的账号和聊天记录，或「删除数据」移入废纸篓。"
                    : "旧版工具留下的数据目录 \(item.bundleId)，副本已迁到新标识或已卸载，这份数据不会再被使用。右键「删除数据」移入废纸篓。"
            } else if item.idMismatch {
                // 标识不对的副本点图标会跳回原版窗口，在列表里就标出来
                text.stringValue = label + "  ⚠︎ 标识未生效"
                text.textColor = .systemOrange
            } else if item.needsRepair {
                // 旧版签名有问题：要么带团队标识导致 macOS 26 起启动即崩，要么丢了沙盒权限，
                // 要么没关微信自带的自动更新（副本装不上更新，会反复重试拖慢整机）
                text.stringValue = label + "  ⚠︎ 需修复"
                text.textColor = .systemOrange
                cell.toolTip = "这个副本由旧版工具创建：在新系统上可能直接打不开、新号登录的安全验证弹不出来，或微信自带的自动更新会反复失败拖慢电脑。右键选「修复」，不影响聊天数据。"
            } else if item.outdated {
                // 副本不自己更新，原版升级后由这里同步
                text.stringValue = label + "  ↑ 可同步新版"
                text.textColor = .systemBlue
                cell.toolTip = "原版微信已升级，这个副本还是旧版本。退出副本后右键选「同步新版」，聊天数据和自定义图标都会保留。"
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
            let text = NSTextField(labelWithString: item.orphan ? "已卸载" : (item.running ? "● 运行中" : "○ 已停止"))
            text.font = .systemFont(ofSize: 12)
            text.textColor = item.orphan ? .tertiaryLabelColor : (item.running ? .systemGreen : .secondaryLabelColor)
            return wrap(text, in: .left)

        case "version":
            let text = NSTextField(labelWithString: item.version.isEmpty ? "—" : item.version)
            text.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            // 落后于原版的副本用蓝色，和名称列的「可同步新版」呼应
            text.textColor = item.outdated ? .systemBlue : .secondaryLabelColor
            text.lineBreakMode = .byTruncatingTail
            let cell = wrap(text, in: .left)
            if !item.build.isEmpty { cell.toolTip = "Build \(item.build)" }
            return cell

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

        if item.orphan {
            let orphans = selected.filter(\.orphan)
            let rebuildable = orphans.filter(\.rebuildable)
            if !rebuildable.isEmpty {
                menu.addItem(withTitle: rebuildable.count > 1 ? "重建 \(rebuildable.count) 个副本" : "重建副本",
                             action: #selector(rebuildOrphan), keyEquivalent: "").target = self
            }
            menu.addItem(withTitle: orphans.count > 1 ? "删除 \(orphans.count) 份数据…" : "删除数据…",
                         action: #selector(deleteOrphanData), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "在访达中显示数据", action: #selector(revealInFinder), keyEquivalent: "").target = self
            return
        }

        menu.addItem(withTitle: item.running ? "激活窗口" : "启动",
                     action: #selector(launchSelected), keyEquivalent: "").target = self

        // 原版也能清：只动缓存，不改 app 本身
        let live = selected.filter { !$0.orphan }
        let clean = menu.addItem(withTitle: live.count > 1 ? "清理 \(live.count) 个的缓存…" : "清理缓存…",
                                 action: #selector(cleanCacheSelected), keyEquivalent: "")
        clean.target = self
        clean.isEnabled = !live.contains { $0.running }
        if item.isBase { return }

        let repairable = selected.filter { $0.needsRepair || $0.outdated }
        if !repairable.isEmpty {
            // 修复和同步新版是同一套流程：从原版重新复制，换上副本的 id 和图标
            let verb = repairable.allSatisfy { !$0.needsRepair } ? "同步新版" : "修复"
            let fix = menu.addItem(withTitle: repairable.count > 1 ? "\(verb) \(repairable.count) 个副本" : verb,
                                   action: #selector(repairSelected), keyEquivalent: "")
            fix.target = self
            fix.isEnabled = !repairable.contains { $0.running }
        }

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
        let urls = selected.map {
            URL(fileURLWithPath: $0.orphan ? Core.containerPath(for: $0.bundleId) : $0.appPath)
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

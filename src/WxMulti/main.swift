// 应用入口与菜单栏

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        guard FileManager.default.fileExists(atPath: Core.baseApp) else {
            fatal("找不到微信", "预期位置 \(Core.baseApp)，请先安装微信。")
            return
        }
        guard Core.appsWritable() else {
            fatal("没有写入权限", "当前账户对 /Applications 没有写权限，需要管理员账户。")
            return
        }

        let c = MainWindowController()
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        controller = c
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func fatal(_ title: String, _ detail: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = detail
        a.alertStyle = .critical
        a.runModal()
        NSApp.terminate(nil)
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于微信多开", action: #selector(about), keyEquivalent: "")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "刷新列表", action: #selector(refresh), keyEquivalent: "r")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // 编辑菜单：让输入框支持 Cmd+C/V/A 等标准快捷键
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    @objc private func refresh() { controller?.reload() }

    @objc private func about() {
        let a = NSAlert()
        a.messageText = "微信多开"
        a.informativeText = """
            复制 WeChat.app、修改 CFBundleIdentifier 并 adhoc 重签名，\
            让每个副本拥有独立的聊天数据目录。

            不修改原版微信，不注入代码，无需管理员密码。

            核心方法来自 github.com/engrecho/Mac_dual_wechat
            """
        a.runModal()
    }
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

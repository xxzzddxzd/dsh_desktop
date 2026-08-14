import AppKit

/// Right-click menu, rebuilt fresh each time it opens so sessions and
/// server state are always current.
final class MenuController: NSObject, NSMenuDelegate {
    var onOpenPanel: (() -> Void)?
    var onOpenSession: ((String) -> Void)?
    var onOpenBrowser: (() -> Void)?
    var onToggleWindowMode: (() -> Void)?
    var onStartServer: (() -> Void)?
    var onStopServer: (() -> Void)?
    var onRestartServer: (() -> Void)?
    var onShowLogs: (() -> Void)?
    var onCheckUpdates: (() -> Void)?
    var onUpdateDsh: (() -> Void)?
    var onRecheckEnvironment: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onToggleNotifications: (() -> Void)?
    var onToggleHotkey: (() -> Void)?
    var onToggleAutoStart: (() -> Void)?
    var onToggleServiceMode: (() -> Void)?
    var onToggleManageServer: (() -> Void)?
    var onLaunchDshInTerminal: (() -> Void)?
    var onToggleLaunchAtLogin: (() -> Void)?
    var onInstallToApplications: (() -> Void)?
    var onQuit: (() -> Void)?

    private let menu = NSMenu()

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    func popUp(relativeTo button: NSStatusBarButton) {
        rebuild()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    private func rebuild() {
        menu.removeAllItems()
        let snap = AppState.shared.snapshot()

        // Actions
        menu.addItem(item("打开 DSH 面板", "⌃⌥D", #selector(openPanel)))
        menu.addItem(item("在浏览器中打开", "", #selector(openBrowser)))
        let windowItem = item("窗口模式", "", #selector(toggleWindowMode))
        windowItem.state = Settings.shared.windowMode ? .on : .off
        menu.addItem(windowItem)
        menu.addItem(.separator())

        // Live sessions, grouped by project (working directory).
        let sessions = Array(snap.sessions.prefix(24))
        if sessions.isEmpty {
            let none = NSMenuItem(title: "暂无会话", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            addSessionGroups(sessions, to: menu)
        }
        menu.addItem(.separator())

        // Server section
        let serverLine: String
        if snap.serverStarting {
            serverLine = "服务器：正在启动…"
        } else if snap.serverRunning {
            let mode = snap.serverService ? "launchd 服务" : (snap.serverOwned ? "本应用托管" : "外部实例")
            var line = "服务器：运行中（\(mode)）"
            if !snap.serverVersion.isEmpty { line += " · v\(snap.serverVersion)" }
            serverLine = line
        } else {
            serverLine = "服务器：离线" + (snap.serverError.isEmpty ? "" : " · \(snap.serverError)")
        }
        let serverStatus = NSMenuItem(title: serverLine, action: nil, keyEquivalent: "")
        serverStatus.isEnabled = false
        menu.addItem(serverStatus)

        if Settings.shared.manageServer {
            let startItem = item("启动服务", "", #selector(startServer))
            startItem.isEnabled = !snap.serverRunning && !snap.serverStarting
            let stopItem = item("停止服务", "", #selector(stopServer))
            stopItem.isEnabled = snap.serverOwned || snap.serverService
            let restartItem = item("重启服务", "", #selector(restartServer))
            restartItem.isEnabled = snap.serverOwned || snap.serverService
            menu.addItem(startItem)
            menu.addItem(stopItem)
            menu.addItem(restartItem)
        } else {
            menu.addItem(item("在终端中启动 DSH…", "", #selector(launchDshInTerminal)))
        }
        menu.addItem(item("查看服务日志…", "", #selector(showLogs)))

        // DSH runtime maintenance
        if let available = UpdateManager.shared.availableVersion, !available.isEmpty {
            menu.addItem(item("更新 DSH 到 v\(available)…", "", #selector(updateDsh)))
        }
        menu.addItem(item("检查 DSH 更新…", "", #selector(checkUpdates)))
        menu.addItem(item("重新检测 DSH 环境…", "", #selector(recheckEnvironment)))
        menu.addItem(.separator())

        // Preferences
        let notifyItem = item("通知", "", #selector(toggleNotifications))
        notifyItem.state = Settings.shared.notificationsEnabled ? .on : .off
        menu.addItem(notifyItem)

        let hotkeyItem = item("全局快捷键 ⌃⌥D", "", #selector(toggleHotkey))
        hotkeyItem.state = Settings.shared.hotkeyEnabled ? .on : .off
        menu.addItem(hotkeyItem)

        let manageItem = item("应用托管 DSH（实验）", "", #selector(toggleManageServer))
        manageItem.state = Settings.shared.manageServer ? .on : .off
        menu.addItem(manageItem)

        if Settings.shared.manageServer {
            let autoStartItem = item("服务自动启动", "", #selector(toggleAutoStart))
            autoStartItem.state = Settings.shared.autoStartServer ? .on : .off
            menu.addItem(autoStartItem)

            let serviceItem = item("系统服务模式（launchd）", "", #selector(toggleServiceMode))
            serviceItem.state = Settings.shared.serverServiceMode ? .on : .off
            menu.addItem(serviceItem)
        }

        let loginItem = item("开机自启", "", #selector(toggleLaunchAtLogin))
        loginItem.state = Settings.shared.launchAtLogin ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(item("设置…", "", #selector(openSettings)))

        if !isInstalledInApplications() {
            menu.addItem(item("安装到「应用程序」…", "", #selector(installToApplications)))
        }
        menu.addItem(.separator())
        menu.addItem(item("退出 DSH Desktop", "q", #selector(quit)))
    }

    private func item(_ title: String, _ key: String, _ action: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        return mi
    }

    /// Adds sessions to the menu grouped by project; a single group stays flat.
    private func addSessionGroups(_ sessions: [SessionState], to menu: NSMenu) {
        // Resolve project keys, disambiguating duplicate basenames with the
        // parent directory (e.g. /a/foo and /b/foo → "foo (a)" / "foo (b)").
        var basenameCounts: [String: Int] = [:]
        for s in sessions {
            if let base = projectBasename(s.cwd) { basenameCounts[base, default: 0] += 1 }
        }
        func key(for s: SessionState) -> String {
            if s.cwd.isEmpty { return "其他会话" }
            if s.cwd == NSHomeDirectory() { return "~" }
            guard let base = projectBasename(s.cwd) else { return s.cwd }
            if basenameCounts[base, default: 0] > 1 {
                let parent = (s.cwd as NSString).deletingLastPathComponent
                let parentName = (parent as NSString).lastPathComponent
                return parentName.isEmpty ? base : "\(base)（\(parentName)）"
            }
            return base
        }

        var order: [String] = []
        var grouped: [String: [SessionState]] = [:]
        for s in sessions {
            let k = key(for: s)
            if grouped[k] == nil { order.append(k) }
            grouped[k, default: []].append(s)
        }

        if order.count <= 1 {
            for s in sessions { menu.addItem(sessionItem(s)) }
            return
        }
        // Flat with group headers: no nested submenus.
        for k in order {
            guard let items = grouped[k], !items.isEmpty else { continue }
            menu.addItem(groupHeader(k, count: items.count))
            for s in items { menu.addItem(sessionItem(s)) }
        }
    }

    private func groupHeader(_ title: String, count: Int) -> NSMenuItem {
        let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        header.isEnabled = false
        let text = NSMutableAttributedString(string: "\(title) · \(count)")
        text.addAttributes([
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ], range: NSRange(location: 0, length: text.length))
        header.attributedTitle = text
        return header
    }

    private func projectBasename(_ cwd: String) -> String? {
        let base = (cwd as NSString).lastPathComponent
        return base.isEmpty ? nil : base
    }

    private func sessionItem(_ s: SessionState) -> NSMenuItem {
        let mi = NSMenuItem(title: StatusText.sessionLine(s), action: #selector(openSession(_:)), keyEquivalent: "")
        mi.target = self
        mi.representedObject = s.id
        mi.image = sessionDot(s)
        return mi
    }

    private func sessionDot(_ s: SessionState) -> NSImage? {
        let color: NSColor
        if s.waitingForUser { color = .systemBlue }
        else if s.running { color = .systemGreen }
        else { color = .tertiaryLabelColor }
        return dotImage(color: color)
    }

    private func dotImage(color: NSColor) -> NSImage {
        let size = NSSize(width: 10, height: 10)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: size.width, height: size.height)).fill()
        image.unlockFocus()
        return image
    }

    private func isInstalledInApplications() -> Bool {
        guard let bundlePath = Bundle.main.bundlePath as NSString? else { return true }
        return bundlePath.hasPrefix("/Applications/")
    }

    // MARK: - Actions

    @objc private func openPanel() { onOpenPanel?() }
    @objc private func openSession(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            onOpenSession?(id)
        }
    }
    @objc private func openBrowser() { onOpenBrowser?() }
    @objc private func toggleWindowMode() { onToggleWindowMode?() }
    @objc private func startServer() { onStartServer?() }
    @objc private func stopServer() { onStopServer?() }
    @objc private func restartServer() { onRestartServer?() }
    @objc private func showLogs() { onShowLogs?() }
    @objc private func checkUpdates() { onCheckUpdates?() }
    @objc private func updateDsh() { onUpdateDsh?() }
    @objc private func recheckEnvironment() { onRecheckEnvironment?() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func toggleNotifications() { onToggleNotifications?() }
    @objc private func toggleHotkey() { onToggleHotkey?() }
    @objc private func toggleAutoStart() { onToggleAutoStart?() }
    @objc private func toggleServiceMode() { onToggleServiceMode?() }
    @objc private func toggleManageServer() { onToggleManageServer?() }
    @objc private func launchDshInTerminal() { onLaunchDshInTerminal?() }
    @objc private func toggleLaunchAtLogin() { onToggleLaunchAtLogin?() }
    @objc private func installToApplications() { onInstallToApplications?() }
    @objc private func quit() { onQuit?() }
}

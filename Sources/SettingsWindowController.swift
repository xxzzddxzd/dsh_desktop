import AppKit
import ServiceManagement

/// Preferences window: port, server binary/workdir, toggles, login item.
final class SettingsWindowController: NSObject {
    private var window: NSWindow?
    private let portField = NSTextField(string: "")
    private let binaryField = NSTextField(string: "")
    private let workdirField = NSTextField(string: "")
    private let manageCheck = NSButton(checkboxWithTitle: "由应用托管 dsh 服务（实验）：自动拉起/守护/回收 dsh web；关闭时应用只挂载你自行启动的 dsh", target: nil, action: nil)
    private let autoStartCheck = NSButton(checkboxWithTitle: "服务未运行时自动启动", target: nil, action: nil)
    private let serviceCheck = NSButton(checkboxWithTitle: "以系统服务方式运行（launchd，登录自启/崩溃自拉起，不随本应用退出）", target: nil, action: nil)
    private let notifyCheck = NSButton(checkboxWithTitle: "启用系统通知", target: nil, action: nil)
    private let alertPopup = NSPopUpButton()
    private let notifyTurnCheck = NSButton(checkboxWithTitle: "回合完成时通知", target: nil, action: nil)
    private let notifyWaitCheck = NSButton(checkboxWithTitle: "等待你输入/授权时通知", target: nil, action: nil)
    private let notifyGoalCheck = NSButton(checkboxWithTitle: "目标事件通知（创建/完成/阻塞）", target: nil, action: nil)
    private let notifyServerCheck = NSButton(checkboxWithTitle: "服务事件通知（离线/出错）", target: nil, action: nil)
    private let hotkeyCheck = NSButton(checkboxWithTitle: "全局快捷键 ⌃⌥D 唤起面板", target: nil, action: nil)
    private let loginCheck = NSButton(checkboxWithTitle: "开机自启", target: nil, action: nil)
    private let infoLabel = NSTextField(labelWithString: "")

    var onSaved: (() -> Void)?

    func show() {
        if window == nil { build() }
        load()
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func build() {
        let s = Settings.shared
        portField.placeholderString = "3080"
        binaryField.placeholderString = s.defaultBinary()
        workdirField.placeholderString = NSHomeDirectory()

        func label(_ text: String) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.font = .systemFont(ofSize: 12, weight: .semibold)
            l.textColor = .secondaryLabelColor
            return l
        }

        alertPopup.addItems(withTitles: ["气泡（菜单栏下方弹出）", "系统通知", "两者都要"])
        let grid = NSGridView(views: [
            [label("端口"), portField],
            [label("dsh 可执行文件"), binaryField],
            [label("服务工作目录"), workdirField],
            [NSGridCell.emptyContentView, manageCheck],
            [NSGridCell.emptyContentView, autoStartCheck],
            [NSGridCell.emptyContentView, serviceCheck],
            [NSGridCell.emptyContentView, notifyCheck],
            [label("完成提醒方式"), alertPopup],
            [NSGridCell.emptyContentView, notifyTurnCheck],
            [NSGridCell.emptyContentView, notifyWaitCheck],
            [NSGridCell.emptyContentView, notifyGoalCheck],
            [NSGridCell.emptyContentView, notifyServerCheck],
            [NSGridCell.emptyContentView, hotkeyCheck],
            [NSGridCell.emptyContentView, loginCheck],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false

        infoLabel.font = .systemFont(ofSize: 11)
        infoLabel.textColor = .tertiaryLabelColor
        infoLabel.maximumNumberOfLines = 0
        infoLabel.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
        let save = NSButton(title: "保存", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        cancel.bezelStyle = .rounded
        save.bezelStyle = .rounded
        save.translatesAutoresizingMaskIntoConstraints = false
        cancel.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(grid)
        content.addSubview(infoLabel)
        content.addSubview(save)
        content.addSubview(cancel)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            infoLabel.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 12),
            infoLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            infoLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            save.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            save.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            cancel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            cancel.trailingAnchor.constraint(equalTo: save.leadingAnchor, constant: -10),
        ])

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 520),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "DSH Desktop 设置"
        w.contentView = content
        w.isReleasedWhenClosed = false
        w.center()
        window = w
    }

    private func load() {
        let s = Settings.shared
        portField.stringValue = String(s.port)
        binaryField.stringValue = s.serverBinary
        workdirField.stringValue = s.serverWorkDir
        manageCheck.state = s.manageServer ? .on : .off
        autoStartCheck.state = s.autoStartServer ? .on : .off
        serviceCheck.state = s.serverServiceMode ? .on : .off
        notifyCheck.state = s.notificationsEnabled ? .on : .off
        switch s.alertPreference {
        case "notification": alertPopup.selectItem(at: 1)
        case "both": alertPopup.selectItem(at: 2)
        default: alertPopup.selectItem(at: 0)
        }
        notifyTurnCheck.state = s.notifyTurnDone ? .on : .off
        notifyWaitCheck.state = s.notifyWaitingInput ? .on : .off
        notifyGoalCheck.state = s.notifyGoalEvents ? .on : .off
        notifyServerCheck.state = s.notifyServerEvents ? .on : .off
        hotkeyCheck.state = s.hotkeyEnabled ? .on : .off
        loginCheck.state = s.launchAtLogin ? .on : .off
        infoLabel.stringValue = "修改端口后需要重新连接服务；保存即生效。"
    }

    @objc private func cancel() {
        window?.orderOut(nil)
    }

    @objc private func save() {
        let s = Settings.shared
        let newPort = Int(portField.stringValue.trimmingCharacters(in: .whitespaces)) ?? s.port
        let oldServiceMode = s.serverServiceMode
        let oldPort = s.port
        s.port = newPort > 0 ? newPort : s.port
        s.serverBinary = binaryField.stringValue.trimmingCharacters(in: .whitespaces)
        s.serverWorkDir = workdirField.stringValue.trimmingCharacters(in: .whitespaces)
        s.manageServer = manageCheck.state == .on
        s.autoStartServer = autoStartCheck.state == .on
        s.serverServiceMode = serviceCheck.state == .on
        s.notificationsEnabled = notifyCheck.state == .on
        s.alertPreference = ["bubble", "notification", "both"][alertPopup.indexOfSelectedItem]
        s.notifyTurnDone = notifyTurnCheck.state == .on
        s.notifyWaitingInput = notifyWaitCheck.state == .on
        s.notifyGoalEvents = notifyGoalCheck.state == .on
        s.notifyServerEvents = notifyServerCheck.state == .on
        s.hotkeyEnabled = hotkeyCheck.state == .on
        applyLaunchAtLogin(loginCheck.state == .on)
        // Service-mode plumbing (install/uninstall the LaunchAgent).
        if s.serverServiceMode != oldServiceMode || s.port != oldPort {
            ServerManager.shared.applyServiceMode()
        }
        window?.orderOut(nil)
        onSaved?()
    }

    private func applyLaunchAtLogin(_ enable: Bool) {
        if #available(macOS 13.0, *) {
            do {
                let service = SMAppService.loginItem(identifier: "dev.mydsh.dsh-desktop")
                if enable {
                    try service.register()
                } else {
                    try service.unregister()
                }
                Settings.shared.launchAtLogin = enable
                return
            } catch {
                // Registering outside /Applications usually fails; surface it.
                let alert = NSAlert()
                alert.messageText = "无法设置开机自启"
                alert.informativeText = "\(error.localizedDescription)\n\n提示：先把应用「安装到「应用程序」」再试。"
                alert.runModal()
                Settings.shared.launchAtLogin = false
                loginCheck.state = .off
                return
            }
        }
        Settings.shared.launchAtLogin = enable
    }
}

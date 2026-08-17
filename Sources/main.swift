import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItemCtrl = StatusItemController()
    private let menuCtrl = MenuController()
    private let panelCtrl = PanelController()
    private let settingsCtrl = SettingsWindowController()
    private let logCtrl = LogWindowController()
    private var pollTimer: Timer?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var isTerminating = false
    private var lastDebugDump: TimeInterval = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMainMenu()

        // Wiring
        AppState.shared.onChange = { [weak self] in self?.refreshUI() }
        AppState.shared.onBubble = { [weak self] title, body, sessionId in
            BubbleController.shared.show(title: title, body: body,
                                         anchor: self?.statusItemCtrl.button,
                                         onClick: {
                guard let self, let button = self.statusItemCtrl.button else { return }
                if !sessionId.isEmpty {
                    // The bubble belongs to one session: open it and consume
                    // the queued event.
                    if !self.panelCtrl.isPopoverShown {
                        self.panelCtrl.togglePopover(relativeTo: button)
                    }
                    let title = AppState.shared.snapshot().sessions.first(where: { $0.id == sessionId })?.title ?? ""
                    self.panelCtrl.openSession(id: sessionId, title: title)
                    AppState.shared.consumeEvents(for: sessionId)
                    if self.panelCtrl.isPopoverShown { self.installDismissMonitors() }
                } else {
                    self.panelCtrl.togglePopover(relativeTo: button)
                }
            })
        }
        AppState.shared.onApproval = { [weak self] info in
            self?.showApprovalBubble(info)
        }
        AppState.shared.onApprovalResolved = { [weak self] approvalId in
            guard let self, let tag = self.approvalTags.removeValue(forKey: approvalId) else { return }
            BubbleController.shared.dismiss(tag: tag)
        }
        statusItemCtrl.onLeftClick = { [weak self] in
            guard let self, let button = self.statusItemCtrl.button else { return }
            // A queued completion is showing: click opens THAT session and
            // dequeues the event (the next queued one then surfaces).
            if let ev = AppState.shared.snapshot().statusEvent, !ev.sessionId.isEmpty {
                if !self.panelCtrl.isPopoverShown {
                    self.panelCtrl.togglePopover(relativeTo: button)
                }
                self.panelCtrl.openSession(id: ev.sessionId, title: ev.title)
                AppState.shared.consumeFrontEvent()
                if self.panelCtrl.isPopoverShown { self.installDismissMonitors() }
                return
            }
            self.panelCtrl.togglePopover(relativeTo: button)
            if self.panelCtrl.isPopoverShown { self.installDismissMonitors() }
        }
        statusItemCtrl.onRightClick = { [weak self] in
            guard let self, let button = self.statusItemCtrl.button else { return }
            self.menuCtrl.popUp(relativeTo: button)
        }

        menuCtrl.onOpenPanel = { [weak self] in
            guard let self, let button = self.statusItemCtrl.button else { return }
            self.panelCtrl.togglePopover(relativeTo: button)
        }
        menuCtrl.onOpenSession = { [weak self] id in
            guard let self, let button = self.statusItemCtrl.button else { return }
            let title = AppState.shared.snapshot().sessions.first(where: { $0.id == id })?.title ?? ""
            if !self.panelCtrl.isPopoverShown {
                self.panelCtrl.togglePopover(relativeTo: button)
            }
            self.panelCtrl.openSession(id: id, title: title)
            if self.panelCtrl.isPopoverShown {
                self.installDismissMonitors()
            }
        }
        menuCtrl.onOpenBrowser = { [weak self] in
            self?.openInBrowser()
        }
        menuCtrl.onToggleWindowMode = { [weak self] in
            self?.panelCtrl.toggleWindowMode()
        }
        menuCtrl.onStartServer = { ServerManager.shared.startServer() }
        menuCtrl.onStopServer = { ServerManager.shared.stopServer() }
        menuCtrl.onRestartServer = { ServerManager.shared.restartServer() }
        menuCtrl.onShowLogs = { [weak self] in self?.logCtrl.show() }
        menuCtrl.onCheckUpdates = { [weak self] in self?.scheduleUpdateCheck(manual: true) }
        menuCtrl.onUpdateDsh = { [weak self] in self?.confirmUpdate() }
        menuCtrl.onRecheckEnvironment = { [weak self] in self?.recheckEnvironment() }
        menuCtrl.onOpenSettings = { [weak self] in self?.settingsCtrl.show() }
        menuCtrl.onToggleNotifications = {
            let s = Settings.shared
            s.notificationsEnabled.toggle()
            if s.notificationsEnabled { Notifier.shared.requestIfNeeded() }
        }
        menuCtrl.onToggleHotkey = {
            let s = Settings.shared
            s.hotkeyEnabled.toggle()
            s.hotkeyEnabled ? HotKey.shared.install() : HotKey.shared.uninstall()
        }
        menuCtrl.onToggleAutoStart = { Settings.shared.autoStartServer.toggle() }
        menuCtrl.onToggleServiceMode = {
            let s = Settings.shared
            s.serverServiceMode.toggle()
            ServerManager.shared.applyServiceMode()
        }
        menuCtrl.onToggleManageServer = { [weak self] in
            self?.toggleManageServer()
        }
        menuCtrl.onLaunchDshInTerminal = { [weak self] in
            self?.launchDshInTerminal()
        }
        menuCtrl.onToggleLaunchAtLogin = { [weak self] in
            self?.settingsCtrl.show()
        }
        menuCtrl.onInstallToApplications = { [weak self] in
            self?.installToApplications()
        }
        menuCtrl.onQuit = { [weak self] in
            self?.quit()
        }

        panelCtrl.onOpenBrowser = { [weak self] in self?.openInBrowser() }
        panelCtrl.onOpenSettings = { [weak self] in self?.settingsCtrl.show() }
        panelCtrl.onQuit = { [weak self] in self?.quit() }
        panelCtrl.onDismiss = { [weak self] in
            self?.removeDismissMonitors()
            self?.statusItemCtrl.unfreezeForPanel()
        }
        panelCtrl.onPopoverShown = { [weak self] in
            self?.statusItemCtrl.freezeForPanel()
        }

        settingsCtrl.onSaved = { [weak self] in self?.reconfigure() }

        HotKey.shared.onTrigger = { [weak self] in
            guard let self, let button = self.statusItemCtrl.button else { return }
            self.panelCtrl.togglePopover(relativeTo: button)
        }
        if Settings.shared.hotkeyEnabled { HotKey.shared.install() }

        // Server + streams
        let port = Settings.shared.port
        ServerManager.shared.configure(port: port)
        DshStreamsBridge.start(port: port) { kind, rpcId, payload in
            if kind == "host" {
                AppState.shared.ingestHostFrame(payload)
            } else {
                AppState.shared.ingestMuxFrame(payload, rpcId: rpcId)
            }
        }
        AppState.shared.noteMuxConnected()

        // Environment gate: find the dsh CLI first; onboard the user when it
        // is missing. The server boots only once the environment is ready.
        setupAssistantHandlers()
        checkEnvironment { [weak self] outcome in
            switch outcome {
            case .ready(let path, let version):
                self?.environmentResolved(path: path, version: version)
            case .missing:
                LogStore.shared.append("未检测到 dsh 命令行工具，打开安装引导", source: "desktop")
                SetupWindowController.shared.present(mode: .onboarding)
            }
        }

        if Settings.shared.notificationsEnabled { Notifier.shared.requestIfNeeded() }

        // Poll fallback (seeds state, survives WS hiccups)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.poll()
        }
        if let pollTimer { RunLoop.main.add(pollTimer, forMode: .common) }
        poll()

        refreshUI()
        LogStore.shared.append("DSH Desktop 已启动（端口 \(port)）", source: "desktop")

        // Graceful shutdown on SIGTERM (kill / log-out): route through the
        // normal termination path so the owned server gets reaped.
        signal(SIGTERM) { _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }

        if Settings.shared.debugAutoOpen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, let button = self.statusItemCtrl.button else { return }
                self.panelCtrl.togglePopover(relativeTo: button)
                if self.panelCtrl.isPopoverShown { self.installDismissMonitors() }
                LogStore.shared.append("debug: popover shown=\(self.panelCtrl.isPopoverShown)", source: "desktop")
            }
        }
        if !Settings.shared.debugSelectId.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                let id = Settings.shared.debugSelectId
                let title = AppState.shared.snapshot().sessions.first(where: { $0.id == id })?.title ?? ""
                self?.panelCtrl.openSession(id: id, title: title)
            }
        }
        // Live DOM probe: watch defaults so probes can be triggered without
        // restarting the app (set debugProbeId / debugProbeTitle via `defaults`).
        probeTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.checkProbeRequest()
        }
        if let probeTimer { RunLoop.main.add(probeTimer, forMode: .common) }
    }

    private var lastProbeKey = ""
    private var probeTimer: Timer?

    private func checkProbeRequest() {
        let id = Settings.shared.debugProbeId
        let title = Settings.shared.debugProbeTitle
        let click = Settings.shared.debugProbeClick
        let bubble = Settings.shared.debugBubble
        if !bubble.isEmpty {
            showSampleBubble(bubble)
            Settings.shared.debugBubble = ""
            return
        }
        guard !id.isEmpty || !title.isEmpty || !click.isEmpty else {
            lastProbeKey = ""
            return
        }
        let key = id + "|" + title + "|" + click
        guard key != lastProbeKey else { return }
        lastProbeKey = key
        panelCtrl.resetProbe()
        panelCtrl.runDomProbe(needle: title, idPrefix: id, click: click)
    }

    /// Demo trigger for the bubble styles (defaults write debugBubble <kind>).
    private func showSampleBubble(_ kind: String) {
        switch kind {
        case "running":
            statusItemCtrl.demoRunning(seconds: 15)
        case "ring":
            statusItemCtrl.demoRing(seconds: 8)
        case "approval":
            BubbleController.shared.show(
                title: "需要授权 · bash",
                body: "运行 shell 命令：rm -rf node_modules && pnpm install（示例演示）",
                anchor: statusItemCtrl.button,
                ttl: 60,
                buttons: [
                    ("允许", { LogStore.shared.append("bubble-demo: 允许", source: "debug") }),
                    ("拒绝", { LogStore.shared.append("bubble-demo: 拒绝", source: "debug") }),
                ],
                tag: "demo-approval",
                onClick: nil)
        case "blocked":
            BubbleController.shared.show(
                title: "目标已阻塞",
                body: "缺少用户确认：文件策略需要切换到 workspace-write（示例演示）",
                anchor: statusItemCtrl.button, ttl: 8, onClick: nil)
        case "goal":
            BubbleController.shared.show(
                title: "目标完成",
                body: "构建并交付 DSH Desktop.app（示例演示）",
                anchor: statusItemCtrl.button, ttl: 8, onClick: nil)
        default:
            BubbleController.shared.show(
                title: "任务完成 · 示例会话",
                body: "步骤 42 · 输出 3.2k tokens · 耗时 2 分 15 秒\n已修复状态栏残留问题并完成会话跳转改造。",
                anchor: statusItemCtrl.button, ttl: 8, onClick: nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        pollTimer?.invalidate()
        removeDismissMonitors()
        DshStreamsBridge.stop()
        // A launchd service keeps running after the app quits (by design);
        // only an app-owned child process is reaped here.
        if !Settings.shared.serverServiceMode {
            ServerManager.shared.stopServer()
        }
    }

    // MARK: - Data

    private func poll() {
        let rpc = DshRpc(port: Settings.shared.port)
        rpc.call("session.list", timeout: 6) { result in
            if case .success(let value) = result {
                let dict = value as? [String: Any] ?? [:]
                let items = dict["items"] as? [[String: Any]] ?? []
                AppState.shared.ingestSessionList(items)
            }
        }
        rpc.call("workspace.list", timeout: 6) { result in
            if case .success(let value) = result,
               let dict = value as? [String: Any] {
                AppState.shared.ingestWorkspaceList(dict)
            }
        }
    }

    private func refreshUI() {
        let snap = AppState.shared.snapshot()
        statusItemCtrl.render(snap)
        panelCtrl.update(snapshot: snap)
        debugDumpIfRequested(snap)
    }

    /// DSH_DESKTOP_DUMP=1 env or `defaults write dev.mydsh.dsh-desktop debugDump 1`:
    /// write the computed status line + sessions to the log at most once per 10s.
    private func debugDumpIfRequested(_ snap: Snapshot) {
        let envOn = ProcessInfo.processInfo.environment["DSH_DESKTOP_DUMP"] != nil
        guard envOn || Settings.shared.debugDump else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastDebugDump > 10 else { return }
        lastDebugDump = now
        var lines = ["DUMP title=「\(StatusText.mainText(snap).0)」 serverRunning=\(snap.serverRunning) owned=\(snap.serverOwned) starting=\(snap.serverStarting) jobs=\(snap.activeJobs)"]
        for s in snap.sessions {
            lines.append("  " + StatusText.sessionLine(s) + " | steps=\(s.steps) turns=\(s.turns) waiting=\(s.waitingForUser)")
        }
        LogStore.shared.append(lines.joined(separator: "\n"), source: "debug")
    }

    // MARK: - Approval bubble (answer directly, no panel round-trip)

    private var approvalTags: [String: String] = [:]

    private func showApprovalBubble(_ info: ApprovalInfo) {
        let tag = UUID().uuidString
        approvalTags[info.approvalId] = tag
        let reason = info.reason.isEmpty ? "该操作需要你的批准" : info.reason
        BubbleController.shared.show(
            title: "需要授权 · \(info.toolName)",
            body: reason,
            anchor: statusItemCtrl.button,
            ttl: 60,
            buttons: [
                ("拒绝", { [weak self] in self?.respondApproval(info, outcome: "rejected", tag: tag) }),
                ("允许一次", { [weak self] in self?.respondApproval(info, outcome: "allowed-once", tag: tag) }),
                ("始终允许", { [weak self] in self?.alwaysAllow(info, tag: tag) }),
            ],
            tag: tag,
            onClick: { [weak self] in
                guard let self, let button = self.statusItemCtrl.button else { return }
                self.panelCtrl.togglePopover(relativeTo: button)
            })
    }

    /// Switch this session to danger-full-access, then allow the pending
    /// operation. The permission command is user-initiated and durable.
    private func alwaysAllow(_ info: ApprovalInfo, tag: String) {
        DshRpc(port: Settings.shared.port).executeCommand(
            sessionId: info.sessionId,
            line: "/permission danger-full-access") { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success:
                        LogStore.shared.append("当前会话已切换 danger-full-access：\(info.sessionId.prefix(13))", source: "desktop")
                        self.respondApproval(info, outcome: "allowed-once", tag: tag)
                    case .failure(let error):
                        self.approvalTags[info.approvalId] = nil
                        BubbleController.shared.dismiss(tag: tag)
                        LogStore.shared.append("始终允许失败：\(error.localizedDescription)", source: "desktop")
                        BubbleController.shared.show(
                            title: "始终允许失败",
                            body: error.localizedDescription,
                            anchor: self.statusItemCtrl.button,
                            ttl: 8,
                            onClick: nil)
                    }
                }
            }
    }

    private func respondApproval(_ info: ApprovalInfo, outcome: String, tag: String) {
        approvalTags[info.approvalId] = nil
        BubbleController.shared.dismiss(tag: tag)
        DshRpc(port: Settings.shared.port).respondApproval(info, outcome: outcome) { accepted in
            LogStore.shared.append("授权应答：\(outcome) accepted=\(accepted)", source: "desktop")
            if !accepted {
                BubbleController.shared.show(title: "授权应答失败",
                                             body: "服务端未接受该应答，请在面板中处理。",
                                             anchor: nil, ttl: 5, onClick: nil)
            }
        }
    }

    // MARK: - Actions

    private func openInBrowser() {
        let port = Settings.shared.port
        if let url = URL(string: "http://127.0.0.1:\(port)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func quit() {
        isTerminating = true
        NSApp.terminate(nil)
    }

    private func installToApplications() {
        let fm = FileManager.default
        let bundlePath = Bundle.main.bundlePath
        let bundleName = (bundlePath as NSString).lastPathComponent
        guard !bundleName.isEmpty else { return }
        let destDir = "/Applications"
        let dest = "\(destDir)/\(bundleName)"
        do {
            if fm.fileExists(atPath: dest) {
                try fm.removeItem(atPath: dest)
            }
            try fm.copyItem(atPath: bundlePath as String, toPath: dest)
        } catch {
            let alert = NSAlert()
            alert.messageText = "安装失败"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }
        LogStore.shared.append("已安装到 \(dest)", source: "desktop")
        let alert = NSAlert()
        alert.messageText = "安装完成"
        alert.informativeText = "应用已复制到「应用程序」。现在切换到新位置重新启动？"
        alert.addButton(withTitle: "重启")
        alert.addButton(withTitle: "继续使用当前实例")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(fileURLWithPath: dest))
            quit()
        }
    }

    private func reconfigure() {
        let port = Settings.shared.port
        if !Settings.shared.manageServer {
            // Leaving (or staying outside) managed mode: release any owned
            // child process and stale launchd agent, then re-attach only.
            ServerManager.shared.stopServer()
            LaunchAgentService.shared.uninstallIfStale()
        }
        ServerManager.shared.restartConfiguration()
        ServerManager.shared.configure(port: port)
        DshStreamsBridge.reconfigure(port: port)
        panelCtrl.update(port: port)
        ServerManager.shared.boot()
        poll()
        refreshUI()
    }

    /// Toggle the experimental "app manages dsh" mode on/off.
    private func toggleManageServer() {
        let s = Settings.shared
        s.manageServer.toggle()
        if s.manageServer {
            LogStore.shared.append("已开启「应用托管 DSH（实验）」，应用将拉起并守护 dsh web", source: "desktop")
        } else {
            LogStore.shared.append("已关闭「应用托管 DSH」，改为只挂载你自行启动的 dsh", source: "desktop")
        }
        reconfigure()
    }

    /// Passive-mode helper: put the start command on the clipboard and open
    /// Terminal at the working directory (no AppleScript permissions needed).
    private func launchDshInTerminal() {
        let cmd = "dsh web --port \(Settings.shared.port)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        let dir = URL(fileURLWithPath: Settings.shared.serverWorkDir, isDirectory: true)
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([dir], withApplicationAt: terminal, configuration: config) { _, _ in }
        LogStore.shared.append("已复制启动命令（\(cmd)）并打开终端（目录 \(Settings.shared.serverWorkDir)）", source: "desktop")
        BubbleController.shared.show(
            title: "启动 DSH",
            body: "已打开终端（\(Settings.shared.serverWorkDir)）并复制命令：\n\(cmd)\n粘贴回车即可。",
            anchor: statusItemCtrl.button, ttl: 8, onClick: nil)
    }

    // MARK: - DSH environment & updates

    /// Resolve the dsh CLI (re-used at launch, after an install, and from the
    /// "重新检测 DSH 环境" menu action).
    private func checkEnvironment(completion: @escaping (DshEnvironment.ReadyOutcome) -> Void) {
        DshEnvironment.shared.ensureReady(completion: completion)
    }

    private func environmentResolved(path: String, version: String) {
        if !Settings.shared.hasCustomServerBinary {
            Settings.shared.serverBinary = path
        }
        if !version.isEmpty {
            UpdateManager.shared.installedVersion = version
        }
        LogStore.shared.append("dsh 环境就绪：\(version.isEmpty ? "版本未知" : "v\(version)")（\(path)）", source: "desktop")
        if !version.isEmpty, !DshEnvironment.isSupported(version) {
            let families = DshEnvironment.supportedVersionFamilies.joined(separator: "、")
            let text = "dsh v\(version) 尚未收录到兼容列表（已验证 \(families) 系列），可能不完全兼容，请留意异常。"
            LogStore.shared.append(text, source: "desktop")
            BubbleController.shared.show(
                title: "DSH 版本未验证",
                body: text,
                anchor: statusItemCtrl.button, ttl: 15, onClick: nil)
            Notifier.shared.notify(id: "dsh-version", title: "DSH 版本未验证", body: text)
        }
        let wasRunning = AppState.shared.snapshot().serverRunning
        if !wasRunning {
            ServerManager.shared.boot()
        }
        poll()
        refreshUI()
        scheduleUpdateCheck(manual: false)
    }

    private func recheckEnvironment() {
        checkEnvironment { [weak self] outcome in
            switch outcome {
            case .ready(let path, let version):
                self?.environmentResolved(path: path, version: version)
            case .missing:
                LogStore.shared.append("仍未检测到 dsh，重新打开安装引导", source: "desktop")
                SetupWindowController.shared.present(mode: .onboarding)
            }
        }
    }

    /// Wire the setup assistant window's buttons to their flows.
    private func setupAssistantHandlers() {
        SetupWindowController.shared.onRun = { [weak self] in
            self?.runSetupInstall()
        }
        SetupWindowController.shared.onGuide = {
            if let url = URL(string: "https://github.com/deepseek-ai/deepseek-harness") {
                NSWorkspace.shared.open(url)
            }
        }
        SetupWindowController.shared.onCopy = {
            let cmd = "npm install -g @deepseek-ai/dsh@latest"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
            LogStore.shared.append("已复制安装命令到剪贴板：\(cmd)", source: "desktop")
        }
        SetupWindowController.shared.onLater = {
            SetupWindowController.shared.dismissWindow()
        }
        SetupWindowController.shared.onProceed = { [weak self] in
            SetupWindowController.shared.dismissWindow()
            self?.recheckEnvironment()
        }
        SetupWindowController.shared.onCancel = {
            DshEnvironment.shared.cancelInstall()
        }
    }

    /// Shared by onboarding (first install) and the update wizard: run the
    /// npm install, stream progress into the assistant window.
    private func runSetupInstall() {
        SetupWindowController.shared.beginWorking()
        DshEnvironment.shared.installOrUpdate(progress: { line in
            SetupWindowController.shared.appendLog(line)
        }) { [weak self] result in
            switch result {
            case .success(let version):
                if !version.isEmpty { UpdateManager.shared.installedVersion = version }
                UpdateManager.shared.availableVersion = nil
                LogStore.shared.append("dsh 安装/更新成功：v\(version.isEmpty ? "?" : version)", source: "desktop")
                SetupWindowController.shared.showSuccess(version: version)
                self?.restartDshServiceAfterUpdate()
            case .failure(let error):
                LogStore.shared.append("dsh 安装/更新失败：\(error.localizedDescription)", source: "desktop")
                SetupWindowController.shared.showFailure(message: error.localizedDescription)
            }
        }
    }

    /// After a dsh upgrade, relaunch the server so it runs the new version.
    private func restartDshServiceAfterUpdate() {
        if Settings.shared.serverServiceMode && Settings.shared.manageServer {
            // Rewrite the plist (fresh ProgramArguments) and let launchd
            // boot it via RunAtLoad.
            LaunchAgentService.shared.install()
        } else if ServerManager.shared.isOwned {
            ServerManager.shared.restartServer()
        } else {
            LogStore.shared.append("dsh 已更新：请在终端重新运行 dsh web 以使用新版本（菜单「在终端中启动 DSH…」）", source: "desktop")
        }
    }

    /// npm latest vs installed. Automatic checks run once a day and only
    /// announce; manual checks report the outcome and offer the upgrade.
    private func scheduleUpdateCheck(manual: Bool) {
        guard Settings.shared.autoCheckUpdates || manual else { return }
        let now = Date().timeIntervalSince1970
        if !manual, now - Settings.shared.lastUpdateCheckAt < 86_400 { return }
        Settings.shared.lastUpdateCheckAt = now

        DshEnvironment.shared.latestVersion { [weak self] latest in
            guard let self else { return }
            guard let latest else {
                if manual { self.showUpdateResultAlert(text: "无法连接 npm 仓库，请检查网络后重试。") }
                return
            }
            let installed = UpdateManager.shared.installedVersion
            if installed.isEmpty || DshEnvironment.compareVersions(latest, installed) != .orderedDescending {
                if manual {
                    self.showUpdateResultAlert(text: "已是最新版本 v\(installed)。")
                }
                return
            }
            UpdateManager.shared.availableVersion = latest
            if manual {
                self.confirmUpdate()
            } else {
                self.announceUpdateAvailable(latest: latest, installed: installed)
            }
        }
    }

    private func announceUpdateAvailable(latest: String, installed: String) {
        LogStore.shared.append("发现 DSH 新版本 v\(latest)（当前 v\(installed)）", source: "desktop")
        BubbleController.shared.show(
            title: "DSH 有新版本",
            body: "v\(latest) 可用（当前 v\(installed)）。点击打开更新向导。",
            anchor: statusItemCtrl.button, ttl: 20,
            onClick: { [weak self] in self?.confirmUpdate() })
        Notifier.shared.notify(id: "dsh-update",
                               title: "DSH 有新版本",
                               body: "v\(latest) 可用（当前 v\(installed)），菜单可一键更新。")
    }

    private func confirmUpdate() {
        guard let latest = UpdateManager.shared.availableVersion else { return }
        let installed = UpdateManager.shared.installedVersion
        let alert = NSAlert()
        alert.messageText = "更新 DeepSeek Harness？"
        alert.informativeText = "将执行 npm install -g @deepseek-ai/dsh@latest 升级到 v\(latest)"
            + "（当前 v\(installed)）。托管模式下会自动重启服务；否则请在终端重新运行 dsh web。"
        alert.addButton(withTitle: "立即更新")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            SetupWindowController.shared.present(mode: .updating)
            runSetupInstall()
        }
    }

    private func showUpdateResultAlert(text: String) {
        let alert = NSAlert()
        alert.messageText = "DSH 更新检查"
        alert.informativeText = text
        alert.runModal()
    }

    // MARK: - Main menu (Edit menu for web text fields, Reload, Quit)

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 DSH Desktop", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 DSH Desktop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "视图")
        let reloadItem = NSMenuItem(title: "刷新界面", action: #selector(reloadFromMenu), keyEquivalent: "r")
        reloadItem.target = self
        viewMenu.addItem(reloadItem)
        let windowToggle = NSMenuItem(title: "切换窗口模式", action: #selector(toggleWindowFromMenu), keyEquivalent: "")
        windowToggle.target = self
        viewMenu.addItem(windowToggle)
        viewMenuItem.submenu = viewMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func reloadFromMenu() { panelCtrl.reloadWebView() }
    @objc private func toggleWindowFromMenu() { panelCtrl.toggleWindowMode() }

    // MARK: - Popover dismissal (ESC / click outside)

    private func installDismissMonitors() {
        removeDismissMonitors()
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, self.panelCtrl.isPopoverShown else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                // While the web view owns the focus, ESC belongs to the page
                // (IME cancel, page dialogs, …); only close the panel when
                // focus is outside the web view.
                if self.webViewHasFocus() || self.hasActiveMarkedText() { return event }
                self.panelCtrl.closePopover()
                return nil
            }
            return event
        }
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.panelCtrl.closePopover()
            }
        }
    }

    /// True when the panel's focus sits inside the embedded web view.
    private func webViewHasFocus() -> Bool {
        guard let responder = panelCtrl.currentWindow?.firstResponder as? NSView else {
            return false
        }
        return responder.isDescendant(of: panelCtrl.webView)
    }

    /// True when the focused text field is in the middle of an IME
    /// composition (pinyin / marked text), so ESC should cancel it first.
    private func hasActiveMarkedText() -> Bool {
        let responders: [Any?] = [
            NSApp.keyWindow?.firstResponder,
            panelCtrl.currentWindow?.firstResponder,
        ]
        for responder in responders {
            if let client = responder as? NSTextInputClient, client.hasMarkedText() {
                return true
            }
        }
        return false
    }

    private func removeDismissMonitors() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }
}

/// Thin bridge so main.swift can hold a DshStreams instance without exposing it.
enum DshStreamsBridge {
    private static var streams: DshStreams?

    static func start(port: Int, onFrame: @escaping (String, String, [String: Any]) -> Void) {
        let s = DshStreams(port: port)
        s.onFrame = onFrame
        streams = s
        s.start()
    }

    static func reconfigure(port: Int) {
        streams?.reconfigure(port: port)
    }

    static func stop() {
        streams?.stop()
        streams = nil
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

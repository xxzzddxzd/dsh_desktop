import Foundation

/// Owns the `dsh web` server lifecycle: discover & attach, spawn, watchdog,
/// restart with backoff, log capture. Only terminates processes it spawned.
final class ServerManager: NSObject {
    static let shared = ServerManager()

    private var process: Process?
    private var owned = false
    private var port = 3080
    private var rpc: DshRpc?
    private var watchdog: Timer?
    private var restartAttempts = 0
    private var restartWorkItem: DispatchWorkItem?
    private var pendingRestart = false
    private var lastKickstart: TimeInterval = 0
    private let maxRestarts = 5
    private let healthInterval: TimeInterval = 5
    private var stopping = false

    var isOwned: Bool { owned }

    func configure(port: Int) {
        self.port = port
        rpc = DshRpc(port: port)
    }

    /// Attach to an existing server or start one. Called once at launch.
    func boot() {
        rpc = rpc ?? DshRpc(port: port)

        // Passive mode (default): never spawn, never touch launchd. The user
        // starts dsh themselves; we only verify status and attach.
        if !Settings.shared.manageServer {
            checkHealthAndUpdate { [weak self] healthy in
                guard let self else { return }
                if !healthy {
                    AppState.shared.setServer(running: false, owned: false, starting: false,
                                              version: "", provider: "", model: "",
                                              error: "DSH 未运行 · 请自行启动（dsh web --port \(self.port)），"
                                              + "或从菜单「在终端中启动 DSH…」")
                }
            }
            startWatchdog()
            return
        }

        if Settings.shared.serverServiceMode {
            // System service mode: ensure the LaunchAgent exists, then rely on
            // launchd (RunAtLoad + KeepAlive) with kickstart as the nudge.
            LaunchAgentService.shared.install()
            checkHealthAndUpdate { [weak self] healthy in
                guard let self else { return }
                if healthy {
                    LogStore.shared.append("已挂载到 launchd 服务（端口 \(self.port)）", source: "desktop")
                    return
                }
                if Settings.shared.autoStartServer {
                    LogStore.shared.append("launchd 服务未运行，kickstart 拉起…", source: "desktop")
                    LaunchAgentService.shared.start()
                } else {
                    AppState.shared.setServer(running: false, owned: false, starting: false,
                                              version: "", provider: "", model: "",
                                              error: "服务未运行（已关闭自动启动）", service: true)
                }
            }
            startWatchdog()
            return
        }

        // App-managed mode: reconcile any stale launchd agent first.
        LaunchAgentService.shared.uninstallIfStale()
        checkHealthAndUpdate { [weak self] healthy in
            guard let self else { return }
            if healthy {
                self.owned = false
                LogStore.shared.append("发现运行中的 DSH 服务（端口 \(self.port)），已挂载", source: "desktop")
                return
            }
            if Settings.shared.autoStartServer {
                self.startServer()
            } else {
                AppState.shared.setServer(running: false, owned: false, starting: false,
                                          version: "", provider: "", model: "",
                                          error: "服务未运行（已关闭自动启动）")
            }
        }
        startWatchdog()
    }

    /// Called when the service-mode setting changes.
    func applyServiceMode() {
        if Settings.shared.serverServiceMode && Settings.shared.manageServer {
            LaunchAgentService.shared.install()
            if Settings.shared.autoStartServer { LaunchAgentService.shared.start() }
        } else {
            LaunchAgentService.shared.uninstall()
        }
    }

    func restartConfiguration() {
        rpc = DshRpc(port: port)
    }

    /// Manual "start server" action from the menu.
    func startServer() {
        guard process == nil || process?.isRunning == false else { return }
        restartAttempts = 0
        spawn()
    }

    func stopServer() {
        if Settings.shared.serverServiceMode {
            LaunchAgentService.shared.stop()
            AppState.shared.setServer(running: false, owned: false, starting: false,
                                      version: "", provider: "", model: "", error: "", service: true)
            return
        }
        guard let process, process.isRunning else {
            owned = false
            pendingRestart = false
            AppState.shared.setServer(running: false, owned: false, starting: false,
                                      version: "", provider: "", model: "", error: "")
            return
        }
        LogStore.shared.append("正在停止 DSH 服务…", source: "desktop")
        stopping = true
        process.terminate()
        // Synchronous bounded wait: this also runs inside
        // applicationWillTerminate, where deferred blocks would never fire,
        // so the child must be reaped before the app exits.
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            _ = process.waitUntilExit()
        }
        self.process = nil
        owned = false
        stopping = false
        pendingRestart = false
        AppState.shared.setServer(running: false, owned: false, starting: false,
                                  version: "", provider: "", model: "", error: "")
    }

    /// Restart only when we own the process (or the launchd service).
    func restartServer() {
        if Settings.shared.serverServiceMode {
            LaunchAgentService.shared.restart()
            return
        }
        guard owned else { return }
        restartAttempts = 0
        let old = process
        old?.terminationHandler = nil
        old?.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.spawn()
        }
    }

    // MARK: - Internals

    private func spawn() {
        guard Settings.shared.manageServer else { return }
        guard process == nil || process?.isRunning == false else { return }
        stopping = false
        pendingRestart = false

        // Refuse to spawn when the port answers but is not DSH.
        if portBlocked() {
            AppState.shared.setServer(running: false, owned: false, starting: false,
                                      version: "", provider: "", model: "",
                                      error: "端口 \(port) 被其他程序占用")
            LogStore.shared.append("端口 \(port) 被其他程序占用，放弃启动", source: "desktop")
            return
        }

        AppState.shared.setServer(running: false, owned: true, starting: true,
                                  version: "", provider: "", model: "", error: "")

        let proc = Process()
        let bin = Settings.shared.serverBinary
        let fm = FileManager.default
        if bin.hasSuffix(".js") {
            // Global npm checkout fallback: run through node.
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = ["node", bin, "web", "--port", String(port)]
        } else if fm.isExecutableFile(atPath: bin) {
            proc.executableURL = URL(fileURLWithPath: bin)
            proc.arguments = ["web", "--port", String(port)]
        } else {
            AppState.shared.setServer(running: false, owned: false, starting: false,
                                      version: "", provider: "", model: "",
                                      error: "找不到 dsh 可执行文件：\(bin)")
            return
        }
        proc.currentDirectoryURL = URL(fileURLWithPath: Settings.shared.serverWorkDir, isDirectory: true)

        // GUI apps launch without a shell PATH: make sure Homebrew binaries
        // (node, the dsh shebang target) resolve for the child.
        var env = ProcessInfo.processInfo.environment
        let devPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let existing = env["PATH"], !existing.isEmpty {
            env["PATH"] = devPaths + ":" + existing
        } else {
            env["PATH"] = devPaths
        }
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                self?.forwardLog(text, source: "dsh")
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                self?.forwardLog(text, source: "dsh")
            }
        }

        proc.terminationHandler = { [weak self] proc in
            guard let self else { return }
            let code = proc.terminationStatus
            DispatchQueue.main.async {
                self.handleExit(code: code)
            }
        }

        do {
            try proc.run()
            process = proc
            owned = true
            LogStore.shared.append("已启动 DSH 服务：\(bin) web --port \(port)（工作目录 \(Settings.shared.serverWorkDir)）", source: "desktop")
        } catch {
            LogStore.shared.append("启动失败：\(error.localizedDescription)", source: "desktop")
            AppState.shared.setServer(running: false, owned: false, starting: false,
                                      version: "", provider: "", model: "",
                                      error: "启动失败：\(error.localizedDescription)")
        }
    }

    private func forwardLog(_ text: String, source: String) {
        LogStore.shared.append(text, source: source)
    }

    private func handleExit(code: Int32) {
        process = nil
        owned = false
        if stopping {
            AppState.shared.setServer(running: false, owned: false, starting: false,
                                      version: "", provider: "", model: "", error: "")
            return
        }
        LogStore.shared.append("DSH 服务退出（状态码 \(code)）", source: "desktop")
        AppState.shared.setServer(running: false, owned: false, starting: false,
                                  version: "", provider: "", model: "",
                                  error: "服务已退出（状态码 \(code)）")
        if restartAttempts < maxRestarts {
            restartAttempts += 1
            let delay = 3.0 * Double(restartAttempts)
            LogStore.shared.append("\(delay)s 后自动重启（第 \(restartAttempts)/\(maxRestarts) 次）", source: "desktop")
            restartWorkItem?.cancel()
            pendingRestart = true
            let item = DispatchWorkItem { [weak self] in
                guard let self, Settings.shared.autoStartServer, Settings.shared.manageServer else { return }
                self.spawn()
            }
            restartWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        } else {
            AppState.shared.setServer(running: false, owned: false, starting: false,
                                      version: "", provider: "", model: "",
                                      error: "服务反复崩溃，已停止自动重启（查看日志）")
        }
    }

    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: healthInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // Keep the timer alive while the run loop is busy.
        if let watchdog { RunLoop.main.add(watchdog, forMode: .common) }
    }

    private func tick() {
        guard !stopping else { return }
        checkHealthAndUpdate { [weak self] healthy in
            guard let self else { return }
            if healthy {
                if self.restartAttempts > 0 { self.restartAttempts = 0 }
                return
            }
            // Health lost.
            if Settings.shared.serverServiceMode {
                // launchd's KeepAlive restarts crashed services itself; a
                // throttled kickstart is the belt-and-braces nudge.
                let now = Date().timeIntervalSince1970
                if Settings.shared.autoStartServer, now - self.lastKickstart > 10 {
                    self.lastKickstart = now
                    LaunchAgentService.shared.start()
                }
                return
            }
            if self.owned, self.process?.isRunning == false {
                // Exit handler will drive the restart; nothing to do here.
                return
            }
            if !self.owned, Settings.shared.autoStartServer, Settings.shared.manageServer,
               self.process?.isRunning != true, !self.pendingRestart {
                // The external server died; try to stand up our own.
                LogStore.shared.append("检测到服务离线，尝试自动拉起…", source: "desktop")
                self.spawn()
            }
        }
    }

    private func checkHealthAndUpdate(completion: @escaping (Bool) -> Void) {
        guard let rpc else {
            completion(false)
            return
        }
        rpc.call("host.describe", timeout: 2.5) { [weak self] result in
            guard let self else { return }
            let serviceMode = Settings.shared.serverServiceMode
            switch result {
            case .success(let value):
                let dict = value as? [String: Any] ?? [:]
                let version = dict["version"] as? String ?? ""
                let provider = dict["provider"] as? String ?? ""
                let model = dict["model"] as? String ?? ""
                let attach = dict["attachedSessions"] as? Int ?? 0
                DispatchQueue.main.async {
                    AppState.shared.setServer(running: true, owned: self.owned, starting: false,
                                              version: version, provider: provider, model: model,
                                              error: "", service: serviceMode)
                    _ = attach
                }
                completion(true)
            case .failure(let error):
                DispatchQueue.main.async {
                    AppState.shared.setServer(running: false, owned: self.owned, starting: false,
                                              version: "", provider: "", model: "",
                                              error: error.localizedDescription, service: serviceMode)
                }
                completion(false)
            }
        }
    }

    private func portBlocked() -> Bool {
        // Fast socket probe: is anything listening on the port?
        var sockaddrIn = sockaddr_in()
        sockaddrIn.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sockaddrIn.sin_family = sa_family_t(AF_INET)
        sockaddrIn.sin_port = in_port_t(port).bigEndian
        sockaddrIn.sin_addr.s_addr = inet_addr("127.0.0.1")

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let result = withUnsafePointer(to: &sockaddrIn) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}

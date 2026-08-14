import Foundation

/// Manages DSH as a per-user launchd LaunchAgent (system service mode):
/// survives app crashes, auto-restarts on non-zero exits, starts at login,
/// and keeps running after the menu bar app quits.
final class LaunchAgentService {
    static let shared = LaunchAgentService()
    static let label = "dev.mydsh.dsh-server"

    private var plistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(Self.label).plist"
    }
    private var target: String { "gui/\(getuid())" }
    private var logPath: String {
        NSHomeDirectory() + "/Library/Logs/DSHDesktop/server.log"
    }

    func isBootstrapped() -> Bool {
        runLaunchctl(["print", "\(target)/\(Self.label)"], log: false) == 0
    }

    /// Idempotent: (re)write the plist for the current settings and bootstrap.
    @discardableResult
    func install() -> Bool {
        do {
            try writePlist()
        } catch {
            LogStore.shared.append("launchd：写入 plist 失败 \(error.localizedDescription)", source: "desktop")
            return false
        }
        // Re-bootstrap cleanly (ignores "not loaded" errors).
        _ = runLaunchctl(["bootout", "\(target)/\(Self.label)"], log: false)
        if runLaunchctl(["bootstrap", target, plistPath], log: false) != 0 {
            LogStore.shared.append("launchd：bootstrap 失败（plist 语法或权限问题）", source: "desktop")
            return false
        }
        LogStore.shared.append("launchd：已安装系统服务 \(Self.label)", source: "desktop")
        return true
    }

    func uninstall() {
        _ = runLaunchctl(["bootout", "\(target)/\(Self.label)"], log: false)
        try? FileManager.default.removeItem(atPath: plistPath)
        LogStore.shared.append("launchd：已卸载系统服务", source: "desktop")
    }

    /// Boot-time hygiene: remove a stale agent left over from service mode.
    func uninstallIfStale() {
        guard FileManager.default.fileExists(atPath: plistPath) else { return }
        LogStore.shared.append("launchd：清理残留的系统服务 plist", source: "desktop")
        uninstall()
    }

    /// Start the service if it is not running (no-op when already up).
    func start() {
        _ = runLaunchctl(["kickstart", "\(target)/\(Self.label)"], log: false)
    }

    /// Force restart (kickstart -k).
    func restart() {
        _ = runLaunchctl(["kickstart", "-k", "\(target)/\(Self.label)"], log: false)
    }

    /// Stop now; launchd reloads it at next login (plist stays installed).
    func stop() {
        _ = runLaunchctl(["bootout", "\(target)/\(Self.label)"], log: false)
    }

    // MARK: - Plist

    private func writePlist() throws {
        let fm = FileManager.default
        let dir = (plistPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let logDir = (logPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: logPath) {
            fm.createFile(atPath: logPath, contents: nil)
        }

        // Build the program arguments like ServerManager.spawn does.
        let bin = Settings.shared.serverBinary
        var args: [String] = []
        if bin.hasSuffix(".js") {
            args = ["/usr/bin/env", "node", bin]
        } else {
            args = [bin]
        }
        args += ["web", "--port", String(Settings.shared.port)]

        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": args,
            "WorkingDirectory": Settings.shared.serverWorkDir,
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "EnvironmentVariables": [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            ],
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                      format: .xml,
                                                      options: 0)
        try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
    }

    // MARK: - launchctl

    @discardableResult
    private func runLaunchctl(_ args: [String], log: Bool = true) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = out
        proc.standardInput = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            if log { LogStore.shared.append("launchctl 调用失败：\(error.localizedDescription)", source: "desktop") }
            return -1
        }
        proc.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        if log, let text = String(data: data, encoding: .utf8), !text.isEmpty {
            LogStore.shared.append("launchctl: \(text)", source: "desktop")
        }
        return proc.terminationStatus
    }
}

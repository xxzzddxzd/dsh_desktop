import Foundation

/// Detects, installs and updates the `dsh` CLI (DeepSeek Harness) on the
/// user's machine, and reports the newest published npm version.
///
/// DSH ships as the npm package `@deepseek-ai/dsh`; the canonical install and
/// upgrade path is `npm install -g @deepseek-ai/dsh@latest`.
final class DshEnvironment {
    static let shared = DshEnvironment()

    /// Simple carrier so install/update failures can flow through Result.
    enum SetupError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let msg) = self { return msg }
            return nil
        }
    }

    /// Extra PATH used for every child process: GUI apps launch without a
    /// login shell, so Homebrew / npm bins must be added explicitly.
    static let devPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    /// npm can take a while on cold caches; kill it after this.
    private let installTimeout: TimeInterval = 600

    private var installProcess: Process?

    enum ReadyOutcome {
        case ready(path: String, version: String)
        case missing
    }

    // MARK: - Detection

    /// Resolve the dsh launcher and its version. Called at launch and after
    /// an install/update; must run on a background queue (spawns processes).
    func ensureReady(completion: @escaping (ReadyOutcome) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let path = self.resolveBinary() else {
                DispatchQueue.main.async { completion(.missing) }
                return
            }
            let version = self.versionSync(path: path)
            DispatchQueue.main.async { completion(.ready(path: path, version: version)) }
        }
    }

    /// Best-effort discovery of the dsh launcher, in priority order:
    /// user override → known prefixes → login-shell PATH → npm global lib.
    func resolveBinary() -> String? {
        let fm = FileManager.default

        // 1. User-configured binary (only while it still exists).
        if Settings.shared.hasCustomServerBinary {
            let bin = Settings.shared.serverBinary
            let ok = bin.hasSuffix(".js") ? fm.fileExists(atPath: bin) : fm.isExecutableFile(atPath: bin)
            if ok { return bin }
        }

        // 2. Standard locations.
        for c in ["/opt/homebrew/bin/dsh", "/usr/local/bin/dsh"] where fm.isExecutableFile(atPath: c) {
            return c
        }

        // 3. The user's real PATH (custom npm prefixes, mise/asdf/nvm shims…).
        if let p = shellWhich("dsh") { return p }

        // 4. Global npm checkout's bin script, run through node.
        for lib in [
            "/opt/homebrew/lib/node_modules/@deepseek-ai/dsh/lib/bin.js",
            "/usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js",
        ] where fm.fileExists(atPath: lib) {
            return lib
        }
        return nil
    }

    /// `dsh --version`, run synchronously (short timeout). Empty on failure.
    func versionSync(path: String) -> String {
        let proc = makeProcess(path: path, extra: ["--version"])
        let r = runSync(proc, timeout: 15)
        guard r.code == 0 else { return "" }
        let lines = r.output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.last ?? ""
    }

    // MARK: - Install / update

    /// Run `npm install -g @deepseek-ai/dsh@latest`. Progress lines are
    /// delivered on the main thread; completion too, with the fresh version.
    func installOrUpdate(progress: @escaping (String) -> Void,
                         completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            guard let npm = self.resolveNpm() else {
                let msg = "未找到 npm。DSH 通过 npm 分发，需要 Node.js ≥ 20。\n"
                    + "请先安装 Node.js（brew install node，或访问 nodejs.org），\n"
                    + "然后点击「重试」，或使用「手动安装指南」。"
                DispatchQueue.main.async { completion(.failure(SetupError.message(msg))) }
                return
            }

            let proc = Process()
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = Self.devPaths + ":" + (env["PATH"] ?? "")
            env["npm_config_fund"] = "false"
            env["npm_config_audit"] = "false"
            env["npm_config_update_notifier"] = "false"
            proc.environment = env
            proc.executableURL = URL(fileURLWithPath: npm)
            proc.arguments = ["install", "--global", "@deepseek-ai/dsh@latest"]

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                    DispatchQueue.main.async { progress(text) }
                }
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                    DispatchQueue.main.async { progress(text) }
                }
            }

            // Hard timeout so a hung npm cannot orphan the flow.
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + self.installTimeout, repeating: .never)
            timer.setEventHandler { [weak proc] in
                if let proc, proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            }
            timer.resume()

            DispatchQueue.main.async { self.installProcess = proc }
            proc.terminationHandler = { [weak self] p in
                timer.cancel()
                DispatchQueue.main.async { self?.installProcess = nil }
                let code = p.terminationStatus
                guard let self else { return }
                if code == 0 {
                    // Re-detect to report the version now on disk.
                    let version = self.resolveBinary().map { self.versionSync(path: $0) } ?? ""
                    DispatchQueue.main.async { completion(.success(version)) }
                } else {
                    DispatchQueue.main.async {
                        completion(.failure(SetupError.message(
                            "npm 退出码 \(code)。上方日志有更多细节；\n"
                            + "也可以复制命令到终端手动执行。")))
                    }
                }
            }

            do {
                try proc.run()
            } catch {
                timer.cancel()
                DispatchQueue.main.async { self.installProcess = nil }
                DispatchQueue.main.async {
                    completion(.failure(SetupError.message("无法启动 npm：\(error.localizedDescription)")))
                }
            }
        }
    }

    /// Abort a running install/update (cancel button).
    func cancelInstall() {
        installProcess?.terminate()
    }

    // MARK: - Version lookup

    /// Newest published version from the npm registry; nil on network error.
    func latestVersion(completion: @escaping (String?) -> Void) {
        guard let url = URL(string: "https://registry.npmjs.org/@deepseek-ai%2Fdsh/latest") else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            var result: String?
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                result = json["version"] as? String
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    /// dsh version families this app has been verified against (major.minor.patch,
    /// any prerelease of that family matches). Update after each verified upgrade.
    static let supportedVersionFamilies = ["0.1.0"]

    /// True when the version belongs to a verified family; unknown versions
    /// (empty) are treated as supported to avoid false alarms.
    static func isSupported(_ version: String) -> Bool {
        let v = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return true }
        let parsed = parseVersion(v)
        let family = "\(parsed.core[0]).\(parsed.core[1]).\(parsed.core[2])"
        return supportedVersionFamilies.contains(family)
    }

    /// Semantic-ish comparison for versions like `0.1.0-rc.6`.
    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let pa = parseVersion(a)
        let pb = parseVersion(b)
        for i in 0..<3 {
            if pa.core[i] != pb.core[i] {
                return pa.core[i] < pb.core[i] ? .orderedAscending : .orderedDescending
            }
        }
        switch (pa.prerelease, pb.prerelease) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending   // release beats any prerelease
        case (_, nil): return .orderedAscending
        case (let x?, let y?): return comparePrerelease(x, y)
        }
    }

    private static func parseVersion(_ s: String) -> (core: [Int], prerelease: String?) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(pattern: #"^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.]+))?$"#),
              let m = regex.firstMatch(in: t, range: NSRange(t.startIndex..<t.endIndex, in: t)) else {
            return ([0, 0, 0], nil)
        }
        let core = (1...3).map { i -> Int in
            let r = m.range(at: i)
            return r.location == NSNotFound ? 0 : (Int((t as NSString).substring(with: r)) ?? 0)
        }
        let pr = m.range(at: 4)
        let prerelease = pr.location == NSNotFound ? nil : (t as NSString).substring(with: pr)
        return (core, prerelease)
    }

    private static func comparePrerelease(_ x: String, _ y: String) -> ComparisonResult {
        if x == y { return .orderedSame }
        if let nx = Int(x), let ny = Int(y) {
            return nx < ny ? .orderedAscending : .orderedDescending
        }
        // e.g. rc.6 vs rc.10: compare the trailing number numerically.
        func rcNumber(_ s: String) -> Int? {
            guard let regex = try? NSRegularExpression(pattern: #"^rc\.(\d+)$"#),
                  let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..<s.endIndex, in: s)) else {
                return nil
            }
            return Int((s as NSString).substring(with: m.range(at: 1)))
        }
        if let nx = rcNumber(x), let ny = rcNumber(y) {
            return nx < ny ? .orderedAscending : .orderedDescending
        }
        return x < y ? .orderedAscending : .orderedDescending
    }

    // MARK: - Process helpers

    /// Process that runs the resolved binary with the given extra arguments.
    private func makeProcess(path: String, extra: [String]) -> Process {
        let proc = Process()
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.devPaths + ":" + (env["PATH"] ?? "")
        proc.environment = env
        if path.hasSuffix(".js") {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = ["node", path] + extra
        } else {
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = extra
        }
        return proc
    }

    /// Blocking run with a bounded wait; SIGKILLs on timeout. Background only.
    private func runSync(_ proc: Process, timeout: TimeInterval) -> (code: Int32, output: String) {
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
        } catch {
            return (-1, "")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
            proc.waitUntilExit()
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// `command -v` through the user's login shell (picks up custom PATHs).
    private func shellWhich(_ name: String) -> String? {
        let shell = FileManager.default.isExecutableFile(atPath: "/bin/zsh") ? "/bin/zsh" : "/bin/sh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-lc", "command -v \(name)"]
        let r = runSync(proc, timeout: 5)
        guard r.code == 0 else { return nil }
        let p = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, FileManager.default.isExecutableFile(atPath: p) else { return nil }
        return p
    }

    /// Locate npm (needed for install/update).
    private func resolveNpm() -> String? {
        for c in ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"]
        where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return shellWhich("npm")
    }
}

/// Small shared holder for the dsh update state (installed + available).
final class UpdateManager {
    static let shared = UpdateManager()
    var installedVersion = ""
    var availableVersion: String?
}

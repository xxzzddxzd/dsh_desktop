import AppKit

/// Modal assistant window for two flows:
///  - onboarding: the `dsh` CLI is missing, offer to install it;
///  - updating: a newer dsh version is available, offer to upgrade.
///
/// The controller only owns presentation; every button fires a closure wired
/// by the app delegate, which drives the actual work via `DshEnvironment`.
final class SetupWindowController: NSObject, NSWindowDelegate {
    static let shared = SetupWindowController()

    enum Mode { case onboarding, updating }
    private enum State { case idle, working, failed, success }

    // Fired by the buttons; wired once by the app delegate.
    var onRun: (() -> Void)?       // 帮我安装 / 立即更新 / 重试
    var onGuide: (() -> Void)?     // 手动安装指南
    var onCopy: (() -> Void)?      // 复制安装命令
    var onLater: (() -> Void)?     // 稍后再说
    var onProceed: (() -> Void)?   // 开始使用 / 完成
    var onCancel: (() -> Void)?    // 取消（安装进行中）

    private var window: NSWindow?
    private var mode: Mode = .onboarding
    private var state: State = .idle
    private var isDismissing = false

    private var titleField: NSTextField!
    private var bodyField: NSTextField!
    private var spinner: NSProgressIndicator!
    private var logScroll: NSScrollView!
    private var logView: NSTextView!
    private var buttonsRow: NSStackView!
    private var windowButtons: [NSButton] = []

    private override init() { super.init() }

    // MARK: - Presentation

    func present(mode: Mode) {
        self.mode = mode
        state = .idle
        buildWindowIfNeeded()

        if mode == .onboarding {
            titleField.stringValue = "需要 DeepSeek Harness（dsh）"
            bodyField.stringValue = "DSH Desktop 是 DSH 的桌面伴侣，需要 dsh 命令行工具来启动本地服务。\n"
                + "检测到这台 Mac 上还没有安装 dsh。\n\n"
                + "点击「帮我安装」将自动执行：\n"
                + "    npm install -g @deepseek-ai/dsh@latest\n"
                + "（需要 Node.js ≥ 20，下载安装约需 1–3 分钟）"
            setButtons([("帮我安装", #selector(installNow)),
                        ("手动安装指南", #selector(openGuide)),
                        ("稍后再说", #selector(later))])
        } else {
            titleField.stringValue = "更新 DeepSeek Harness（dsh）"
            bodyField.stringValue = "将执行 npm install -g @deepseek-ai/dsh@latest，\n"
                + "升级完成后自动重启 DSH 服务。"
            setButtons([("立即更新", #selector(installNow)),
                        ("稍后再说", #selector(later))])
        }
        spinner.stopAnimation(nil)
        logScroll.isHidden = true
        logView.string = ""
        window?.title = "DSH Desktop 设置助手"
        showWindow()
    }

    func beginWorking() {
        state = .working
        titleField.stringValue = mode == .onboarding ? "正在安装 DSH…" : "正在更新 DSH…"
        bodyField.stringValue = "正在运行 npm install -g @deepseek-ai/dsh@latest，请稍候…"
        spinner.startAnimation(nil)
        logScroll.isHidden = false
        logView.string = ""
        appendLog("$ npm install -g @deepseek-ai/dsh@latest\n")
        setButtons([("取消", #selector(cancelRun))])
    }

    func appendLog(_ text: String) {
        guard state == .working else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let logView else { return }
            logView.textStorage?.append(NSAttributedString(string: text))
            logView.scrollToEndOfDocument(nil)
        }
    }

    func showSuccess(version: String) {
        state = .success
        spinner.stopAnimation(nil)
        titleField.stringValue = mode == .onboarding ? "安装完成" : "更新完成"
        bodyField.stringValue = "dsh v\(version.isEmpty ? "最新版" : version) 已就绪。"
        logScroll.isHidden = true
        setButtons([(mode == .onboarding ? "开始使用" : "完成", #selector(proceed))])
    }

    func showFailure(message: String) {
        state = .failed
        spinner.stopAnimation(nil)
        titleField.stringValue = mode == .onboarding ? "安装失败" : "更新失败"
        bodyField.stringValue = message
        setButtons([("重试", #selector(installNow)),
                    ("复制安装命令", #selector(copyCommand)),
                    ("稍后再说", #selector(later))])
    }

    func dismissWindow() {
        isDismissing = true
        window?.close()
        isDismissing = false
    }

    func windowWillClose(_ notification: Notification) {
        if isDismissing { return }
        if state == .working { onCancel?() }
        else if state == .idle { onLater?() }
    }

    // MARK: - Actions

    @objc private func installNow() { onRun?() }
    @objc private func openGuide() { onGuide?() }
    @objc private func copyCommand() { onCopy?() }
    @objc private func later() { onLater?() }
    @objc private func proceed() { onProceed?() }
    @objc private func cancelRun() { onCancel?() }

    // MARK: - Window construction

    private func buildWindowIfNeeded() {
        guard window == nil else { return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()

        guard let content = w.contentView else { return }

        titleField = NSTextField(labelWithString: "")
        titleField.font = .systemFont(ofSize: 16, weight: .semibold)
        titleField.translatesAutoresizingMaskIntoConstraints = false

        bodyField = NSTextField(wrappingLabelWithString: "")
        bodyField.font = .systemFont(ofSize: 12)
        bodyField.textColor = .secondaryLabelColor
        bodyField.translatesAutoresizingMaskIntoConstraints = false

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        logScroll = NSScrollView()
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder
        logScroll.translatesAutoresizingMaskIntoConstraints = false

        logView = NSTextView()
        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        logView.isVerticallyResizable = true
        logView.autoresizingMask = [.width]
        logView.textContainerInset = NSSize(width: 6, height: 6)
        logScroll.documentView = logView

        buttonsRow = NSStackView()
        buttonsRow.orientation = .horizontal
        buttonsRow.alignment = .centerY
        buttonsRow.spacing = 8
        buttonsRow.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(titleField)
        content.addSubview(bodyField)
        content.addSubview(spinner)
        content.addSubview(logScroll)
        content.addSubview(buttonsRow)

        NSLayoutConstraint.activate([
            titleField.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            titleField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),

            bodyField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 8),
            bodyField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            bodyField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),

            spinner.topAnchor.constraint(equalTo: bodyField.bottomAnchor, constant: 12),
            spinner.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),

            logScroll.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 8),
            logScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            logScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            logScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),

            buttonsRow.topAnchor.constraint(equalTo: logScroll.bottomAnchor, constant: 12),
            buttonsRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            buttonsRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])

        window = w
    }

    private func setButtons(_ defs: [(String, Selector)]) {
        for b in windowButtons {
            buttonsRow.removeArrangedSubview(b)
            b.removeFromSuperview()
        }
        windowButtons = []
        for (title, sel) in defs {
            let b = NSButton(title: title, target: self, action: sel)
            b.bezelStyle = .rounded
            if title == "帮我安装" || title == "立即更新" || title == "开始使用" || title == "完成" {
                b.keyEquivalent = "\r"
            }
            windowButtons.append(b)
            buttonsRow.addArrangedSubview(b)
        }
    }

    private func showWindow() {
        guard let window else { return }
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

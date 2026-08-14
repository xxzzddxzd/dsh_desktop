import AppKit
import WebKit

/// Bottom-right resize grip drawn over the panel; drag to resize the popover.
final class ResizeGripView: NSView {
    var onResize: ((NSSize) -> Void)?
    var onResizeEnd: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.setStroke()
        let path = NSBezierPath()
        for i in 0..<3 {
            let inset = CGFloat(4 + i * 4)
            path.move(to: NSPoint(x: bounds.maxX - inset, y: 2))
            path.line(to: NSPoint(x: bounds.maxX - 2, y: inset))
        }
        path.lineWidth = 1.3
        path.stroke()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        guard let win = window else { return }
        let startPoint = NSEvent.mouseLocation
        let startSize = win.frame.size
        while true {
            guard let next = win.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            if next.type == .leftMouseUp { break }
            let current = NSEvent.mouseLocation
            var width = startSize.width + (current.x - startPoint.x)
            var height = startSize.height - (current.y - startPoint.y)
            width = max(width, 620)
            height = max(height, 440)
            onResize?(NSSize(width: width, height: height))
        }
        onResizeEnd?()
    }
}

/// Panel view: toolbar (status line + action buttons) above the DSH Web UI.
final class PanelViewController: NSViewController {
    let webView = WKWebView()
    private let statusLabel = NSTextField(labelWithString: "正在连接 DSH 服务…")
    private let overlayLabel = NSTextField(labelWithString: "")
    private var overlayHost: NSView?
    private(set) var resizeGrip: ResizeGripView!

    var onOpenBrowser: (() -> Void)?
    var onReload: (() -> Void)?
    var onToggleWindow: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 720))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let toolbar = NSVisualEffectView()
        toolbar.material = .hudWindow
        toolbar.blendingMode = .withinWindow
        toolbar.state = .active
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        func makeButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton()
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            b.bezelStyle = .texturedRounded
            b.controlSize = .small
            b.toolTip = tip
            b.target = self
            b.action = action
            b.translatesAutoresizingMaskIntoConstraints = false
            return b
        }

        let browserButton = makeButton("safari", "在浏览器中打开", #selector(openBrowserAction))
        let reloadButton = makeButton("arrow.clockwise", "刷新", #selector(reloadAction))
        let windowButton = makeButton("macwindow", "切换窗口模式", #selector(toggleWindowAction))
        let settingsButton = makeButton("gearshape", "设置", #selector(openSettingsAction))
        let quitButton = makeButton("xmark", "退出", #selector(quitAction))

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.allowsBackForwardNavigationGestures = false

        resizeGrip = ResizeGripView()
        resizeGrip.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(toolbar)
        toolbar.addSubview(statusLabel)
        toolbar.addSubview(browserButton)
        toolbar.addSubview(reloadButton)
        toolbar.addSubview(windowButton)
        toolbar.addSubview(settingsButton)
        toolbar.addSubview(quitButton)
        root.addSubview(webView)
        root.addSubview(resizeGrip)

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 42),

            statusLabel.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 14),
            statusLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: browserButton.leadingAnchor, constant: -10),

            quitButton.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -10),
            quitButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            settingsButton.trailingAnchor.constraint(equalTo: quitButton.leadingAnchor, constant: -6),
            settingsButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            windowButton.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -6),
            windowButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            reloadButton.trailingAnchor.constraint(equalTo: windowButton.leadingAnchor, constant: -6),
            reloadButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            browserButton.trailingAnchor.constraint(equalTo: reloadButton.leadingAnchor, constant: -6),
            browserButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            resizeGrip.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -3),
            resizeGrip.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -3),
            resizeGrip.widthAnchor.constraint(equalToConstant: 18),
            resizeGrip.heightAnchor.constraint(equalToConstant: 18),
        ])

        view = root
    }

    func updateStatusLine(_ text: String) {
        statusLabel.stringValue = text
    }

    /// Show/hide the resize grip; loads the view hierarchy if needed.
    func setGripHidden(_ hidden: Bool) {
        _ = view
        resizeGrip.isHidden = hidden
    }

    func showOverlay(_ text: String) {
        guard overlayHost == nil else {
            overlayLabel.stringValue = text
            return
        }
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor

        overlayLabel.stringValue = text
        overlayLabel.alignment = .center
        overlayLabel.font = .systemFont(ofSize: 15, weight: .medium)
        overlayLabel.textColor = .secondaryLabelColor
        overlayLabel.maximumNumberOfLines = 0
        overlayLabel.translatesAutoresizingMaskIntoConstraints = false

        host.addSubview(overlayLabel)
        webView.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
            host.topAnchor.constraint(equalTo: webView.topAnchor),
            host.bottomAnchor.constraint(equalTo: webView.bottomAnchor),
            overlayLabel.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            overlayLabel.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            overlayLabel.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: 40),
            overlayLabel.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -40),
        ])
        overlayHost = host
    }

    func hideOverlay() {
        overlayHost?.removeFromSuperview()
        overlayHost = nil
    }

    @objc private func openBrowserAction() { onOpenBrowser?() }
    @objc private func reloadAction() { onReload?() }
    @objc private func toggleWindowAction() { onToggleWindow?() }
    @objc private func openSettingsAction() { onOpenSettings?() }
    @objc private func quitAction() { onQuit?() }
}

/// Popover + resizable window hosting the panel; keeps the WKWebView alive
/// across open/close for an instant UI.
final class PanelController: NSObject, NSPopoverDelegate, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    let popover = NSPopover()
    private let panelVC = PanelViewController()
    private var window: NSWindow?
    private var baseURL = URL(string: "http://127.0.0.1:3080")!
    private var webViewLoaded = false
    private var lastLoadFailed = false
    private var retryTimer: Timer?
    private var serverRunning = false
    private var lastSnapshot: Snapshot?
    private var loggedFinish = false
    private var loggedFailure = false
    private var pendingSessionTitle: String?
    private var selectRetries = 0
    private var selectInProgress = false

    var onOpenBrowser: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?
    var onDismiss: (() -> Void)?
    /// Fired right after the popover becomes visible.
    var onPopoverShown: (() -> Void)?

    override init() {
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = Self.clampedSize(Settings.shared.popoverSize)
        popover.contentViewController = panelVC
        panelVC.webView.navigationDelegate = self
        panelVC.webView.uiDelegate = self
        panelVC.onOpenBrowser = { [weak self] in self?.onOpenBrowser?() }
        panelVC.onReload = { [weak self] in self?.reloadWebView() }
        panelVC.onToggleWindow = { [weak self] in self?.toggleWindowMode() }
        panelVC.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        panelVC.onQuit = { [weak self] in self?.onQuit?() }
        configureGrip()
    }

    /// Wires the resize grip (forces the view hierarchy to load first).
    private func configureGrip() {
        _ = panelVC.view
        panelVC.resizeGrip.onResize = { [weak self] size in
            self?.popover.contentSize = Self.clampedSize(size)
        }
        panelVC.resizeGrip.onResizeEnd = { [weak self] in
            guard let self else { return }
            Settings.shared.popoverSize = self.popover.contentSize
        }
        panelVC.resizeGrip.isHidden = true
    }

    /// Clamp a panel size to sane bounds (screen-relative maximum).
    static func clampedSize(_ size: NSSize) -> NSSize {
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let maxW = frame.width * 0.92
        let maxH = frame.height * 0.92
        return NSSize(width: min(max(size.width, 620), maxW),
                      height: min(max(size.height, 440), maxH))
    }

    func update(port: Int) {
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
        if webViewLoaded {
            webViewLoaded = false
            lastLoadFailed = false
            panelVC.webView.load(URLRequest(url: baseURL))
        }
    }

    var isPopoverShown: Bool { popover.isShown }
    var isWindowVisible: Bool { window?.isVisible ?? false }

    var webView: WKWebView { panelVC.webView }

    /// The window currently hosting the panel (popover or floating window).
    var currentWindow: NSWindow? {
        if popover.isShown { return panelVC.view.window }
        if window?.isVisible == true { return window }
        return nil
    }

    // MARK: - Open / close

    func togglePopover(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        if window?.isVisible == true {
            window?.orderOut(nil)
        }
        panelVC.setGripHidden(false)
        ensureWebView()
        // Freeze the status item width BEFORE showing so the popover opens
        // anchored at the final frame (no jump at open, none while open).
        onPopoverShown?()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closePopover() {
        if popover.isShown { popover.performClose(nil) }
    }

    func toggleWindowMode() {
        if window?.isVisible == true {
            window?.orderOut(nil)
            return
        }
        if popover.isShown { popover.performClose(nil) }
        ensureWebView()

        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 800),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "DSH Desktop"
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("DSHDesktopPanelWindow")
            w.delegate = self
            window = w
        }
        if let window {
            panelVC.setGripHidden(true)
            popover.contentViewController = nil
            window.contentViewController = panelVC
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            Settings.shared.windowMode = true
        }
    }

    /// Move the panel back into the popover when the window closes.
    func windowWillClose(_ notification: Notification) {
        if window?.contentViewController === panelVC {
            window?.contentViewController = nil
            popover.contentViewController = panelVC
        }
        panelVC.setGripHidden(false)
        Settings.shared.windowMode = false
        onDismiss?()
    }

    func popoverDidClose(_ notification: Notification) {
        onDismiss?()
    }

    func reloadWebView() {
        guard webViewLoaded else { return }
        panelVC.webView.reloadFromOrigin()
    }

    /// Opens the panel on a specific session. The web UI has no URL deep
    /// link, so we drive its session switcher: click the session crumb →
    /// pick the matching row in the picker → verify the crumb changed.
    /// All steps use synchronous JS snippets staged from Swift.
    func openSession(id: String, title: String) {
        pendingSessionTitle = title.isEmpty ? nil : title
        selectRetries = 0
        ensureWebView()
        selectStageOpenPicker()
    }

    private func selectStageOpenPicker() {
        guard let title = pendingSessionTitle, webViewLoaded, !selectInProgress else { return }
        selectInProgress = true
        evaluate(Self.crumbClickScript(), tag: "select-open") { [weak self] result in
            guard let self else { return }
            if Settings.shared.debugDump {
                LogStore.shared.append("select-open: \(result ?? "nil")", source: "debug")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                self?.selectStagePick(title: title)
            }
        }
    }

    private func selectStagePick(title: String) {
        guard pendingSessionTitle != nil else { return }
        evaluate(Self.pickScript(title: title), tag: "select-pick") { [weak self] result in
            guard let self else { return }
            let picked = result ?? ""
            if Settings.shared.debugDump {
                LogStore.shared.append("select-pick: \(picked)", source: "debug")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                self?.selectStageVerify(title: title, picked: picked)
            }
        }
    }

    private func selectStageVerify(title: String, picked: String) {
        evaluate(Self.crumbTextScript(), tag: "select-verify") { [weak self] result in
            guard let self else { return }
            let current = (result ?? "").trimmingCharacters(in: .whitespaces)
            let already = current == title || current.hasPrefix(String(title.prefix(8)))
            let ok = already || (!picked.contains("not-found") && !picked.isEmpty && picked != "no-crumb")
            if Settings.shared.debugDump {
                LogStore.shared.append("select-verify: current=「\(current.prefix(40))」 ok=\(ok)", source: "debug")
            }
            if ok {
                self.pendingSessionTitle = nil
                self.selectInProgress = false
                return
            }
            self.selectRetries += 1
            if self.selectRetries < 6 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.selectStageOpenPicker()
                }
            } else {
                self.pendingSessionTitle = nil
                self.selectInProgress = false
            }
        }
    }

    /// Debug: dump the DOM (clickable surface + optional needle hits) to the
    /// log. Optional pre-click of the session crumb to reveal the picker.
    func runDomProbe(needle: String, idPrefix: String, click: String = "") {
        ensureWebView()
        guard webViewLoaded, probeRetries < 5 else {
            probeRetries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.runDomProbe(needle: needle, idPrefix: idPrefix, click: click)
            }
            return
        }
        let dumpScript = Self.dumpScript(needle: needle, idPrefix: idPrefix)
        if click == "crumb" {
            evaluate(Self.crumbClickScript(), tag: "probe-click") { [weak self] result in
                LogStore.shared.append("probe-click: \(result ?? "nil")", source: "debug")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                    self?.evaluate(dumpScript, tag: "dom-probe") { text in
                        LogStore.shared.append("dom-probe: \(text ?? "nil")", source: "debug")
                    }
                }
            }
            return
        }
        evaluate(dumpScript, tag: "dom-probe") { text in
            LogStore.shared.append("dom-probe: \(text ?? "nil")", source: "debug")
        }
    }

    func resetProbe() {
        probeRetries = 0
    }

    private var probeRetries = 0

    // MARK: - Injected JS snippets (synchronous; staged from Swift)

    private func evaluate(_ js: String, tag: String, completion: @escaping (String?) -> Void) {
        if Settings.shared.debugDump {
            LogStore.shared.append("eval-start: \(tag)", source: "debug")
        }
        panelVC.webView.evaluateJavaScript(js) { result, error in
            if let error {
                LogStore.shared.append("eval-error: \(tag) \(error.localizedDescription)", source: "debug")
            }
            completion(result as? String)
        }
    }

    private static func jsEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// Click the deepest breadcrumb (the session-level crumb) to open the
    /// session switcher.
    static func crumbClickScript() -> String {
        """
        (() => {
          const cs = Array.from(document.querySelectorAll('button[class*="crumb"]'));
          if (!cs.length) return 'no-crumb';
          const el = cs[cs.length - 1];
          const r = el.getBoundingClientRect();
          const o = { bubbles: true, cancelable: true, view: window,
                      clientX: r.x + r.width / 2, clientY: r.y + r.height / 2,
                      button: 0, buttons: 1, detail: 1 };
          try {
            el.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, cancelable: true, pointerId: 1, pointerType: 'mouse' }));
            el.dispatchEvent(new MouseEvent('mousedown', o));
            el.dispatchEvent(new MouseEvent('mouseup', Object.assign({}, o, { buttons: 0 })));
            el.dispatchEvent(new MouseEvent('click', Object.assign({}, o, { buttons: 0 })));
          } catch (e) { try { el.click(); } catch (e2) { return 'click-error'; } }
          return 'clicked';
        })();
        """
    }

    /// Find the picker row matching the session title and click it.
    static func pickScript(title: String) -> String {
        let t = jsEscape(title)
        return """
        (() => {
          const t = "\(t)";
          const norm = s => (s || '').replace(/\\s+/g, ' ').trim();
          const els = Array.from(document.querySelectorAll(
            '[role="option"], [role="menuitem"], button, [role="button"], [role="listitem"]'));
          let best = null, score = 0;
          for (const el of els) {
            const txt = norm(el.textContent);
            if (!txt || txt.length > t.length + 30) continue;
            if (txt === t) { best = el; score = 3; break; }
            if (txt.startsWith(t.slice(0, 10)) && score < 2) { best = el; score = 2; }
            if (!best && t.length >= 6 && txt.includes(t.slice(0, 6))) { best = el; score = 1; }
          }
          if (!best) return 'not-found';
          const r = best.getBoundingClientRect();
          const o = { bubbles: true, cancelable: true, view: window,
                      clientX: r.x + r.width / 2, clientY: r.y + r.height / 2,
                      button: 0, buttons: 1, detail: 1 };
          try {
            best.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, cancelable: true, pointerId: 1, pointerType: 'mouse' }));
            best.dispatchEvent(new MouseEvent('mousedown', o));
            best.dispatchEvent(new MouseEvent('mouseup', Object.assign({}, o, { buttons: 0 })));
            best.dispatchEvent(new MouseEvent('click', Object.assign({}, o, { buttons: 0 })));
          } catch (e) { try { best.click(); } catch (e2) { return 'click-error'; } }
          return 'clicked:' + norm(best.textContent).slice(0, 30);
        })();
        """
    }

    /// Current session title shown in the crumb (verification step).
    static func crumbTextScript() -> String {
        """
        (() => {
          const c = document.querySelector('button[class*="crumbCurrent"]');
          return c ? (c.textContent || '').replace(/\\s+/g, ' ').trim() : 'none';
        })();
        """
    }

    /// Dump the clickable surface (and needle hits) as a JSON string.
    static func dumpScript(needle: String, idPrefix: String) -> String {
        let n = jsEscape(needle)
        let i = jsEscape(idPrefix)
        return """
        (() => {
          const needle = "\(n)", idPrefix = "\(i)";
          const norm = s => (s || '').replace(/\\s+/g, ' ').trim();
          const out = { buttons: [], near: [], byId: [] };
          let nBtn = 0;
          for (const el of document.querySelectorAll('button, [role="button"], [role="option"], [role="menuitem"], [role="tab"], [role="treeitem"], [tabindex="0"], [role="listitem"]')) {
            if (nBtn++ > 90) break;
            const t = norm(el.textContent).slice(0, 44);
            if (!t) continue;
            const cls = typeof el.className === 'string' ? el.className.slice(0, 40) : '';
            out.buttons.push(el.tagName.toLowerCase() + '.' + cls + ' role=' + (el.getAttribute('role') || '-') + ' | ' + t);
          }
          if (needle || idPrefix) {
            for (const el of document.querySelectorAll('*')) {
              const t = norm(el.textContent);
              if (needle && t && t.includes(needle) && t.length < 120 && out.near.length < 20) {
                const cls = typeof el.className === 'string' ? el.className.slice(0, 36) : '';
                out.near.push(el.tagName.toLowerCase() + '.' + cls + ' role=' + (el.getAttribute('role') || '-') + ' | ' + t.slice(0, 60));
              }
              if (idPrefix && out.byId.length < 20) {
                for (const a of el.attributes) {
                  if (a.value && a.value.includes(idPrefix)) {
                    out.byId.push(el.tagName.toLowerCase() + ' ' + a.name + '=' + a.value.slice(0, 60));
                    break;
                  }
                }
              }
            }
          }
          return JSON.stringify(out);
        })();
        """
    }

    /// Reflects AppState into the panel (status line + overlay logic).
    func update(snapshot: Snapshot) {
        lastSnapshot = snapshot
        serverRunning = snapshot.serverRunning
        panelVC.updateStatusLine(StatusText.detailLine(snapshot))

        if snapshot.serverRunning {
            if lastLoadFailed {
                // Server is back: retry now.
                reloadWebView()
            }
            if webViewLoaded {
                panelVC.hideOverlay()
            }
        } else if webViewLoaded, !lastLoadFailed {
            // Server went away while a page is loaded; keep the page but flag it.
            scheduleRetryIfNeeded()
        }
    }

    private func ensureWebView() {
        guard !webViewLoaded else { return }
        webViewLoaded = true
        lastLoadFailed = false
        panelVC.webView.load(URLRequest(url: baseURL))
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        lastLoadFailed = false
        panelVC.hideOverlay()
        if !loggedFinish {
            loggedFinish = true
            LogStore.shared.append("Web UI 加载完成", source: "desktop")
        }
        if pendingSessionTitle != nil {
        if pendingSessionTitle != nil {
            selectStageOpenPicker()
        }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        lastLoadFailed = true
        if !loggedFailure {
            loggedFailure = true
            LogStore.shared.append("Web UI 加载失败：\(error.localizedDescription)（服务恢复后自动重试）", source: "desktop")
        }
        panelVC.showOverlay("无法连接 DSH 服务\n\n服务离线时我会自动重试；你也可以从菜单手动「启动服务」。")
        scheduleRetryIfNeeded()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        lastLoadFailed = true
        scheduleRetryIfNeeded()
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // target=_blank links: hand off to the default browser.
        if navigationAction.navigationType == .linkActivated,
           navigationAction.targetFrame == nil,
           let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    // MARK: - Retry

    private func scheduleRetryIfNeeded() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.serverRunning, self.lastLoadFailed {
                self.reloadWebView()
            }
            if !self.lastLoadFailed {
                self.retryTimer?.invalidate()
                self.retryTimer = nil
            }
        }
        if let retryTimer { RunLoop.main.add(retryTimer, forMode: .common) }
    }
}

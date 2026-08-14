import AppKit

/// Builds the menu bar text / tooltip / detail lines from a state snapshot.
enum StatusText {
    /// (title, color) for the status item. Vibe Island style: recent
    /// high-signal events take the stage briefly, "needs you" states stick,
    /// and the bar falls back to a single status glyph when idle.
    static func mainText(_ snap: Snapshot) -> (String, NSColor) {
        if snap.serverStarting {
            return ("DSH 启动中…", .systemOrange)
        }
        if !snap.serverRunning {
            if !snap.serverError.isEmpty { return ("DSH 出错", .systemRed) }
            return ("DSH 离线", .secondaryLabelColor)
        }

        // 1. A session is waiting for you — sticky until resolved.
        if let waiting = snap.waitingSessions.first {
            let label = waiting.waitingKind == "approval" ? "待审批" : "等你回答"
            return ("DSH \(label)", .systemBlue)
        }

        // 2. A recent event is still fresh — flash it.
        if let ev = snap.statusEvent {
            switch ev.kind {
            case .completed, .turnDone, .goalComplete:
                return (ev.text, .systemGreen)
            case .failed, .blocked:
                return (ev.text, .systemRed)
            }
        }

        // 3. Fallback glyphs: the whale icon itself carries the activity
        // (breathing pulse / progress ring) — no text for mere busyness.
        let running = snap.runningSessions
        if let active = running.first {
            if active.goal?.phase == "blocked" { return ("DSH 阻塞", .systemRed) }
            return ("", .systemGreen)
        }
        if snap.sessions.first(where: { $0.goal?.phase == "blocked" }) != nil {
            return ("DSH 阻塞", .systemRed)
        }
        if snap.activeJobs > 0 {
            return ("DSH \(snap.activeJobs) 任务", .secondaryLabelColor)
        }
        // Idle: icon only, no text.
        return ("", .secondaryLabelColor)
    }

    /// Multi-line tooltip for the status item.
    static func tooltip(_ snap: Snapshot) -> String {
        var lines: [String] = []
        if snap.serverRunning {
            var serverLine = "服务器：运行中"
            if !snap.serverVersion.isEmpty { serverLine += " v\(snap.serverVersion)" }
            if snap.serverService {
                serverLine += "（launchd 系统服务）"
            } else {
                serverLine += "（\(snap.serverOwned ? "本应用托管" : "已挂载外部实例")）"
            }
            if !snap.model.isEmpty { serverLine += " · \(snap.provider)/\(snap.model)" }
            lines.append(serverLine)
        } else if snap.serverStarting {
            lines.append("服务器：正在启动…")
        } else {
            lines.append("服务器：离线" + (snap.serverError.isEmpty ? "" : "（\(snap.serverError)）"))
        }

        let show = Array(snap.sessions.prefix(6))
        if show.isEmpty {
            lines.append("暂无会话")
        } else {
            for s in show {
                lines.append(sessionLine(s))
            }
        }
        lines.append("")
        lines.append("左键：打开面板 · 右键：菜单 · ⌃⌥D：全局唤起")
        return lines.joined(separator: "\n")
    }

    /// One line for a session (menu / tooltip).
    static func sessionLine(_ s: SessionState) -> String {
        let name = s.title.isEmpty ? shortId(s.id) : s.title
        var line = name
        if let goal = s.goal {
            switch goal.phase {
            case "complete": line += " — 目标完成"
            case "blocked": line += " — 已阻塞" + (goal.blockedReason.map { "：\(truncate($0, limit: 30))" } ?? "")
            case "paused": line += " — 已暂停"
            default:
                line += " — 「\(truncate(goal.objective, limit: 24))」"
            }
        }
        if let todos = s.todos, !todos.isEmpty {
            let done = todos.filter { $0.status == "completed" }.count
            line += " · 待办 \(done)/\(todos.count)"
        } else if s.goal == nil, s.running {
            line += " · 步骤 \(s.steps)"
        }
        if s.waitingForUser && !s.waitingReason.isEmpty {
            line += "（\(truncate(s.waitingReason, limit: 40))）"
        }
        return line
    }

    /// Toolbar summary line inside the panel.
    static func detailLine(_ snap: Snapshot) -> String {
        if snap.serverStarting { return "正在启动 DSH 服务…" }
        if !snap.serverRunning {
            return "DSH 服务离线 — " + (snap.serverError.isEmpty ? "等待重新连接" : snap.serverError)
        }
        var parts: [String] = ["服务在线"]
        if !snap.serverVersion.isEmpty { parts.append("v\(snap.serverVersion)") }
        if !snap.model.isEmpty { parts.append("\(snap.provider)/\(snap.model)") }
        let running = snap.runningSessions.count
        if running > 0 { parts.append("\(running) 个会话运行中") }
        if snap.activeJobs > 0 { parts.append("\(snap.activeJobs) 个后台任务") }
        if let first = snap.runningSessions.first {
            if let goal = first.goal { parts.append("「\(first.title.isEmpty ? "会话" : first.title)」\(goal.progressText)") }
        }
        return parts.joined(separator: " · ")
    }

    private static func shortId(_ id: String) -> String {
        let uuid = id.replacingOccurrences(of: "session-", with: "")
        return uuid.count >= 8 ? "会话 " + String(uuid.prefix(8)) : id
    }

    private static func truncate(_ s: String, limit: Int) -> String {
        s.count <= limit ? s : String(s.prefix(limit)) + "…"
    }
}

/// Menu bar presence: the whale icon carries the state — static when idle,
/// swimming with a dot trail while busy (head flips when it turns), and
/// ringed with a progress arc when todos exist.
final class StatusItemController {
    private let item: NSStatusItem
    private var animTimer: Timer?
    private var ringTimer: Timer?
    private var frameIndex = 0
    private var ringProgress: Double = 0
    private var forcedRunningUntil: TimeInterval = 0

    /// Swim path (built once): right → left → right; the head always leads.
    private var swimFrames: [(x: CGFloat, movingLeft: Bool)] = []
    /// Progress-ring arc breathing (alpha only).
    private let arcAlphas: [CGFloat] = [0.92, 0.80, 0.66, 0.56, 0.66, 0.80]

    var onLeftClick: (() -> Void)?
    var onRightClick: (() -> Void)?

    init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        var frames: [(CGFloat, Bool)] = []
        var x: CGFloat = 16
        while x < 30.5 { frames.append((x, false)); x += 2 }
        while x > 15.5 { frames.append((x, true)); x -= 2 }
        swimFrames = frames
        if let button = item.button {
            button.image = Self.staticIcon()
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        render(AppState.shared.snapshot())
    }

    var button: NSStatusBarButton? { item.button }

    func render(_ snap: Snapshot) {
        let (text, color) = StatusText.mainText(snap)
        let attr = NSMutableAttributedString(string: text)
        attr.addAttributes([
            .font: NSFont.menuBarFont(ofSize: 0),
            .foregroundColor: color,
        ], range: NSRange(location: 0, length: attr.length))
        item.button?.attributedTitle = attr
        item.button?.toolTip = StatusText.tooltip(snap)
        updateIcon(snap)
    }

    // MARK: - Demos (defaults write debugBubble "running" | "ring")

    /// Force the swimming whale for a few seconds regardless of real state.
    func demoRunning(seconds: TimeInterval = 15) {
        forcedRunningUntil = Date().timeIntervalSince1970 + seconds
        stopRing()
        startSwim()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.2) { [weak self] in
            self?.render(AppState.shared.snapshot())
        }
    }

    /// Animate the progress ring sweeping to 80% and back to real state.
    func demoRing(seconds: TimeInterval = 8) {
        stopSwim()
        let steps = 20
        let interval = seconds / Double(steps)
        var i = 0
        ringTimer?.invalidate()
        ringTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            i += 1
            if i > steps {
                timer.invalidate()
                self.ringTimer = nil
                self.render(AppState.shared.snapshot())
                return
            }
            self.ringProgress = Double(i) / Double(steps) * 0.8
            self.item.button?.image = Self.ringIcon(progress: self.ringProgress, arcAlpha: 0.92)
        }
        if let ringTimer { RunLoop.main.add(ringTimer, forMode: .common) }
    }

    // MARK: - Icon states

    private func updateIcon(_ snap: Snapshot) {
        // Working state is ALWAYS the swimming whale with a dot trail
        // (todo progress stays in the tooltip and the right-click menu).
        let forced = forcedRunningUntil > Date().timeIntervalSince1970
        if forced || !snap.runningSessions.isEmpty {
            stopRing()
            startSwim()
            return
        }
        stopSwim()
        stopRing()
        item.button?.image = Self.staticIcon()
    }

    private func startSwim() {
        guard animTimer == nil else { return }
        frameIndex = 0
        animTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
            guard let self else { return }
            let frame = self.swimFrames[self.frameIndex % self.swimFrames.count]
            self.frameIndex += 1
            self.item.button?.image = Self.swimIcon(centerX: frame.x, movingLeft: frame.movingLeft)
        }
        if let animTimer { RunLoop.main.add(animTimer, forMode: .common) }
    }

    private func stopSwim() {
        animTimer?.invalidate()
        animTimer = nil
    }

    private func startRingPulse(progress: Double) {
        ringProgress = progress
        guard ringTimer == nil else { return }
        var i = 0
        ringTimer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: true) { [weak self] _ in
            guard let self else { return }
            let alpha = self.arcAlphas[i % self.arcAlphas.count]
            i += 1
            self.item.button?.image = Self.ringIcon(progress: self.ringProgress, arcAlpha: alpha)
        }
        if let ringTimer { RunLoop.main.add(ringTimer, forMode: .common) }
    }

    private func stopRing() {
        ringTimer?.invalidate()
        ringTimer = nil
    }

    // MARK: - Icon drawing (all template images: adaptive, transparent bg)

    private static func drawWhale(in rect: NSRect, alpha: CGFloat = 1, flipped: Bool = false) {
        guard let whalePath = Bundle.main.path(forResource: "StatusIcon", ofType: "svg"),
              let whale = NSImage(contentsOfFile: whalePath) else {
            // Fallback: letter D.
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                .foregroundColor: NSColor.black.withAlphaComponent(alpha),
            ]
            let text = "D" as NSString
            let textSize = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: rect.midX - textSize.width / 2,
                                  y: rect.midY - textSize.height / 2 - 0.5),
                      withAttributes: attrs)
            return
        }
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            whale.draw(in: rect)
            return
        }
        ctx.saveGState()
        ctx.setAlpha(alpha)
        if flipped {
            // Mirror about the rect's vertical center line.
            ctx.translateBy(x: rect.midX * 2, y: 0)
            ctx.scaleBy(x: -1, y: 1)
        }
        whale.draw(in: rect)
        ctx.restoreGState()
    }

    private static func templateImage(size: NSSize = NSSize(width: 18, height: 18),
                                      _ draw: () -> Void) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        draw()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    /// Idle: plain whale.
    static func staticIcon() -> NSImage {
        templateImage {
            drawWhale(in: NSRect(x: 1, y: 1, width: 16, height: 16))
        }
    }

    /// Busy: whale swimming at centerX with a fading dot trail behind it.
    static func swimIcon(centerX: CGFloat, movingLeft: Bool) -> NSImage {
        templateImage(size: NSSize(width: 46, height: 18)) {
            // Dots trail behind (opposite of the heading).
            let behind: CGFloat = movingLeft ? 1 : -1
            let alphas: [CGFloat] = [0.65, 0.45, 0.25]
            for (i, alpha) in alphas.enumerated() {
                let dx = behind * CGFloat(5 + i * 4)
                let dot = NSRect(x: centerX + dx - 1.3, y: 8.2, width: 2.6, height: 2.6)
                NSColor.black.withAlphaComponent(alpha).setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            // Head leads the motion (the official whale faces left).
            drawWhale(in: NSRect(x: centerX - 7, y: 2, width: 14, height: 14),
                      flipped: !movingLeft)
        }
    }

    /// Busy with todos: smaller whale + progress ring (track + arc).
    static func ringIcon(progress: Double, arcAlpha: CGFloat) -> NSImage {
        templateImage {
            drawWhale(in: NSRect(x: 3.4, y: 3.4, width: 11.2, height: 11.2))
            let center = NSPoint(x: 9, y: 9)
            let radius: CGFloat = 7.9
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 1.0
            NSColor.black.withAlphaComponent(0.22).setStroke()
            track.stroke()
            let clamped = min(max(progress, 0), 1)
            if clamped > 0.02 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius,
                              startAngle: 90, endAngle: 90 - 360 * clamped,
                              clockwise: true)
                arc.lineWidth = 1.8
                arc.lineCapStyle = .round
                NSColor.black.withAlphaComponent(arcAlpha).setStroke()
                arc.stroke()
            }
        }
    }

    @objc private func clicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            onRightClick?()
        } else {
            onLeftClick?()
        }
    }
}

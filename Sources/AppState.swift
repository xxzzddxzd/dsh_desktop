import Foundation

// MARK: - Wire-derived value types

struct JobView {
    let id: String
    let kind: String
    let label: String
    let status: String   // running | stopping | completed | killed | failed
    let detail: String?

    var isActive: Bool { status == "running" || status == "stopping" }
}

struct GoalView {
    let objective: String
    let phase: String    // active | paused | blocked | complete
    let roundsStarted: Int
    let maxGoalRounds: Int
    let blockedReason: String?

    var progressText: String {
        switch phase {
        case "complete": return "目标已完成"
        case "blocked": return "已阻塞：\(blockedReason ?? "原因未知")"
        case "paused": return "已暂停"
        default: return "进行中"
        }
    }
}

struct TodoRow {
    let content: String
    let status: String   // pending | in_progress | completed
}

/// One recent high-signal event surfaced in the menu bar (Vibe Island style):
/// completions flash briefly, "needs you" states stick until resolved.
struct StatusEvent {
    enum Kind {
        case completed      // a todo just completed
        case turnDone       // a session finished a turn
        case goalComplete   // goal reached completion
        case question       // the agent asked the user something
        case approval       // the agent needs a tool approval
        case failed         // background job failed
        case blocked        // goal became blocked
    }

    /// Blocking events (question/approval) jump the queue.
    var isUrgent: Bool {
        kind == .question || kind == .approval
    }
    let kind: Kind
    let text: String
    let at: TimeInterval
    var sessionId: String = ""
    var title: String = ""
}

/// Transient status events stay visible for this long.
let statusEventTtl: TimeInterval = 8

struct SessionState {
    var id: String
    var title: String = ""
    var cwd: String = ""
    var blank: Bool = false
    var running: Bool = false
    var updatedAt: TimeInterval = 0
    var steps: Int = 0
    var turns: Int = 0
    var goal: GoalView?
    var todos: [TodoRow]?
    var jobs: [JobView] = []
    var waitingForUser: Bool = false
    var waitingReason: String = ""
    var waitingKind: String = ""   // "question" | "approval"
    var waitingSince: TimeInterval = 0
    var lastError: String?
    var lastActivityAt: TimeInterval = 0
    var lastUserMessageAt: TimeInterval = 0
    var busySince: TimeInterval?
    var busyStartSteps: Int = 0
    var tokenOutput: Int = 0
    var lastTurnOutput: Int = 0
    var lastAssistantText: String = ""
    var lastTurnDoneAt: TimeInterval = 0
    var lastTurnEventAt: TimeInterval = 0
    var lastTurnBubbleAt: TimeInterval = 0
    var blockedBubbleKey: String = ""
    var lastGoalBubbleKey: String = ""
}

struct Snapshot {
    var serverRunning = false
    var serverOwned = false
    var serverStarting = false
    var serverService = false
    var serverVersion = ""
    var provider = ""
    var model = ""
    var serverError = ""
    var sessions: [SessionState] = []
    var activeJobs = 0
    var statusEvent: StatusEvent?
    var queuedEvents: Int = 0
    var queuePreview: [StatusEvent] = []
    /// Session id → workspace title (mirrors the web UI's workspace view).
    var workspaceTitles: [String: String] = [:]
    var archivedSessionIds: Set<String> = []

    var waitingSessions: [SessionState] { sessions.filter { $0.waitingForUser } }
    var runningSessions: [SessionState] { sessions.filter { $0.running } }
}

/// One pending tool-approval request (answerable directly from the bubble).
struct ApprovalInfo {
    let sessionId: String
    let approvalId: String
    let rpcId: String
    let toolName: String
    let reason: String
}

// MARK: - Central state aggregator

final class AppState {
    static let shared = AppState()

    private let queue = DispatchQueue(label: "dsh.appstate")
    private var sessions: [String: SessionState] = [:]
    private var serverRunning = false
    private var serverOwned = false
    private var serverStarting = false
    private var serverService = false
    private var serverVersion = ""
    private var provider = ""
    private var model = ""
    private var serverError = ""
    private var notifyPending = false
    private var lastGoalNotification = ""
    private var transientEvent: StatusEvent?
    private var muxConnectedAt: TimeInterval = 0
    private var lastMuxFrameAt: TimeInterval = 0
    private struct WorkspaceInfo {
        var title: String
        var sessionIds: [String]
    }
    private var workspaces: [String: WorkspaceInfo] = [:]
    private var archivedSessionIds: Set<String> = []

    /// workspace.list: the authoritative workspace membership the web UI uses.
    func ingestWorkspaceList(_ dict: [String: Any]) {
        queue.async { [self] in
            if let items = dict["items"] as? [[String: Any]] {
                for item in items {
                    guard let id = item["workspaceId"] as? String else { continue }
                    workspaces[id] = WorkspaceInfo(
                        title: item["title"] as? String ?? "",
                        sessionIds: item["sessionIds"] as? [String] ?? [])
                }
            }
            if let arch = dict["archivedSessionIds"] as? [String] {
                archivedSessionIds = Set(arch)
            }
            publish()
        }
    }

    /// Sessions the user recently viewed in ANY client (web UI or our panel):
    /// the server broadcasts session/subscribed for those, so the completion
    /// queue can stay backend-authoritative.
    private var recentlyViewedAt: [String: TimeInterval] = [:]
    /// Clickable completion queue: the front shows in the bar until the user
    /// clicks it (then the next one surfaces).
    private var eventQueue: [StatusEvent] = []

    /// Fired on the main thread whenever state changes.
    var onChange: (() -> Void)?
    /// Fired on the main thread when a bubble should pop under the menu bar.
    var onBubble: ((String, String, String) -> Void)?
    /// Fired on the main thread when an approval can be answered from a bubble.
    var onApproval: ((ApprovalInfo) -> Void)?
    /// Fired on the main thread when an approval resolved (bubble can dismiss).
    var onApprovalResolved: ((String) -> Void)?

    // MARK: Public ingestion (any thread)

    func setServer(running: Bool, owned: Bool, starting: Bool, version: String, provider: String, model: String, error: String, service: Bool? = nil) {
        queue.async { [self] in
            let wasRunning = serverRunning
            serverRunning = running
            serverOwned = owned
            serverStarting = starting
            if let service { serverService = service }
            serverVersion = version
            self.provider = provider
            self.model = model
            serverError = error
            if !running && wasRunning {
                // Server went away; mark every session idle so the bar doesn't lie.
                for key in sessions.keys {
                    sessions[key]?.running = false
                    sessions[key]?.busySince = nil
                    sessions[key]?.waitingForUser = false
                }
                if Settings.shared.notifyServerEvents && Settings.shared.notificationsEnabled {
                    Notifier.shared.notify(id: "server-down", title: "DSH 服务已离线", body: "菜单栏显示离线状态；若开启了自动启动将尝试重新拉起。")
                }
            }
            if running && !wasRunning && !serverOwned {
                LogStore.shared.append("已挂载到运行中的 DSH 服务（端口 \(Settings.shared.port)）", source: "desktop")
            }
            publish()
        }
    }

    func ingestSessionList(_ items: [[String: Any]]) {
        queue.async { [self] in
            var seen = Set<String>()
            for item in items {
                guard let id = item["sessionId"] as? String else { continue }
                seen.insert(id)
                var s = sessions[id] ?? SessionState(id: id)
                applySummary(item, to: &s)
                sessions[id] = s
            }
            // Drop sessions the server no longer reports.
            for key in sessions.keys where !seen.contains(key) {
                sessions.removeValue(forKey: key)
            }
            publish()
        }
    }

    func ingestHostFrame(_ payload: [String: Any]) {
        queue.async { [self] in
            applyHostFrame(payload)
            publish()
        }
    }

    /// Called once when the mux stream (re)starts, so the connection's
    /// bootstrap auto-subscribe frames can be told apart from real views.
    func noteMuxConnected() {
        queue.async { [self] in
            muxConnectedAt = Date().timeIntervalSince1970
        }
    }

    func ingestMuxFrame(_ payload: [String: Any], rpcId: String = "") {
        queue.async { [self] in
            let prevFrameAt = lastMuxFrameAt
            lastMuxFrameAt = Date().timeIntervalSince1970
            applyMuxFrame(payload, rpcId: rpcId, prevFrameAt: prevFrameAt)
            publish()
        }
    }

    func snapshot() -> Snapshot {
        queue.sync { buildSnapshotLocked() }
    }

    // MARK: - Frame application (queue only)

    private func applyHostFrame(_ payload: [String: Any]) {
        guard let type = payload["type"] as? String else { return }
        switch type {
        case "host/session-added":
            let id = payload["sessionId"] as? String ?? ""
            guard !id.isEmpty else { return }
            var s = sessions[id] ?? SessionState(id: id)
            s.blank = payload["blank"] as? Bool ?? false
            if let cwd = payload["cwd"] as? String { s.cwd = cwd }
            sessions[id] = s
        case "host/session-removed":
            if let id = payload["sessionId"] as? String {
                sessions.removeValue(forKey: id)
            }
        case "host/session-status":
            guard let id = payload["sessionId"] as? String,
                  let running = payload["running"] as? Bool else { return }
            var s = sessions[id] ?? SessionState(id: id)
            handleRunningTransition(&s, running: running, source: "ws-status")
            sessions[id] = s
        case "host/workspace-changed":
            if let w = payload["workspace"] as? [String: Any],
               let id = w["workspaceId"] as? String {
                workspaces[id] = WorkspaceInfo(
                    title: w["title"] as? String ?? "",
                    sessionIds: w["sessionIds"] as? [String] ?? [])
            }
        case "host/workspace-removed":
            if let id = payload["workspaceId"] as? String {
                workspaces.removeValue(forKey: id)
            }
        case "host/archived-sessions-changed":
            if let ids = payload["archivedSessionIds"] as? [String] {
                archivedSessionIds = Set(ids)
            }
        case "host/agent-error":
            guard let id = payload["sessionId"] as? String else { return }
            var s = sessions[id] ?? SessionState(id: id)
            s.lastError = payload["message"] as? String
            sessions[id] = s
            if Settings.shared.notifyServerEvents && Settings.shared.notificationsEnabled {
                Notifier.shared.notify(id: "agent-error-\(id)", title: "DSH 会话出错",
                                       body: s.lastError ?? "未知错误")
            }
        default:
            break
        }
    }

    private func applyMuxFrame(_ payload: [String: Any], rpcId: String = "", prevFrameAt: TimeInterval = 0) {
        guard let type = payload["type"] as? String else { return }
        let sid = payload["sessionId"] as? String ?? ""

        switch type {
        case "session/subscribed":
            guard !sid.isEmpty else { return }
            if sessions[sid] == nil { sessions[sid] = SessionState(id: sid) }
            // The server broadcasts a subscribed baseline for the most
            // recent session when a NEW connection attaches. Ignore those
            // bootstrap frames; every other subscribed frame means some
            // client (e.g. Safari with this session open) is now viewing
            // the session — treat it as read.
            let now = Date().timeIntervalSince1970
            let isBootstrap = (muxConnectedAt > 0 && now - muxConnectedAt < 5)
                || (prevFrameAt == 0 || now - prevFrameAt > 5)
            if !isBootstrap {
                noteUserEngagement(sid)
            }
        case "session/event":
            guard !sid.isEmpty,
                  let event = payload["event"] as? [String: Any],
                  let eventType = event["type"] as? String else { return }
            var s = sessions[sid] ?? SessionState(id: sid)
            if let time = event["time"] as? Double { s.updatedAt = max(s.updatedAt, time / 1000) }
            applySessionEvent(eventType, data: event["data"], to: &s)
            sessions[sid] = s
        case "session/projection":
            guard !sid.isEmpty,
                  let key = payload["key"] as? String else { return }
            var s = sessions[sid] ?? SessionState(id: sid)
            applyProjection(key, value: payload["value"], to: &s)
            sessions[sid] = s
        case "session/jobs":
            guard !sid.isEmpty else { return }
            var s = sessions[sid] ?? SessionState(id: sid)
            let old = s.jobs
            s.jobs = parseJobs(payload["jobs"])
            for job in s.jobs where job.status == "failed" {
                if !old.contains(where: { $0.id == job.id && $0.status == "failed" }) {
                    setTransient(.failed, text: "\(truncate(job.label, limit: 12)) 失败")
                    if Settings.shared.notificationsEnabled {
                        Notifier.shared.notify(id: "job-failed-\(job.id)", title: "DSH 后台任务失败",
                                               body: "\(job.label)（\(job.detail ?? job.kind)）")
                    }
                }
            }
            sessions[sid] = s
        case "question/requested":
            guard !sid.isEmpty else { return }
            var s = sessions[sid] ?? SessionState(id: sid)
            s.waitingForUser = true
            s.waitingKind = "question"
            s.waitingSince = Date().timeIntervalSince1970
            let questions = payload["questions"] as? [[String: Any]] ?? []
            if let first = questions.first {
                s.waitingReason = first["question"] as? String ?? "需要你的回答"
            } else {
                s.waitingReason = "需要你的回答"
            }
            sessions[sid] = s
            enqueueEvent(.question, sessionId: sid, title: s.title,
                         text: "等你回答 · \(truncate(s.waitingReason, limit: 26))", urgent: true)
            if Settings.shared.wantsBubble {
                let reason = truncate(s.waitingReason, limit: 140)
                DispatchQueue.main.async { [weak self] in
                    self?.onBubble?("需要你的回答", reason, sid)
                }
            }
            if Settings.shared.wantsNotification,
               Settings.shared.notifyWaitingInput && Settings.shared.notificationsEnabled {
                Notifier.shared.notify(id: "question-\(sid)", title: "DSH 正在等你",
                                       body: truncate(s.waitingReason, limit: 120))
            }
        case "question/resolved":
            guard !sid.isEmpty, var s = sessions[sid] else { return }
            clearWaiting(&s)
            sessions[sid] = s
            dequeueEvents(for: sid, kind: .question)
        case "approval/requested":
            guard !sid.isEmpty else { return }
            var s = sessions[sid] ?? SessionState(id: sid)
            s.waitingForUser = true
            s.waitingKind = "approval"
            s.waitingSince = Date().timeIntervalSince1970
            let tool = payload["toolName"] as? String ?? "工具"
            let reason = payload["reason"] as? String ?? ""
            s.waitingReason = "\(tool) 需要你的授权" + (reason.isEmpty ? "" : "：\(truncate(reason, limit: 60))")
            sessions[sid] = s
            let approval = ApprovalInfo(sessionId: sid,
                                        approvalId: payload["approvalId"] as? String ?? "",
                                        rpcId: rpcId,
                                        toolName: tool,
                                        reason: reason)
            enqueueEvent(.approval, sessionId: sid, title: s.title,
                         text: "待审批 · \(truncate(tool, limit: 12))\(reason.isEmpty ? "" : "：" + truncate(reason, limit: 14))", urgent: true)
            if Settings.shared.wantsBubble {
                DispatchQueue.main.async { [weak self] in
                    self?.onApproval?(approval)
                }
            }
            if Settings.shared.wantsNotification,
               Settings.shared.notifyWaitingInput && Settings.shared.notificationsEnabled {
                Notifier.shared.notify(id: "approval-\(sid)", title: "DSH 请求授权",
                                       body: truncate(s.waitingReason, limit: 120))
            }
        case "approval/resolved":
            guard !sid.isEmpty else { return }
            if var s = sessions[sid] {
                clearWaiting(&s)
                sessions[sid] = s
            }
            dequeueEvents(for: sid, kind: .approval)
            let resolvedId = payload["approvalId"] as? String ?? ""
            DispatchQueue.main.async { [weak self] in
                self?.onApprovalResolved?(resolvedId)
            }
        default:
            break
        }
    }

    /// Genuine agent activity: refresh the activity clock and start the busy
    /// timer if it is not already running. The `running` flag itself is
    /// NEVER set here — it belongs to the server's authoritative frames.
    /// Late mux stragglers that land after the server already said
    /// running=false must not resurrect the swim or a bogus busy clock.
    private func markActivity(_ s: inout SessionState) {
        let now = Date().timeIntervalSince1970
        s.lastActivityAt = now
        guard s.running else { return }
        if s.busySince == nil {
            s.busySince = now
            s.busyStartSteps = s.steps
            s.lastAssistantText = ""
        }
        // Throttled persistence: a mid-turn relaunch (e.g. an app update)
        // resumes the busy clock instead of truncating the turn.
        persistBusySince(s)
    }

    private func persistBusySince(_ s: SessionState) {
        guard let since = s.busySince else { return }
        let now = Date().timeIntervalSince1970
        let key = "busySince.\(s.id)"
        if now - UserDefaults.standard.double(forKey: key + ".w") > 30 {
            UserDefaults.standard.set(since, forKey: key)
            UserDefaults.standard.set(now, forKey: key + ".w")
        }
    }

    /// Resume a busy clock that a recent relaunch interrupted (<=90s old).
    private func restoreBusySince(_ s: inout SessionState) {
        guard s.busySince == nil, s.running else { return }
        let key = "busySince.\(s.id)"
        let since = UserDefaults.standard.double(forKey: key)
        let now = Date().timeIntervalSince1970
        if since > 0, now - since <= 90 {
            s.busySince = since
            s.busyStartSteps = 0
        }
    }

    private func clearPersistedBusySince(_ id: String) {
        UserDefaults.standard.removeObject(forKey: "busySince.\(id)")
        UserDefaults.standard.removeObject(forKey: "busySince.\(id).w")
    }

    /// The agent resumed or answered: it is no longer waiting for the user.
    private func clearWaiting(_ s: inout SessionState) {
        s.waitingForUser = false
        s.waitingReason = ""
        s.waitingKind = ""
        s.waitingSince = 0
    }

    private func applySessionEvent(_ type: String, data: Any?, to s: inout SessionState) {
        switch type {
        case "user/message":
            // The user sent a prompt in this session: they are right there,
            // so any completion prompt for it is stale.
            s.lastUserMessageAt = Date().timeIntervalSince1970
            noteUserEngagement(s.id)
        case "step/start", "step/end":
            if let dict = data as? [String: Any], let step = dict["step"] as? Int { s.steps = step }
            markActivity(&s)
        case "goal/change":
            applyGoalChange(data as? [String: Any], to: &s)
        case "todo/write":
            // The todo/write event carries the whole replacement list.
            if let list = data as? [[String: Any]] {
                updateTodos(parseTodos(list), in: &s)
            } else if let dict = data as? [String: Any],
                      let list = (dict["todos"] ?? dict["items"]) as? [[String: Any]] {
                updateTodos(parseTodos(list), in: &s)
            }
        case "assistant/message":
            markActivity(&s)
            // Capture the assistant's text for the turn-end brief.
            if let dict = data as? [String: Any],
               let message = dict["message"] as? [String: Any],
               let blocks = message["content"] as? [[String: Any]] {
                var text = ""
                for block in blocks where block["type"] as? String == "text" {
                    if let t = block["text"] as? String { text += t }
                }
                let trimmed = text.replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    s.lastAssistantText = truncate(trimmed, limit: 100)
                }
            }
            // The agent is actively working again: any stale "waiting for
            // user" state from a missed resolution frame is over.
            clearWaiting(&s)
        case "tool/call", "tool/result", "assistant/chunk":
            markActivity(&s)
            clearWaiting(&s)
        default:
            break
        }
    }

    private func applyProjection(_ key: String, value: Any?, to s: inout SessionState) {
        switch key {
        case "goal":
            guard let dict = value as? [String: Any] else { s.goal = nil; return }
            s.goal = parseGoal(dict)
        case "todos":
            if let list = value as? [[String: Any]] {
                updateTodos(parseTodos(list), in: &s)
            } else if value is NSNull {
                s.todos = nil
            }
        case "sessionStats":
            guard let dict = value as? [String: Any] else { return }
            if let turns = dict["turns"] as? Int { s.turns = turns }
            if let steps = dict["steps"] as? Int { s.steps = steps }
        case "tokenUsage":
            guard let dict = value as? [String: Any] else { return }
            if let out = dict["outputTokens"] as? Int { s.tokenOutput = out }
        case "title":
            if let title = value as? String, !title.isEmpty { s.title = title }
        default:
            break
        }
    }

    private func applySummary(_ item: [String: Any], to s: inout SessionState) {
        if let t = item["updatedAt"] as? Double { s.updatedAt = max(s.updatedAt, t / 1000) }
        if let running = item["running"] as? Bool {
            handleRunningTransition(&s, running: running, source: "poll")
        }
        restoreBusySince(&s)
        s.blank = item["blank"] as? Bool ?? false
        if let cwd = item["cwd"] as? String { s.cwd = cwd }
        if let projections = item["projections"] as? [String: Any],
           let values = projections["values"] as? [String: Any] {
            if let title = values["title"] as? String { s.title = title }
            if let goal = values["goal"] as? [String: Any] {
                s.goal = parseGoal(goal)
                handleBlockedGoal(&s)
            }
            if let todos = values["todos"] as? [[String: Any]] { updateTodos(parseTodos(todos), in: &s) }
            if let stats = values["sessionStats"] as? [String: Any] {
                if let turns = stats["turns"] as? Int { s.turns = turns }
                if let steps = stats["steps"] as? Int { s.steps = steps }
            }
        }
    }

    private func handleRunningTransition(_ s: inout SessionState, running: Bool, source: String = "?") {
        let now = Date().timeIntervalSince1970
        if running {
            // NOTE: busySince is deliberately NOT set here. Only genuine
            // activity events (assistant messages, tool calls, steps) start
            // the busy clock — a bare running=true claim with no activity
            // must never produce completion alerts.
            if s.running != running {
                LogStore.shared.append("run: \(s.id.prefix(8)) -> true [\(source)]", source: "desktop")
            }
            s.running = true
            // Resuming after an answer/approval: the wait is over.
            if s.waitingForUser { clearWaiting(&s) }
        } else {
            let wasRunning = s.running
            if wasRunning != running {
                LogStore.shared.append("run: \(s.id.prefix(8)) -> false [\(source)]", source: "desktop")
            }
            s.running = false
            clearPersistedBusySince(s.id)
            if wasRunning, let since = s.busySince {
                let duration = now - since
                s.busySince = nil
                let stepsDelta = s.busyStartSteps > 0 ? max(0, s.steps - s.busyStartSteps) : 0
                let outDelta = s.tokenOutput > 0 ? max(0, s.tokenOutput - s.lastTurnOutput) : 0
                s.lastTurnOutput = s.tokenOutput
                s.busyStartSteps = 0

                // If the user messaged this session within the last 5
                // minutes AND nothing else is running, they are watching the
                // only show — the completion is self-evident and stays quiet.
                // With other sessions still working, a completion is news
                // (which one finished?) and alerts normally.
                let othersRunning = sessions.values.contains { $0.id != s.id && $0.running }
                let engaged = s.lastUserMessageAt > 0 && now - s.lastUserMessageAt < 300 && !othersRunning

                // Turns under 8s are not worth a queue entry.
                if duration >= 8, !engaged, now - s.lastTurnEventAt > 20 {
                    s.lastTurnEventAt = now
                    let snippet = s.lastAssistantText.isEmpty
                        ? (s.title.isEmpty ? "会话" : s.title)
                        : s.lastAssistantText
                    enqueueEvent(.turnDone, sessionId: s.id, title: s.title,
                                 text: "完成 · \(truncate(snippet, limit: 22))")
                }

                // Task completion: bubble with a brief (steps / tokens /
                // duration + the assistant's closing words). Fires eagerly
                // (>=5s) so it tracks the status bar, never lags a turn.
                // Bubbles for real work (>=20s).
                if duration >= 20, !engaged, now - s.lastTurnBubbleAt > 30, Settings.shared.wantsBubble {
                    s.lastTurnBubbleAt = now
                    var parts: [String] = []
                    if stepsDelta > 0 { parts.append("步骤 \(stepsDelta)") }
                    if outDelta > 0 { parts.append("输出 \(Self.fmtTokens(outDelta)) tokens") }
                    parts.append("耗时 \(Self.fmtDuration(duration))")
                    var brief = parts.joined(separator: " · ")
                    if !s.lastAssistantText.isEmpty {
                        brief += "\n" + s.lastAssistantText
                    }
                    let name = s.title.isEmpty ? "会话" : truncate(s.title, limit: 16)
                    let sid = s.id
                    LogStore.shared.append("bubble: turn-done · \(name) · \(parts.joined(separator: " · "))", source: "desktop")
                    DispatchQueue.main.async { [weak self] in
                        self?.onBubble?("任务完成 · \(name)", brief, sid)
                    }
                }

                let coolDown = now - s.lastTurnDoneAt
                if duration >= 20, !engaged, coolDown > 60,
                   Settings.shared.wantsNotification,
                   Settings.shared.notifyTurnDone, Settings.shared.notificationsEnabled {
                    s.lastTurnDoneAt = now
                    let name = s.title.isEmpty ? s.id : s.title
                    Notifier.shared.notify(id: "turn-done-\(s.id)", title: "DSH 完成了一轮工作",
                                           body: "「\(truncate(name, limit: 60))」已空闲，耗时 \(Int(duration))s。")
                }
            }
        }
    }

    private func applyGoalChange(_ data: [String: Any]?, to s: inout SessionState) {
        guard let data else { return }
        let operation = data["operation"] as? String ?? ""
        if operation == "clear" {
            let old = s.goal
            s.goal = nil
            s.blockedBubbleKey = ""
            if old != nil && Settings.shared.notifyGoalEvents && Settings.shared.notificationsEnabled {
                Notifier.shared.notify(id: "goal-clear-\(s.id)", title: "DSH 目标已清除",
                                       body: "「\(truncate(old!.objective, limit: 80))」被清除。")
            }
            return
        }
        guard let goalDict = data["goal"] as? [String: Any] else { return }
        var projection: [String: Any] = goalDict
        projection["roundsStarted"] = data["roundsStarted"]
        projection["createdAt"] = data["createdAt"]
        projection["updatedAt"] = data["updatedAt"]
        let old = s.goal
        s.goal = parseGoal(projection)
        handleBlockedGoal(&s)
        if let goal = s.goal, Settings.shared.notifyGoalEvents, Settings.shared.notificationsEnabled {
            let key = "\(s.id)-\(goal.phase)-\(operation)"
            if key != lastGoalNotification {
                lastGoalNotification = key
                switch goal.phase {
                case "complete":
                    enqueueEvent(.goalComplete, sessionId: s.id, title: s.title,
                                 text: "目标完成 · \(truncate(goal.objective, limit: 22))")
                    if Settings.shared.wantsNotification {
                        Notifier.shared.notify(id: "goal-complete-\(s.id)", title: "DSH 目标完成",
                                               body: "「\(truncate(goal.objective, limit: 80))」已完成。")
                    }
                    if Settings.shared.wantsBubble, key != s.lastGoalBubbleKey {
                        s.lastGoalBubbleKey = key
                        let objective = truncate(goal.objective, limit: 90)
                        let sid = s.id
                        LogStore.shared.append("bubble: goal-complete · \(objective)", source: "desktop")
                        DispatchQueue.main.async { [weak self] in
                            self?.onBubble?("目标完成", objective, sid)
                        }
                    }
                default:
                    if old == nil {
                        Notifier.shared.notify(id: "goal-created-\(s.id)", title: "DSH 目标已创建",
                                               body: "「\(truncate(goal.objective, limit: 80))」")
                    }
                }
            }
        }
    }

    /// A goal entering (or re-entering after a change) the blocked phase gets
    /// a status-bar flash, a macOS notification, and a transient bubble.
    private func handleBlockedGoal(_ s: inout SessionState) {
        guard let goal = s.goal else {
            s.blockedBubbleKey = ""
            return
        }
        if goal.phase == "blocked" {
            let key = "\(goal.objective)#\(goal.blockedReason ?? "")"
            guard key != s.blockedBubbleKey else { return }
            s.blockedBubbleKey = key
            let reason = goal.blockedReason ?? goal.objective
            setTransient(.blocked, text: "目标阻塞")
            if Settings.shared.wantsNotification,
               Settings.shared.notifyGoalEvents && Settings.shared.notificationsEnabled {
                Notifier.shared.notify(id: "goal-blocked-\(s.id)", title: "DSH 目标已阻塞",
                                       body: truncate(reason, limit: 120))
            }
            if Settings.shared.wantsBubble {
                LogStore.shared.append("bubble: blocked · \(truncate(reason, limit: 60))", source: "desktop")
                let sid = s.id
                DispatchQueue.main.async { [weak self] in
                    self?.onBubble?("目标已阻塞", reason, sid)
                }
            }
        } else {
            s.blockedBubbleKey = ""
        }
    }

    // MARK: - Parsers

    private func parseGoal(_ dict: [String: Any]) -> GoalView? {
        guard let goal = dict["goal"] as? [String: Any],
              let objective = goal["objective"] as? String else {
            // Projection may carry the snapshot fields directly (no nested "goal").
            if let objective = dict["objective"] as? String {
                return GoalView(objective: objective,
                                phase: dict["phase"] as? String ?? "active",
                                roundsStarted: dict["roundsStarted"] as? Int ?? 0,
                                maxGoalRounds: dict["maxGoalRounds"] as? Int ?? 0,
                                blockedReason: (dict["blockedReason"] as? [String: Any])?["message"] as? String)
            }
            return nil
        }
        return GoalView(objective: objective,
                        phase: goal["phase"] as? String ?? "active",
                        roundsStarted: dict["roundsStarted"] as? Int ?? 0,
                        maxGoalRounds: goal["maxGoalRounds"] as? Int ?? 0,
                        blockedReason: (goal["blockedReason"] as? [String: Any])?["message"] as? String)
    }

    private func parseTodos(_ list: [[String: Any]]) -> [TodoRow] {
        list.compactMap { row in
            guard let content = row["content"] as? String,
                  let status = row["status"] as? String else { return nil }
            return TodoRow(content: content, status: status)
        }
    }

    /// Applies a fresh todo list and flashes the newly completed items in the
    /// menu bar (Vibe Island style). Never fires on the initial fill.
    private func updateTodos(_ new: [TodoRow]?, in s: inout SessionState) {
        let old = s.todos
        s.todos = new
        guard let new, let old, !old.isEmpty else { return }
        let newlyCompleted = new.filter { row in
            row.status == "completed" && !old.contains(where: {
                $0.content == row.content && $0.status == "completed"
            })
        }
        if let first = newlyCompleted.first {
            let extra = newlyCompleted.count > 1 ? " +\(newlyCompleted.count - 1)" : ""
            enqueueEvent(.completed, sessionId: s.id, title: s.title,
                         text: "完成 \(truncate(first.content, limit: 14))\(extra)")
        }
    }

    /// Short-lived status flash (blocked / failed alerts, not clickable).
    private func setTransient(_ kind: StatusEvent.Kind, text: String) {
        let event = StatusEvent(kind: kind, text: text, at: Date().timeIntervalSince1970)
        transientEvent = event
        DispatchQueue.main.asyncAfter(deadline: .now() + statusEventTtl + 0.5) { [weak self] in
            self?.queue.async {
                self?.publish()
            }
        }
    }

    /// The user engaged a session (opened it in any client, or sent a
    /// message in it): its completion prompts are stale — dequeue them.
    private func noteUserEngagement(_ sid: String) {
        guard !sid.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        recentlyViewedAt[sid] = now
        let removed = eventQueue.filter { $0.sessionId == sid }.count
        if removed > 0 {
            eventQueue.removeAll { $0.sessionId == sid }
            LogStore.shared.append("viewed: \(sid.prefix(8)) → 出队 \(removed) 条完成提示", source: "desktop")
        }
    }

    /// Queue a clickable event carrying the session's BRIEF (not just its
    /// title). Urgent events (question/approval) jump ahead of completions.
    private func enqueueEvent(_ kind: StatusEvent.Kind, sessionId: String, title: String, text: String, urgent: Bool = false) {
        // The user already saw this session elsewhere: no stale prompt.
        let now = Date().timeIntervalSince1970
        if let viewedAt = recentlyViewedAt[sessionId], now - viewedAt < 90 {
            return
        }
        var event = StatusEvent(kind: kind, text: text, at: now)
        event.sessionId = sessionId
        event.title = title
        if urgent {
            let firstNonUrgent = eventQueue.firstIndex { !$0.isUrgent }
            eventQueue.insert(event, at: firstNonUrgent ?? eventQueue.count)
        } else {
            eventQueue.append(event)
        }
        if eventQueue.count > 8 { eventQueue.removeFirst(eventQueue.count - 8) }
    }

    /// Drop queued events for one session (optionally one kind).
    private func dequeueEvents(for sid: String, kind: StatusEvent.Kind? = nil) {
        let before = eventQueue.count
        eventQueue.removeAll { $0.sessionId == sid && (kind == nil || $0.kind == kind) }
        if eventQueue.count != before {
            LogStore.shared.append("dequeue: \(sid.prefix(8)) → 剩余 \(eventQueue.count) 条", source: "desktop")
        }
    }

    /// The user clicked the front event: drop it and surface the next.
    func consumeFrontEvent() {
        queue.async { [self] in
            if !eventQueue.isEmpty {
                eventQueue.removeFirst()
            }
            publish()
        }
    }

    /// The user clicked a bubble for one session: drop ITS events.
    func consumeEvents(for sessionId: String) {
        queue.async { [self] in
            dequeueEvents(for: sessionId)
            publish()
        }
    }

    private func parseJobs(_ raw: Any?) -> [JobView] {
        guard let list = raw as? [[String: Any]] else { return [] }
        return list.compactMap { row in
            guard let id = row["id"] as? String,
                  let kind = row["kind"] as? String,
                  let label = row["label"] as? String,
                  let status = row["status"] as? String else { return nil }
            return JobView(id: id, kind: kind, label: label, status: status, detail: row["detail"] as? String)
        }
    }

    private func buildSnapshotLocked() -> Snapshot {
        let nowNow = Date().timeIntervalSince1970
        var snap = Snapshot()
        snap.serverRunning = serverRunning
        snap.serverOwned = serverOwned
        snap.serverStarting = serverStarting
        snap.serverService = serverService
        snap.serverVersion = serverVersion
        snap.provider = provider
        snap.model = model
        snap.serverError = serverError
        snap.sessions = sessions.values.sorted { $0.updatedAt > $1.updatedAt }
        snap.activeJobs = sessions.values.reduce(0) { $0 + $1.jobs.filter(\.isActive).count }
        // Completion queue: front surfaces; entries expire after 10 minutes.
        while let front = eventQueue.first, nowNow - front.at > 600 {
            eventQueue.removeFirst()
        }
        snap.queuedEvents = eventQueue.count
        snap.queuePreview = Array(eventQueue.prefix(5))
        snap.archivedSessionIds = archivedSessionIds
        for w in workspaces.values {
            for sid in w.sessionIds {
                if snap.workspaceTitles[sid] == nil {
                    snap.workspaceTitles[sid] = w.title
                }
            }
        }
        if let ev = eventQueue.first {
            snap.statusEvent = ev
        } else if let ev = transientEvent, nowNow - ev.at < statusEventTtl {
            snap.statusEvent = ev
        }
        for (key, at) in recentlyViewedAt where nowNow - at > 90 {
            recentlyViewedAt.removeValue(forKey: key)
        }
        // A running flag with no recent activity is a phantom (idle session):
        // render it as idle so the bar doesn't swim forever.
        for key in sessions.keys {
            guard let s = sessions[key], s.running, s.lastActivityAt > 0,
                  nowNow - s.lastActivityAt > 300 else { continue }
            sessions[key]?.running = false
        }
        // Hard expiry: a waiting flag that survives 10 minutes with no
        // resolution frame is stale (missed frame / WS gap) — drop it.
        let now = Date().timeIntervalSince1970
        for key in sessions.keys {
            guard let s = sessions[key], s.waitingForUser,
                  s.waitingSince > 0, now - s.waitingSince > 600 else { continue }
            sessions[key]?.waitingForUser = false
            sessions[key]?.waitingReason = ""
            sessions[key]?.waitingKind = ""
            sessions[key]?.waitingSince = 0
        }
        return snap
    }

    private func publish() {
        if !notifyPending {
            notifyPending = true
            DispatchQueue.main.async { [self] in
                notifyPending = false
                onChange?()
            }
        }
    }

    private func truncate(_ s: String, limit: Int) -> String {
        s.count <= limit ? s : String(s.prefix(limit)) + "…"
    }

    private static func fmtDuration(_ secs: TimeInterval) -> String {
        if secs < 60 { return "\(Int(secs)) 秒" }
        let m = Int(secs) / 60
        let s = Int(secs) % 60
        return s == 0 ? "\(m) 分钟" : "\(m) 分 \(s) 秒"
    }

    private static func fmtTokens(_ n: Int) -> String {
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }
}

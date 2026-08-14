import Foundation

/// Subscribes to the two DSH server→client WebSocket downlinks
/// (/api/events.host and /api/events.mux) with automatic reconnect.
final class DshStreams: NSObject {
    private let session: URLSession
    private let queue = OperationQueue()
    private var hostTask: URLSessionWebSocketTask?
    private var muxTask: URLSessionWebSocketTask?
    private var hostBackoff: TimeInterval = 1
    private var muxBackoff: TimeInterval = 1
    private var hostConnected = false
    private var muxConnected = false
    private var closed = false
    private var port: Int

    /// Called on the main thread with (kind "host"|"mux", envelope rpcId, payload).
    var onFrame: ((String, String, [String: Any]) -> Void)?

    init(port: Int) {
        self.port = port
        queue.maxConcurrentOperationCount = 1
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config, delegate: nil, delegateQueue: queue)
        super.init()
    }

    func start() {
        connect(kind: "host", path: "/api/events.host")
        connect(kind: "mux", path: "/api/events.mux")
    }

    func reconfigure(port: Int) {
        queue.addOperation { [weak self] in
            guard let self else { return }
            self.port = port
            self.hostTask?.cancel(with: .goingAway, reason: nil)
            self.muxTask?.cancel(with: .goingAway, reason: nil)
            self.hostTask = nil
            self.muxTask = nil
            self.hostBackoff = 1
            self.muxBackoff = 1
            self.connect(kind: "host", path: "/api/events.host")
            self.connect(kind: "mux", path: "/api/events.mux")
        }
    }

    func stop() {
        closed = true
        queue.addOperation { [weak self] in
            self?.hostTask?.cancel(with: .goingAway, reason: nil)
            self?.muxTask?.cancel(with: .goingAway, reason: nil)
        }
    }

    private func connect(kind: String, path: String) {
        guard let url = URL(string: "ws://127.0.0.1:\(port)\(path)") else { return }
        let task = session.webSocketTask(with: url)
        if kind == "host" { hostTask = task } else { muxTask = task }
        task.resume()
        schedulePing(kind: kind, task: task)
        receiveLoop(kind: kind, task: task)
    }

    private func schedulePing(kind: String, task: URLSessionWebSocketTask) {
        queue.addOperation { [weak self, weak task] in
            Thread.sleep(forTimeInterval: 25)
            guard let self, !self.closed, let task else { return }
            task.sendPing { _ in }
            self.schedulePing(kind: kind, task: task)
        }
    }

    private func receiveLoop(kind: String, task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            guard let self, !self.closed, let task else { return }
            switch result {
            case .success(let message):
                if kind == "host" { self.hostBackoff = 1; self.hostConnected = true }
                else { self.muxBackoff = 1; self.muxConnected = true }
                switch message {
                case .string(let text):
                    self.handle(text: text, kind: kind)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handle(text: text, kind: kind)
                    }
                @unknown default:
                    break
                }
                self.receiveLoop(kind: kind, task: task)
            case .failure:
                // Connection dropped: exponential backoff reconnect.
                let delay: TimeInterval
                if kind == "host" {
                    self.hostConnected = false
                    self.hostBackoff = min(self.hostBackoff * 2, 30)
                    delay = self.hostBackoff
                } else {
                    self.muxConnected = false
                    self.muxBackoff = min(self.muxBackoff * 2, 30)
                    delay = self.muxBackoff
                }
                self.queue.addOperation { [weak self] in
                    guard let self, !self.closed else { return }
                    Thread.sleep(forTimeInterval: delay)
                    guard !self.closed else { return }
                    self.connect(kind: kind, path: kind == "host" ? "/api/events.host" : "/api/events.mux")
                }
            }
        }
    }

    private func handle(text: String, kind: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "server-request",
              let payload = json["payload"] as? [String: Any] else {
            return
        }
        let rpcId = json["rpcId"] as? String ?? ""
        DispatchQueue.main.async { [weak self] in
            self?.onFrame?(kind, rpcId, payload)
        }
    }
}

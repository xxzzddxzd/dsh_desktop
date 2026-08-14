import AppKit
import Foundation

/// User-facing preferences persisted in UserDefaults.
final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    private let kPort = "port"
    private let kAutoStart = "autoStartServer"
    private let kNotifications = "notificationsEnabled"
    private let kNotifyTurnDone = "notifyTurnDone"
    private let kNotifyWaiting = "notifyWaitingInput"
    private let kNotifyGoal = "notifyGoalEvents"
    private let kNotifyServer = "notifyServerEvents"
    private let kHotkey = "hotkeyEnabled"
    private let kLaunchAtLogin = "launchAtLogin"
    private let kServerBinary = "serverBinary"
    private let kWorkDir = "serverWorkDir"
    private let kWindowMode = "windowMode"
    private let kServiceMode = "serverServiceMode"
    private let kManageServer = "manageServer"
    private let kAlertPref = "completionAlertPreference"
    private let kAutoCheckUpdates = "autoCheckUpdates"
    private let kLastUpdateCheckAt = "lastUpdateCheckAt"

    var port: Int {
        get { let v = defaults.integer(forKey: kPort); return v == 0 ? 3080 : v }
        set { defaults.set(newValue, forKey: kPort) }
    }
    var autoStartServer: Bool {
        get { defaults.object(forKey: kAutoStart) as? Bool ?? true }
        set { defaults.set(newValue, forKey: kAutoStart) }
    }
    var notificationsEnabled: Bool {
        get { defaults.object(forKey: kNotifications) as? Bool ?? true }
        set { defaults.set(newValue, forKey: kNotifications) }
    }
    var notifyTurnDone: Bool {
        get { defaults.object(forKey: kNotifyTurnDone) as? Bool ?? true }
        set { defaults.set(newValue, forKey: kNotifyTurnDone) }
    }
    var notifyWaitingInput: Bool {
        get { defaults.object(forKey: kNotifyWaiting) as? Bool ?? true }
        set { defaults.set(newValue, forKey: kNotifyWaiting) }
    }
    var notifyGoalEvents: Bool {
        get { defaults.object(forKey: kNotifyGoal) as? Bool ?? true }
        set { defaults.set(newValue, forKey: kNotifyGoal) }
    }
    var notifyServerEvents: Bool {
        get { defaults.object(forKey: kNotifyServer) as? Bool ?? true }
        set { defaults.set(newValue, forKey: kNotifyServer) }
    }
    var hotkeyEnabled: Bool {
        get { defaults.object(forKey: kHotkey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: kHotkey) }
    }
    var launchAtLogin: Bool {
        get { defaults.object(forKey: kLaunchAtLogin) as? Bool ?? false }
        set { defaults.set(newValue, forKey: kLaunchAtLogin) }
    }
    var serverBinary: String {
        get { defaults.string(forKey: kServerBinary) ?? defaultBinary() }
        set { defaults.set(newValue, forKey: kServerBinary) }
    }
    var serverWorkDir: String {
        get { defaults.string(forKey: kWorkDir) ?? NSHomeDirectory() }
        set { defaults.set(newValue, forKey: kWorkDir) }
    }
    var windowMode: Bool {
        get { defaults.bool(forKey: kWindowMode) }
        set { defaults.set(newValue, forKey: kWindowMode) }
    }
    /// Persisted popover size (drag the bottom-right grip to resize).
    var popoverSize: NSSize {
        get {
            let w = defaults.double(forKey: "popoverWidth")
            let h = defaults.double(forKey: "popoverHeight")
            if w > 100, h > 100 { return NSSize(width: w, height: h) }
            return NSSize(width: 1000, height: 720)
        }
        set {
            defaults.set(Double(newValue.width), forKey: "popoverWidth")
            defaults.set(Double(newValue.height), forKey: "popoverHeight")
        }
    }
    /// How completions alert the user: "bubble" | "notification" | "both".
    var alertPreference: String {
        get {
            let v = defaults.string(forKey: kAlertPref) ?? "bubble"
            return ["bubble", "notification", "both"].contains(v) ? v : "bubble"
        }
        set { defaults.set(newValue, forKey: kAlertPref) }
    }
    /// Whether bubble alerts are wanted under the current preference.
    var wantsBubble: Bool { alertPreference != "notification" }
    /// Whether notification alerts are wanted under the current preference.
    var wantsNotification: Bool { alertPreference != "bubble" }

    /// Run the server as a launchd LaunchAgent instead of an app child process.
    var serverServiceMode: Bool {
        get { defaults.bool(forKey: kServiceMode) }
        set { defaults.set(newValue, forKey: kServiceMode) }
    }
    /// Experimental: let the app own the dsh server lifecycle (spawn /
    /// watchdog / launchd). Off by default: the app only attaches to a dsh
    /// instance the user starts themselves and just verifies its status.
    var manageServer: Bool {
        get { defaults.object(forKey: kManageServer) as? Bool ?? false }
        set { defaults.set(newValue, forKey: kManageServer) }
    }
    /// Whether the app checks npm for newer dsh versions (once a day).
    var autoCheckUpdates: Bool {
        get { defaults.object(forKey: kAutoCheckUpdates) as? Bool ?? true }
        set { defaults.set(newValue, forKey: kAutoCheckUpdates) }
    }
    /// Unix time of the last automatic update check (throttles to 1/day).
    var lastUpdateCheckAt: TimeInterval {
        get { defaults.double(forKey: kLastUpdateCheckAt) }
        set { defaults.set(newValue, forKey: kLastUpdateCheckAt) }
    }
    /// True when the user explicitly configured the dsh binary path.
    var hasCustomServerBinary: Bool {
        defaults.object(forKey: kServerBinary) != nil
    }
    /// Headless verification aid: dump computed status lines to the log.
    var debugDump: Bool {
        get { defaults.bool(forKey: "debugDump") }
        set { defaults.set(newValue, forKey: "debugDump") }
    }
    /// Headless verification aid: auto-open the popover at launch.
    var debugAutoOpen: Bool {
        get { defaults.bool(forKey: "debugAutoOpen") }
        set { defaults.set(newValue, forKey: "debugAutoOpen") }
    }
    /// Headless verification aid: jump to this session id at launch.
    var debugSelectId: String {
        get { defaults.string(forKey: "debugSelectId") ?? "" }
        set { defaults.set(newValue, forKey: "debugSelectId") }
    }
    /// Headless verification aid: select this session title at launch.
    var debugSelectTitle: String {
        get { defaults.string(forKey: "debugSelectTitle") ?? "" }
        set { defaults.set(newValue, forKey: "debugSelectTitle") }
    }
    /// Headless verification aid: dump DOM structure around a title/id.
    var debugProbeId: String {
        get { defaults.string(forKey: "debugProbeId") ?? "" }
        set { defaults.set(newValue, forKey: "debugProbeId") }
    }
    /// Headless verification aid: needle for the DOM probe (optional).
    var debugProbeTitle: String {
        get { defaults.string(forKey: "debugProbeTitle") ?? "" }
        set { defaults.set(newValue, forKey: "debugProbeTitle") }
    }
    /// Headless verification aid: pre-click action for the probe ("crumb").
    var debugProbeClick: String {
        get { defaults.string(forKey: "debugProbeClick") ?? "" }
        set { defaults.set(newValue, forKey: "debugProbeClick") }
    }
    /// Live demo aid: show a sample bubble ("complete" | "approval" | "blocked" | "goal").
    var debugBubble: String {
        get { defaults.string(forKey: "debugBubble") ?? "" }
        set { defaults.set(newValue, forKey: "debugBubble") }
    }

    /// Best-effort discovery of the `dsh` launcher.
    func defaultBinary() -> String {
        let candidates = [
            "/opt/homebrew/bin/dsh",
            "/usr/local/bin/dsh",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        // Last resort: the global npm checkout's bin script run through node.
        let npmLib = "/opt/homebrew/lib/node_modules/@deepseek-ai/dsh/lib/bin.js"
        if FileManager.default.fileExists(atPath: npmLib) {
            return npmLib
        }
        return "/opt/homebrew/bin/dsh"
    }
}

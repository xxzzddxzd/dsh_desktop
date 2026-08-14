import Foundation

/// Rolling in-memory log + persistent log file (~/Library/Logs/DSHDesktop/server.log).
final class LogStore {
    static let shared = LogStore()

    private let lock = NSLock()
    private var buffer: [String] = []
    private let capacity = 800
    private var fileHandle: FileHandle?
    private let dateFormatter: DateFormatter
    /// Called on the main thread with each new line.
    var onChange: ((String) -> Void)?

    private init() {
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss"
        openFile()
    }

    private func openFile() {
        let fm = FileManager.default
        let dir = NSHomeDirectory() + "/Library/Logs/DSHDesktop"
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/server.log"
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil)
        }
        fileHandle = FileHandle(forWritingAtPath: path)
        fileHandle?.seekToEndOfFile()
    }

    func append(_ text: String, source: String = "dsh") {
        let now = dateFormatter.string(from: Date())
        let lines = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        lock.lock()
        var added: [String] = []
        for line in lines {
            let stamped = "[\(now)] [\(source)] \(line)"
            buffer.append(stamped)
            added.append(stamped)
            if let data = (stamped + "\n").data(using: .utf8) {
                fileHandle?.write(data)
            }
        }
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
        lock.unlock()
        for line in added {
            DispatchQueue.main.async { [weak self] in
                self?.onChange?(line)
            }
        }
    }

    func allLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func clear() {
        lock.lock()
        buffer.removeAll()
        lock.unlock()
    }
}

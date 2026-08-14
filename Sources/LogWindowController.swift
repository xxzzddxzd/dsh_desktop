import AppKit

/// Small floating window that tails the server log live.
final class LogWindowController: NSObject {
    private var window: NSWindow?
    private let textView = NSTextView()
    private var observing = false

    func toggle() {
        if let window, window.isVisible {
            window.orderOut(nil)
            return
        }
        show()
    }

    func show() {
        if window == nil {
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 420))

            let scroll = NSScrollView(frame: content.bounds)
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true
            scroll.borderType = .noBorder

            textView.isEditable = false
            textView.isRichText = false
            textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            textView.textContainerInset = NSSize(width: 8, height: 8)
            textView.autoresizingMask = [.width]
            textView.isVerticallyResizable = true
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.minSize = NSSize(width: 0, height: 0)
            scroll.documentView = textView
            content.addSubview(scroll)

            let clearButton = NSButton(title: "清空", target: self, action: #selector(clear))
            clearButton.bezelStyle = .rounded
            clearButton.controlSize = .small
            clearButton.frame = NSRect(x: content.bounds.width - 86, y: 8, width: 70, height: 24)
            clearButton.autoresizingMask = [.minXMargin, .maxYMargin]
            content.addSubview(clearButton)

            let w = NSWindow(contentRect: content.bounds,
                             styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "DSH 服务日志"
            w.contentView = content
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("DSHDesktopLogWindow")
            window = w
        }

        reload()
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        if !observing {
            observing = true
            LogStore.shared.onChange = { [weak self] line in
                self?.appendLine(line)
            }
        }
    }

    private func reload() {
        let all = LogStore.shared.allLines()
        textView.string = all.joined(separator: "\n")
        scrollToEnd()
    }

    private func appendLine(_ line: String) {
        guard window?.isVisible == true else { return }
        if textView.string.isEmpty {
            textView.string = line
        } else {
            textView.string += "\n" + line
        }
        scrollToEnd()
    }

    private func scrollToEnd() {
        let end = textView.string.count
        textView.scrollRangeToVisible(NSRange(location: max(0, end - 1), length: 1))
    }

    @objc private func clear() {
        LogStore.shared.clear()
        textView.string = ""
    }
}

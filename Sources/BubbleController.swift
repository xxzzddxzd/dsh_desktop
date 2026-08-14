import AppKit

/// Transient status bubble: a borderless, non-activating panel that pops up
/// under the menu bar item, auto-dismisses after ~5s, and opens the panel
/// when clicked.
final class BubbleController {
    static let shared = BubbleController()

    private var panel: NSPanel?
    private var hideTimer: Timer?
    private var clickHandler: (() -> Void)?
    private(set) var activeTag: String = ""

    func show(title: String,
              body: String,
              anchor: NSStatusBarButton?,
              ttl: TimeInterval = 5,
              buttons: [(title: String, action: () -> Void)] = [],
              tag: String = "",
              onClick: (() -> Void)?) {
        clickHandler = onClick
        activeTag = tag
        let content = buildContent(title: title, body: body, buttons: buttons)
        let size = content.fittingSize
        let contentSize = NSSize(width: min(max(size.width + 36, 220), 380), height: size.height + 24)

        let panel = makePanel(size: contentSize)
        self.panel = panel

        content.frame = NSRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height)
        panel.contentView = content

        // Position below the status item (or top-right fallback).
        var origin = NSPoint.zero
        if let anchor, let anchorWindow = anchor.window {
            let screenFrame = anchorWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            origin.x = screenFrame.midX - contentSize.width / 2
            origin.y = screenFrame.minY - contentSize.height - 8
        } else if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            origin.x = vf.maxX - contentSize.width - 20
            origin.y = vf.maxY - contentSize.height - 8
        }
        // Clamp into the main screen.
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - contentSize.width - 8)
            origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - contentSize.height - 8)
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: ttl, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
        if let hideTimer { RunLoop.main.add(hideTimer, forMode: .common) }
    }

    func dismiss() {
        hideTimer?.invalidate()
        hideTimer = nil
        activeTag = ""
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    /// Dismiss only when the bubble still carries this tag.
    func dismiss(tag: String) {
        guard !tag.isEmpty, tag == activeTag else { return }
        dismiss()
    }

    // MARK: - Construction

    private func makePanel(size: NSSize) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    private func buildContent(title: String, body: String,
                              buttons: [(title: String, action: () -> Void)]) -> NSView {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.97).cgColor
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.separatorColor.cgColor

        // Full-surface click backdrop (opens the panel); action buttons sit
        // above it and receive their own clicks.
        let backdrop = NSButton(title: "", target: self, action: #selector(bubbleClicked))
        backdrop.isBordered = false
        backdrop.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let bodyLabel = NSTextField(wrappingLabelWithString: body)
        bodyLabel.font = .systemFont(ofSize: 11.5)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.preferredMaxLayoutWidth = 330

        root.addSubview(backdrop)
        root.addSubview(titleLabel)
        root.addSubview(bodyLabel)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: root.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -14),
            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            bodyLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            bodyLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
        ])

        if buttons.isEmpty {
            bodyLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10).isActive = true
        } else {
            var previous: NSButton?
            for (index, button) in buttons.enumerated() {
                let b = NSButton(title: button.title, target: self, action: #selector(actionButtonClicked(_:)))
                b.bezelStyle = .rounded
                b.controlSize = .small
                b.tag = index
                b.translatesAutoresizingMaskIntoConstraints = false
                root.addSubview(b)
                NSLayoutConstraint.activate([
                    b.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 8),
                    b.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
                ])
                if let previous {
                    b.leadingAnchor.constraint(equalTo: previous.trailingAnchor, constant: 8).isActive = true
                } else {
                    b.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14).isActive = true
                }
                b.widthAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
                previous = b
            }
            previous?.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -14).isActive = true
        }

        buttonActions = buttons.map { $0.action }
        return root
    }

    private var buttonActions: [() -> Void] = []

    @objc private func actionButtonClicked(_ sender: NSButton) {
        let action = sender.tag < buttonActions.count ? buttonActions[sender.tag] : nil
        dismiss()
        action?()
    }

    @objc private func bubbleClicked() {
        let handler = clickHandler
        dismiss()
        handler?()
    }
}

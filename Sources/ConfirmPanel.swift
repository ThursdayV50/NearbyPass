// ConfirmPanel.swift — F1 的确认浮窗（屏幕居中）
//
// 设计要点：
// 1. 必须由用户点「允许」才会填密码 —— 不自动执行。超时默认**取消**（安全侧倒向）。
// 2. 面板必须能成为 key window，否则 macOS 的「第一次点击只激活窗口、不触发控件」
//    会让「允许」按钮永远点不动（实测过：windowNumber 有值、isVisible=true，
//    但 CGEventPost 点击后没有任何回调）。
// 3. 抢焦点是安全的：填写走 AX 直接写值 + AXPress 按钮，不依赖键盘焦点。
// 4. 内存：图标用 SF Symbol（系统共享缓存），信号条自绘，不用 emoji（emoji 会让
//    CoreText 把 ~180MB 的 Apple Color Emoji 字体私有化进本进程）。
import AppKit

/// 第一次点击就能命中，不需要先激活窗口。
final class ClickThroughButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 5 格信号条，按 dBm 点亮。轻量自绘，不建 layer。
final class SignalBars: NSView {
    var dbm: Int = -60 { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let slots = 5
        let t = (Double(dbm) + 95.0) / 55.0          // -95…-40 → 0…1
        let lit = max(0, min(slots, Int((t * Double(slots)).rounded())))
        let barW: CGFloat = 3
        let gap: CGFloat = 2
        let h = bounds.height
        let color: NSColor = lit >= 4 ? .systemGreen : (lit >= 2 ? .systemYellow : .systemOrange)
        color.withAlphaComponent(0.95).setFill()
        for i in 0..<slots {
            let bh = h * (0.40 + 0.15 * CGFloat(i))
            let r = NSRect(x: CGFloat(i) * (barW + gap), y: h - bh, width: barW, height: bh)
            NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 23, height: 12) }
}

final class ConfirmPanel {

    static let shared = ConfirmPanel()

    private var panel: NSPanel?
    private var countdown: Timer?
    private var remaining = 0
    private var onAllow: (() -> Void)?
    private var finished = false
    private var countLabel: NSTextField?
    private var statusLabel: NSTextField?
    private var watch: Timer?
    private var submitted = false
    private var targetWindow = 0
    private var sessionID = 0
    private var allowButton: NSButton?
    private var cancelButton: NSButton?

    private init() {}

    /// 显示确认浮窗。用户点「允许」才执行 onAllow；
    /// 点「取消」或倒计时结束则放弃（默认 seconds=20 秒后自动取消）。
    func show(
        device: String,
        rssi: Int,
        seconds: Int = 20,
        anchor: CGRect? = nil,
        windowNumber: Int = 0,
        onAllow: @escaping () -> Void
    ) {
        sessionID += 1
        let currentSession = sessionID
        close()
        finished = false
        submitted = false
        targetWindow = windowNumber
        self.onAllow = onAllow
        self.remaining = max(3, seconds)

        let w: CGFloat = 400, h: CGFloat = 198
        let screen = NSScreen.main?.frame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // 水平居中；垂直放在屏幕中央偏下。
        // 系统认证弹窗占据正中央且由 WindowServer 特殊保护（NSWindow.Level 提到 1500
        // 也压不过它），浮窗放在正中间会被完全遮住、按钮点不到。
        // 水平居中；垂直贴着系统认证弹窗的正下方（都能落在屏幕中央区域）。
        // 系统认证弹窗由 WindowServer 特殊保护：NSWindow.Level 提到 1500 也压不过它，
        // 所以不能叠在它上面，只能让开。
        var oy = screen.minY + (screen.height - h) * 0.30
        if let a = anchor, a.height > 1, a.width > 1,
           a.height < screen.height, a.width < screen.width {
            let bottomInAppKit = screen.maxY - a.maxY          // 弹窗底边（AppKit 坐标）
            let below = bottomInAppKit - 16 - h
            let above = bottomInAppKit + a.height + 16
            oy = (below >= screen.minY + 32) ? below : min(screen.maxY - h - 32, above)
        }
        let origin = NSPoint(x: screen.midX - w / 2, y: oy)

        let p = KeyablePanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: w, height: h)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // 系统认证弹窗在 layer 1000，浮窗必须更高才能居中显示且可点。
        p.level = NSWindow.Level(rawValue: 1500)
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.animationBehavior = .utilityWindow

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 20
        bg.layer?.cornerCurve = .continuous
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor

        // ── 图标（SF Symbol，系统共享缓存）
        let iconSize: CGFloat = 44
        let iconBox = NSView(frame: NSRect(x: 24, y: h - 24 - iconSize, width: iconSize, height: iconSize))
        iconBox.wantsLayer = true
        iconBox.layer?.cornerRadius = 11
        iconBox.layer?.cornerCurve = .continuous
        iconBox.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor

        if let sym = NSImage(systemSymbolName: "dot.radiowaves.left.and.right",
                             accessibilityDescription: "蓝牙") {
            let cfg = NSImage.SymbolConfiguration(pointSize: 21, weight: .medium)
            let img = sym.withSymbolConfiguration(cfg) ?? sym
            let iv = NSImageView(frame: NSRect(x: 0, y: 0, width: iconSize, height: iconSize))
            iv.image = img
            iv.contentTintColor = .controlAccentColor
            iv.imageScaling = .scaleProportionallyDown
            iv.imageAlignment = .alignCenter
            iconBox.addSubview(iv)
        }

        // ── 标题
        let titleX = 24 + iconSize + 14
        let titleW = w - titleX - 24
        let title = NSTextField(labelWithString: "设备在附近，要填密码吗？")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: titleX, y: h - 24 - 22, width: titleW, height: 22)

        let hint = NSTextField(labelWithString: "为这次系统授权自动填入登录密码")
        hint.font = .systemFont(ofSize: 11.5, weight: .regular)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.frame = NSRect(x: titleX, y: h - 24 - 42, width: titleW, height: 16)

        // ── 设备行（名字 + 信号条 + dBm）
        let devY: CGFloat = 74
        let dev = NSTextField(labelWithString: device)
        dev.font = .systemFont(ofSize: 12.5, weight: .medium)
        dev.textColor = .labelColor
        dev.lineBreakMode = .byTruncatingTail
        dev.frame = NSRect(x: 24, y: devY, width: w - 24 - 130, height: 17)

        let dBm = NSTextField(labelWithString: "\(rssi) dBm")
        dBm.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        dBm.textColor = .secondaryLabelColor
        dBm.alignment = .right
        dBm.frame = NSRect(x: w - 24 - 66, y: devY, width: 66, height: 16)

        let bars = SignalBars(frame: NSRect(x: w - 24 - 66 - 8 - 23, y: devY + 2, width: 23, height: 12))
        bars.dbm = rssi

        // ── 分隔线
        let sep = NSBox(frame: NSRect(x: 24, y: 60, width: w - 48, height: 1))
        sep.boxType = .separator
        sep.titlePosition = .noTitle

        // ── 倒计时
        let count = NSTextField(labelWithString: "")
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = .tertiaryLabelColor
        count.frame = NSRect(x: 24, y: 22, width: 220, height: 16)
        countLabel = count

        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11, weight: .medium)
        status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 200, y: 22, width: w - 224, height: 16)
        status.alignment = .right
        statusLabel = status

        // ── 按钮（主按钮在右，符合 macOS 习惯）
        let allowW: CGFloat = 92, btnH: CGFloat = 32
        let allow = ClickThroughButton(title: "允许", target: self, action: #selector(allowTapped))
        allow.bezelStyle = .rounded
        allow.keyEquivalent = "\r"
        allow.font = .systemFont(ofSize: 13, weight: .medium)
        allow.contentTintColor = .controlAccentColor
        allow.frame = NSRect(x: w - 24 - allowW, y: 15, width: allowW, height: btnH)
        self.allowButton = allow

        let cancelW: CGFloat = 72
        let cancel = ClickThroughButton(title: "取消", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        cancel.font = .systemFont(ofSize: 13, weight: .regular)
        cancel.frame = NSRect(x: w - 24 - allowW - 8 - cancelW, y: 15, width: cancelW, height: btnH)
        self.cancelButton = cancel

        bg.addSubview(iconBox)
        bg.addSubview(title)
        bg.addSubview(hint)
        bg.addSubview(dev)
        bg.addSubview(bars)
        bg.addSubview(dBm)
        bg.addSubview(sep)
        bg.addSubview(count)
        bg.addSubview(status)
        bg.addSubview(cancel)
        bg.addSubview(allow)
        p.contentView = bg

        NSApp.activate(ignoringOtherApps: true)
        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            p.animator().alphaValue = 1
        }
        panel = p

        updateLabel()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        countdown = t

        // 监视目标弹窗：它先一步消失说明用户自己完成/取消了
        let w2 = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.checkTarget()
        }
        RunLoop.main.add(w2, forMode: .common)
        watch = w2

        // 兜底：任何情况下浮窗都不该无限留在屏幕上
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
            guard let self, self.sessionID == currentSession, !self.finished else { return }
            Log.info("确认浮窗超时兜底关闭")
            self.finished = true
            self.close()
        }

        // 打印「允许」按钮的真实屏幕坐标（左上原点），供自动化点击校验
        let btnRect = allow.convert(allow.bounds, to: nil)
        let btnScreen = p.convertPoint(toScreen: NSPoint(x: btnRect.midX, y: btnRect.midY))
        let sy = (p.screen?.frame.maxY ?? 1050) - btnScreen.y
        Log.info("「允许」按钮屏幕坐标 ≈ (\(Int(btnScreen.x)), \(Int(sy)))")
        Log.info("确认浮窗已弹出（居中）num=\(p.windowNumber) frame=\(Int(p.frame.minX)),\(Int(p.frame.minY)) \(Int(w))x\(Int(h))")
    }

    private func updateLabel() {
        countLabel?.stringValue = "\(remaining) 秒后自动取消"
    }

    private func tick() {
        remaining -= 1
        if remaining > 0 {
            updateLabel()
            return
        }
        guard !finished else { return }
        finished = true
        close()
        Log.info("确认浮窗超时，未填写")
    }

    @objc private func allowTapped() {
        guard !finished, !submitted else { return }
        submitted = true
        allowButton?.isHidden = true
        cancelButton?.isHidden = true
        countdown?.invalidate()
        countdown = nil
        countLabel?.stringValue = ""
        statusLabel?.stringValue = "正在填写…"
        Log.info("用户点击「允许」，开始填写")
        onAllow?()
    }

    /// 供外部更新状态行
    func updateStatus(_ text: String) {
        let currentSession = sessionID
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sessionID == currentSession else { return }
            self.statusLabel?.stringValue = text
        }
    }

    /// 完成收尾：延时关闭，给用户看一眼状态
    func finish(after delay: TimeInterval = 1.0) {
        let currentSession = sessionID
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.sessionID == currentSession else { return }
            self.finished = true
            self.close()
        }
    }

    private func checkTarget() {
        guard targetWindow > 0, !finished else { return }
        let stillThere = Self.windowExists(targetWindow)
        if !stillThere {
            watch?.invalidate()
            watch = nil
            if submitted {
                // 我们自己提交过，按正常验证流程走
                return
            }
            countdown?.invalidate()
            countdown = nil
            countLabel?.stringValue = ""
            statusLabel?.stringValue = "你已完成，未做操作"
            Log.info("目标弹窗已消失（用户手动完成），浮窗自动关闭")
            finish(after: 0.9)
        }
    }

    private static func windowExists(_ number: Int) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        for w in list {
            if let n = w[kCGWindowNumber as String] as? Int, n == number { return true }
        }
        return false
    }

    @objc private func cancelTapped() {
        guard !finished else { return }
        finished = true
        close()
        Log.info("用户点击「取消」，不填写")
    }

    func close() {
        countdown?.invalidate()
        countdown = nil
        watch?.invalidate()
        watch = nil
        allowButton = nil
        cancelButton = nil
        statusLabel = nil
        panel?.orderOut(nil)
        panel = nil
        countLabel = nil
    }
}

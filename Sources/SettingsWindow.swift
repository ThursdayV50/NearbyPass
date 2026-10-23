// SettingsWindow.swift — 设置界面（AppKit 手写）
//
// 用户明确要求的三件事都在这里：
//   1. 实时显示每个蓝牙设备当前的信号强度
//   2. 直接勾选哪些设备算"人在"
//   3. 分别设置「解锁强度」和「锁屏强度」两个阈值
//
// 视觉：卡片式分组、统一圆角、克制的层级与留白。
import AppKit
import Darwin

// MARK: - 主题

private enum T {
    static let W: CGFloat = 740
    static let H: CGFloat = 926
    static let pad: CGFloat = 20        // 窗口左右边距
    static let cardPad: CGFloat = 16    // 卡片内边距
    static let cardW: CGFloat = W - pad * 2
    static let innerW: CGFloat = cardW - cardPad * 2

    static let cardRadius: CGFloat = 12

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
    static func cardFill(_ appearance: NSAppearance) -> NSColor {
        isDark(appearance)
            ? NSColor(white: 1.0, alpha: 0.055)
            : NSColor(white: 1.0, alpha: 0.50)
    }
    static func cardStroke(_ appearance: NSAppearance) -> NSColor {
        isDark(appearance)
            ? NSColor(white: 1.0, alpha: 0.10)
            : NSColor(white: 0.0, alpha: 0.07)
    }
    /// 卡片顶部那道高光，模拟玻璃厚度
    static func cardHighlight(_ appearance: NSAppearance) -> NSColor {
        isDark(appearance)
            ? NSColor(white: 1.0, alpha: 0.10)
            : NSColor(white: 1.0, alpha: 0.80)
    }
}

// MARK: - 玻璃背景（液态玻璃底）

/// 窗口级的一层磨砂玻璃。卡片不再各自做模糊，
/// 只在玻璃之上叠半透明色块 —— 既像液态玻璃，又不会拖垮性能。
final class GlassBackground: NSVisualEffectView {
    static let corner: CGFloat = 20

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .underWindowBackground
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = Self.corner
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = NSBezierPath(roundedRect: r, xRadius: Self.corner, yRadius: Self.corner)

        // 极淡的一层压色，保证玻璃背后再花也不影响文字可读性
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (dark ? NSColor(white: 0.06, alpha: 0.34) : NSColor(white: 1.0, alpha: 0.30)).setFill()
        p.fill()

        // 玻璃边缘的立体感
        NSColor(white: 1, alpha: 0.14).setStroke()
        p.lineWidth = 1
        p.stroke()
    }
}

// MARK: - 卡片容器

final class CardView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = NSBezierPath(roundedRect: r, xRadius: T.cardRadius, yRadius: T.cardRadius)
        T.cardFill(effectiveAppearance).setFill()
        p.fill()

        // 顶部高光：玻璃受光的边缘
        let hi = NSBezierPath()
        hi.move(to: NSPoint(x: r.minX + T.cardRadius, y: r.minY + 0.5))
        hi.line(to: NSPoint(x: r.maxX - T.cardRadius, y: r.minY + 0.5))
        T.cardHighlight(effectiveAppearance).setStroke()
        hi.lineWidth = 1
        hi.stroke()

        T.cardStroke(effectiveAppearance).setStroke()
        p.lineWidth = 1
        p.stroke()
    }
}

// MARK: - 状态胶囊

final class PillView: NSView {
    private let label = NSTextField(labelWithString: "")
    var tint: NSColor = .secondaryLabelColor { didSet { apply() } }

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue; resize(); needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.alignment = .center
        addSubview(label)
        apply()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        label.textColor = tint
        needsDisplay = true
    }

    func resize() {
        let w = label.intrinsicContentSize.width + 22
        setFrameSize(NSSize(width: max(w, 60), height: 24))
        label.frame = NSRect(x: 0, y: 3, width: bounds.width, height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        tint.withAlphaComponent(0.14).setFill()
        p.fill()
        tint.withAlphaComponent(0.3).setStroke()
        p.lineWidth = 1
        p.stroke()
    }
}

// MARK: - 信号格

final class SignalBarsView: NSView {
    var level: Int = 0 { didSet { if level != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        let bars = 5
        let gap: CGFloat = 2
        let w = (bounds.width - gap * CGFloat(bars - 1)) / CGFloat(bars)
        for i in 0..<bars {
            let h = bounds.height * (0.32 + 0.68 * CGFloat(i) / CGFloat(bars - 1))
            let r = NSRect(x: CGFloat(i) * (w + gap), y: bounds.height - h, width: w, height: h)
            let on = i < level
            let color: NSColor = on
                ? (level >= 4 ? .systemGreen : level >= 3 ? .systemYellow : .systemOrange)
                : NSColor.quaternaryLabelColor
            color.setFill()
            NSBezierPath(roundedRect: r, xRadius: w / 2, yRadius: w / 2).fill()
        }
    }

    /// RSSI(dBm) → 0..5 格
    static func level(for rssi: Int?) -> Int {
        guard let r = rssi else { return 0 }
        switch r {
        case (-45)...:      return 5
        case -55 ..< -45:   return 4
        case -65 ..< -55:   return 3
        case -75 ..< -65:   return 2
        case -85 ..< -75:   return 1
        default:            return 0
        }
    }
}

// MARK: - 历史曲线

final class HistoryGraphView: NSView {
    var values: [Int?] = [] { didSet { updateBarLayers() } }
    var unlockThreshold: Int = -60 { didSet { updateBarLayers() } }
    var lockThreshold: Int = -85 { didSet { updateBarLayers() } }

    private let dbmTop = -30
    private let dbmBottom = -100
    private var barLayers: [CALayer] = []

    /// 柱子用 60 个 CALayer 画（GPU 合成），不用 CoreGraphics 逐根填充。
    func prepareBarLayers() {
        guard barLayers.isEmpty else { return }
        wantsLayer = true
        for _ in 0..<60 {
            let l = CALayer()
            l.isHidden = true
            l.cornerRadius = 2
            layer?.addSublayer(l)
            barLayers.append(l)
        }
        updateBarLayers()
    }

    private func yPos(for dbm: Double) -> CGFloat {
        let t = (dbm - Double(dbmBottom)) / Double(dbmTop - dbmBottom)
        return 8 + CGFloat(max(0, min(1, t))) * (bounds.height - 16)
    }

    private func updateBarLayers() {
        guard !barLayers.isEmpty, bounds.width > 0 else { return }
        let slot = bounds.width / CGFloat(barLayers.count)
        let barW = max(1.5, slot - 1.0)
        let base = yPos(for: Double(dbmBottom))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in 0..<barLayers.count {
            let l = barLayers[i]
            guard i < values.count, let dbm = values[i] else {
                l.isHidden = true
                continue
            }
            let x = CGFloat(i) * slot + (slot - barW) / 2
            let top = yPos(for: Double(dbm))
            l.isHidden = false
            l.frame = CGRect(x: x, y: min(top, base),
                             width: barW, height: max(1.5, abs(top - base)))
            let c: NSColor = Double(dbm) >= Double(unlockThreshold)
                ? .systemGreen
                : (Double(dbm) <= Double(lockThreshold) ? .systemRed : .systemYellow)
            l.backgroundColor = c.withAlphaComponent(0.85).cgColor
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        updateBarLayers()
    }

    override func draw(_ dirtyRect: NSRect) {
        // 背景
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        NSColor.textBackgroundColor.withAlphaComponent(0.35).setFill()
        bg.fill()

        func y(for dbm: Double) -> CGFloat { yPos(for: dbm) }

        // 横向网格
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        for v in stride(from: -100.0, through: -30.0, by: 10.0) {
            let yy = y(for: v)
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 0, y: yy))
            p.line(to: NSPoint(x: bounds.width, y: yy))
            p.lineWidth = 1
            p.stroke()
        }

        // 阈值参考线
        let thresholdLines: [(Int, NSColor)] = [
            (unlockThreshold, .systemGreen),
            (lockThreshold, .systemRed)
        ]
        for (dbm, color) in thresholdLines {
            let yy = y(for: Double(dbm))
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 0, y: yy))
            p.line(to: NSPoint(x: bounds.width, y: yy))
            p.lineWidth = 1
            p.setLineDash([3, 3], count: 2, phase: 0)
            color.withAlphaComponent(0.6).setStroke()
            p.stroke()
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]

        guard !values.isEmpty else {
            let hint = "等待蓝牙数据…" as NSString
            hint.draw(at: NSPoint(x: bounds.midX - 42, y: bounds.midY - 7), withAttributes: attrs)
            return
        }

        // 右侧刻度
        ("\(dbmTop)" as NSString).draw(
            at: NSPoint(x: bounds.width - 26, y: bounds.height - 14), withAttributes: attrs)
        ("\(dbmBottom)" as NSString).draw(
            at: NSPoint(x: bounds.width - 32, y: 3), withAttributes: attrs)
    }
}

// MARK: - 可双击的标签

final class ClickNameField: NSTextField {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            super.mouseDown(with: event)
        }
    }
}

// MARK: - 设备行

final class DeviceRowView: NSView {

    let deviceID: String
    var onToggleTrust: ((Bool) -> Void)?
    var onSetPrimary: (() -> Void)?
    var onRename: (() -> Void)?

    private let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let star = NSButton(title: "☆", target: nil, action: nil)
    private let nameLabel = ClickNameField(labelWithString: "")
    private let rssiLabel = NSTextField(labelWithString: "")
    private let bars = SignalBarsView()
    private let ageLabel = NSTextField(labelWithString: "")
    private let editButton = NSButton(title: "改", target: nil, action: nil)

    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    init(deviceID: String) {
        self.deviceID = deviceID
        super.init(frame: .zero)

        check.target = self
        check.action = #selector(toggleTrust)

        star.target = self
        star.action = #selector(setPrimary)
        star.isBordered = false
        star.font = .systemFont(ofSize: 14)
        star.toolTip = "设为「解锁主设备」——只有它能触发自动解锁"

        nameLabel.font = .systemFont(ofSize: 12.5)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.onDoubleClick = { [weak self] in self?.onRename?() }

        rssiLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        rssiLabel.alignment = .right

        ageLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        ageLabel.textColor = .tertiaryLabelColor
        ageLabel.alignment = .right

        editButton.target = self
        editButton.action = #selector(renameTapped)
        editButton.isBordered = false
        editButton.font = .systemFont(ofSize: 11)
        editButton.contentTintColor = .secondaryLabelColor
        editButton.toolTip = "给这个设备起个名字"
        editButton.alphaValue = 0.22

        addSubview(check)
        addSubview(editButton)
        addSubview(star)
        addSubview(nameLabel)
        addSubview(rssiLabel)
        addSubview(bars)
        addSubview(ageLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking, t.rect.equalTo(bounds) { return }
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        editButton.alphaValue = 1.0
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        editButton.alphaValue = 0.22
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            let p = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 6, yRadius: 6)
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            p.fill()
        }
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        check.frame = NSRect(x: 4, y: (bounds.height - 18) / 2, width: 18, height: 18)
        star.frame = NSRect(x: 26, y: (bounds.height - 20) / 2, width: 22, height: 20)
        ageLabel.frame = NSRect(x: w - 74, y: (bounds.height - 16) / 2, width: 64, height: 16)
        bars.frame = NSRect(x: w - 164, y: (bounds.height - 12) / 2, width: 44, height: 12)
        rssiLabel.frame = NSRect(x: w - 240, y: (bounds.height - 18) / 2, width: 70, height: 18)
        editButton.frame = NSRect(x: w - 268, y: (bounds.height - 18) / 2, width: 18, height: 18)
        nameLabel.frame = NSRect(
            x: 50, y: (bounds.height - 18) / 2, width: max(60, w - 326), height: 18)
    }

    func update(
        name: String, rssi: Int?, age: TimeInterval?,
        trusted: Bool, primary: Bool, stale: Bool = false,
        pending: Bool = false, unknownName: Bool = false
    ) {
        if pending {
            setText(nameLabel, name + "  · 识别名字中…")
            nameLabel.textColor = .secondaryLabelColor
            editButton.isHidden = true
        } else {
            setText(nameLabel, name)
            nameLabel.textColor = unknownName ? .tertiaryLabelColor : .labelColor
            editButton.isHidden = false
            editButton.alphaValue = hovered ? 1.0 : (unknownName ? 0.8 : 0.22)
        }

        if check.state != (trusted ? .on : .off) { check.state = trusted ? .on : .off }
        star.title = primary ? "★" : "☆"
        star.contentTintColor = primary ? .systemYellow : .tertiaryLabelColor

        if let r = rssi {
            setText(rssiLabel, stale ? "\(r) dBm ·" : "\(r) dBm")
            rssiLabel.textColor = stale
                ? .tertiaryLabelColor
                : (r >= Settings.shared.unlockThreshold
                    ? .systemGreen
                    : (r <= Settings.shared.lockThreshold ? .systemRed : .labelColor))
        } else if age != nil {
            // 超过 60 秒没收到广播：明确显示"未在附近"，不再挂一个旧数值
            setText(rssiLabel, "未在附近")
            rssiLabel.textColor = .tertiaryLabelColor
        } else {
            setText(rssiLabel, "—")
            rssiLabel.textColor = .tertiaryLabelColor
        }
        bars.level = SignalBarsView.level(for: rssi)

        if let a = age {
            setText(ageLabel, a < 1 ? "刚刚" : "\(Int(a))s 前")
        } else {
            setText(ageLabel, "")
        }
    }

    /// 只在内容变化时才写，避免每秒生成一堆临时字符串
    private func setText(_ field: NSTextField, _ value: String) {
        if field.stringValue != value { field.stringValue = value }
    }

    @objc private func toggleTrust() {
        onToggleTrust?(check.state == .on)
    }

    @objc private func setPrimary() {
        onSetPrimary?()
    }

    @objc private func renameTapped() {
        onRename?()
    }
}

// MARK: - 翻转坐标的容器（让子视图从顶部开始排列）

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - 设置窗口


final class SettingsWindow: NSObject, NSWindowDelegate {

    static let shared = SettingsWindow()

    private var window: NSWindow?
    private var refreshTimer: Timer?
    private var tickCount = 0

    private let graph = HistoryGraphView()
    private let deviceScroll = NSScrollView()
    private let deviceContainer = FlippedView()
    private var rows: [String: DeviceRowView] = [:]
    private let emptyHint = NSTextField(labelWithString: "")
    private let trustedCount = NSTextField(labelWithString: "")

    private let pill = PillView()
    private let unlockSlider = NSSlider()
    private let lockSlider = NSSlider()
    private let unlockValue = NSTextField(labelWithString: "")
    private let lockValue = NSTextField(labelWithString: "")
    private let prediction = NSTextField(labelWithString: "")

    private let authFillCheck = NSButton(checkboxWithTitle: "授权弹窗自动填密码", target: nil, action: nil)
    private let autoUnlockCheck = NSButton(checkboxWithTitle: "锁屏自动解锁", target: nil, action: nil)
    private let autoLockCheck = NSButton(checkboxWithTitle: "远离自动锁屏", target: nil, action: nil)
    private let cooldownSlider = NSSlider()
    private let cooldownValue = NSTextField(labelWithString: "")
    private let delaySlider = NSSlider()
    private let delayValue = NSTextField(labelWithString: "")

    private override init() { super.init() }

    // MARK: - 显示

    func show() {
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            w.orderFrontRegardless()
            startTimer()
            refresh()
            return
        }
        build()
    }

    func windowWillClose(_ notification: Notification) {
        // 窗口关掉就别再每秒刷新了
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func startTimer() {
        guard refreshTimer == nil else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, self.window?.isVisible == true else { return }
            self.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    private func build() {
        // 标题栏 30pt 让出来给红绿灯，内容整体下移，玻璃铺满整窗
        let topInset: CGFloat = 30
        let winH = T.H + topInset

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: T.W, height: winH),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = "NearbyPass 设置"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.backgroundColor = .clear
        w.isOpaque = false
        w.center()

        let outer = FlippedView(frame: NSRect(x: 0, y: 0, width: T.W, height: winH))
        let glass = GlassBackground(frame: outer.bounds)
        glass.autoresizingMask = [.width, .height]
        outer.addSubview(glass)

        // c 仍是内容层，坐标沿用原来那套（从顶部数）
        let c = FlippedView(frame: NSRect(x: 0, y: topInset, width: T.W, height: T.H))
        outer.addSubview(c)

        w.contentView = outer
        window = w

        // ── 头部
        let title = NSTextField(labelWithString: "NearbyPass")
        title.font = .systemFont(ofSize: 22, weight: .bold)
        title.frame = NSRect(x: T.pad, y: 16, width: 300, height: 28)
        c.addSubview(title)

        let sub = NSTextField(labelWithString: "蓝牙在场驱动的 自动解锁 / 自动锁屏 / 授权弹窗填密码")
        sub.font = .systemFont(ofSize: 11.5)
        sub.textColor = .secondaryLabelColor
        sub.frame = NSRect(x: T.pad, y: 46, width: 460, height: 16)
        c.addSubview(sub)

        c.addSubview(pill)
        pill.frame = NSRect(x: T.W - T.pad - 120, y: 18, width: 120, height: 24)

        // ── 卡片 1：信号曲线
        let card1 = makeCard(c, top: 74, height: 132)
        card1.addSubview(makeCardTitle("信号强度", top: 14))
        card1.addSubview(makeCardNote("最近 60 秒 · 取最强信任设备", top: 14))

        graph.frame = NSRect(
            x: T.cardPad, y: 40, width: T.innerW, height: 78)
        card1.addSubview(graph)
        graph.prepareBarLayers()

        // ── 卡片 2：设备列表
        let card2 = makeCard(c, top: 218, height: 278)
        card2.addSubview(makeCardTitle("设备", top: 14))
        card2.addSubview(
            makeCardNote("勾选 = 算作「人在」　★ = 解锁主设备　双击名字可重命名", top: 14))

        deviceScroll.frame = NSRect(x: T.cardPad, y: 38, width: T.innerW, height: 196)
        deviceScroll.hasVerticalScroller = true
        deviceScroll.autohidesScrollers = true
        deviceScroll.drawsBackground = false
        deviceScroll.borderType = .noBorder
        deviceContainer.frame = NSRect(x: 0, y: 0, width: T.innerW - 2, height: 10)
        deviceScroll.documentView = deviceContainer
        card2.addSubview(deviceScroll)

        emptyHint.font = .systemFont(ofSize: 11.5)
        emptyHint.textColor = .tertiaryLabelColor
        emptyHint.stringValue = "扫描中…（蓝牙关闭或附近没有设备时会一直为空）"
        emptyHint.frame = NSRect(x: T.cardPad + 4, y: 106, width: 420, height: 18)
        card2.addSubview(emptyHint)

        let rescan = NSButton(title: "重新扫描", target: self, action: #selector(doRescan))
        rescan.bezelStyle = .rounded
        rescan.controlSize = .small
        rescan.font = .systemFont(ofSize: 11)
        rescan.frame = NSRect(x: T.cardPad, y: 244, width: 82, height: 22)
        card2.addSubview(rescan)

        trustedCount.font = .systemFont(ofSize: 11)
        trustedCount.textColor = .tertiaryLabelColor
        trustedCount.alignment = .right
        trustedCount.frame = NSRect(
            x: T.cardPad + T.innerW - 220, y: 246, width: 220, height: 18)
        card2.addSubview(trustedCount)

        // ── 卡片 3：阈值
        let card3 = makeCard(c, top: 508, height: 196)
        card3.addSubview(makeCardTitle("强度阈值", top: 14))
        card3.addSubview(makeCardNote("左端 = 更远（弱）　右端 = 更近（强）", top: 14))

        configure(slider: unlockSlider, action: #selector(unlockChanged))
        card3.addSubview(mkLabel("解锁强度", x: T.cardPad, y: 46, w: 76))
        card3.addSubview(unlockSlider)
        unlockSlider.frame = NSRect(x: T.cardPad + 80, y: 44, width: T.innerW - 80 - 86, height: 22)
        unlockValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        unlockValue.alignment = .right
        unlockValue.frame = NSRect(x: T.cardPad + T.innerW - 82, y: 46, width: 82, height: 18)
        card3.addSubview(unlockValue)

        configure(slider: lockSlider, action: #selector(lockChanged))
        card3.addSubview(mkLabel("锁屏强度", x: T.cardPad, y: 80, w: 76))
        card3.addSubview(lockSlider)
        lockSlider.frame = NSRect(x: T.cardPad + 80, y: 78, width: T.innerW - 80 - 86, height: 22)
        lockValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        lockValue.alignment = .right
        lockValue.frame = NSRect(x: T.cardPad + T.innerW - 82, y: 80, width: 82, height: 18)
        card3.addSubview(lockValue)

        let note = mkLabel(
            "两个阈值之间是过渡区，不会来回抖动；解锁强度必须强于锁屏强度。",
            x: T.cardPad, y: 112, w: T.innerW - 32)
        note.font = .systemFont(ofSize: 10.5)
        note.textColor = .tertiaryLabelColor
        card3.addSubview(note)

        prediction.font = .systemFont(ofSize: 12, weight: .medium)
        prediction.frame = NSRect(x: T.cardPad, y: 140, width: T.innerW, height: 20)
        card3.addSubview(prediction)

        let rangeNote = mkLabel("−95 dBm", x: T.cardPad + 80, y: 166, w: 60)
        rangeNote.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        rangeNote.textColor = .tertiaryLabelColor
        card3.addSubview(rangeNote)
        let rangeNote2 = mkLabel("−40 dBm", x: T.innerW - 60, y: 166, w: 60)
        rangeNote2.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        rangeNote2.textColor = .tertiaryLabelColor
        rangeNote2.alignment = .right
        card3.addSubview(rangeNote2)

        // ── 卡片 4：行为
        let card4 = makeCard(c, top: 716, height: 140)
        card4.addSubview(makeCardTitle("行为", top: 14))

        configure(check: authFillCheck, action: #selector(authFillToggled))
        card4.addSubview(authFillCheck)
        authFillCheck.frame = NSRect(x: T.cardPad, y: 42, width: 210, height: 22)

        card4.addSubview(mkLabel("冷却", x: T.cardPad + 220, y: 44, w: 30))
        configure(slider: cooldownSlider, action: #selector(cooldownChanged))
        cooldownSlider.minValue = 3
        cooldownSlider.maxValue = 120
        cooldownSlider.frame = NSRect(x: T.cardPad + 254, y: 42, width: 170, height: 20)
        card4.addSubview(cooldownSlider)
        cooldownValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        cooldownValue.textColor = .secondaryLabelColor
        cooldownValue.frame = NSRect(x: T.cardPad + 430, y: 44, width: 70, height: 18)
        card4.addSubview(cooldownValue)

        configure(check: autoUnlockCheck, action: #selector(autoUnlockToggled))
        card4.addSubview(autoUnlockCheck)
        autoUnlockCheck.frame = NSRect(x: T.cardPad, y: 72, width: 250, height: 22)

        configure(check: autoLockCheck, action: #selector(autoLockToggled))
        card4.addSubview(autoLockCheck)
        autoLockCheck.frame = NSRect(x: T.cardPad, y: 102, width: 200, height: 22)

        card4.addSubview(mkLabel("延迟", x: T.cardPad + 220, y: 104, w: 30))
        configure(slider: delaySlider, action: #selector(delayChanged))
        delaySlider.minValue = 15
        delaySlider.maxValue = 300
        delaySlider.frame = NSRect(x: T.cardPad + 254, y: 102, width: 170, height: 20)
        card4.addSubview(delaySlider)
        delayValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        delayValue.textColor = .secondaryLabelColor
        delayValue.frame = NSRect(x: T.cardPad + 430, y: 104, width: 70, height: 18)
        card4.addSubview(delayValue)

        // ── 底部按钮
        let by: CGFloat = 876
        let pwBtn = NSButton(title: "设置密码…", target: self, action: #selector(promptPassword))
        pwBtn.bezelStyle = .rounded
        pwBtn.frame = NSRect(x: T.pad, y: by, width: 106, height: 30)
        c.addSubview(pwBtn)

        let diagBtn = NSButton(title: "权限自检", target: self, action: #selector(showDiag))
        diagBtn.bezelStyle = .rounded
        diagBtn.frame = NSRect(x: T.pad + 116, y: by, width: 96, height: 30)
        c.addSubview(diagBtn)

        let logBtn = NSButton(title: "查看日志", target: self, action: #selector(openLog))
        logBtn.bezelStyle = .rounded
        logBtn.frame = NSRect(x: T.pad + 222, y: by, width: 96, height: 30)
        c.addSubview(logBtn)

        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()

        refresh()
        startTimer()
    }

    // MARK: - 小工具

    private func makeCard(_ parent: NSView, top: CGFloat, height: CGFloat) -> CardView {
        let card = CardView(frame: NSRect(x: T.pad, y: top, width: T.cardW, height: height))
        parent.addSubview(card)
        return card
    }

    private func makeCardTitle(_ text: String, top: CGFloat) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12.5, weight: .semibold)
        l.frame = NSRect(x: T.cardPad, y: top, width: 200, height: 18)
        return l
    }

    private func makeCardNote(_ text: String, top: CGFloat) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 10.5)
        l.textColor = .tertiaryLabelColor
        l.alignment = .right
        l.frame = NSRect(x: T.cardPad + 200, y: top + 1, width: T.innerW - 200, height: 16)
        return l
    }

    private func mkLabel(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12)
        l.frame = NSRect(x: x, y: y, width: w, height: 18)
        return l
    }

    private func configure(slider: NSSlider, action: Selector) {
        slider.minValue = Double(Settings.thresholdMin)
        slider.maxValue = Double(Settings.thresholdMax)
        slider.target = self
        slider.action = action
        slider.isContinuous = true
    }

    private func configure(check: NSButton, action: Selector) {
        check.target = self
        check.action = action
        check.font = .systemFont(ofSize: 12.5)
    }

    // MARK: - 刷新

    private func refresh() {
        let s = Settings.shared
        let p = PresenceMonitor.shared

        // 建窗口后 QuartzCore 会在 malloc large 区预留一些页，定期归还。
        tickCount += 1
        if tickCount % 8 == 0 {
            malloc_zone_pressure_relief(nil, 0)
        }

        // 顶部胶囊
        if s.paused {
            pill.text = "‖ 已暂停"
            pill.tint = .systemGray
        } else if let r = p.bestTrustedRSSI() {
            pill.text = "\(p.presence.symbol) \(p.presence.rawValue) · \(r)"
            pill.tint = p.presence == .present
                ? .systemGreen
                : (p.presence == .absent ? .systemRed : .systemOrange)
        } else {
            pill.text = "\(p.presence.symbol) \(p.presence.rawValue)"
            pill.tint = .systemGray
        }
        pill.resize()
        pill.setFrameOrigin(NSPoint(x: T.W - T.pad - pill.frame.width, y: 18))

        // 曲线
        let focusID = s.primaryDeviceID
            ?? s.trustedDeviceIDs.first
            ?? p.allDevices().first?.id
        if let id = focusID, let d = p.device(id) {
            graph.values = d.history
        } else {
            graph.values = []
        }
        graph.unlockThreshold = s.unlockThreshold
        graph.lockThreshold = s.lockThreshold
        graph.needsDisplay = true

        refreshDeviceRows()

        // 阈值
        unlockSlider.doubleValue = Double(s.unlockThreshold)
        lockSlider.doubleValue = Double(s.lockThreshold)
        unlockValue.stringValue = "\(s.unlockThreshold) dBm"
        lockValue.stringValue = "\(s.lockThreshold) dBm"

        // 预测
        let rssis = s.trustedDeviceIDs.compactMap { p.liveRSSI($0) }
        let best = rssis.max()
        if !s.isConfigured {
            prediction.stringValue = "还没有勾选信任设备，三个功能都不会生效"
            prediction.textColor = .systemOrange
        } else if p.bluetoothState != .poweredOn {
            prediction.stringValue = "蓝牙未开启"
            prediction.textColor = .systemOrange
        } else if let b = best {
            if b >= s.unlockThreshold {
                prediction.stringValue = "此刻若锁屏 → 会自动解锁 ✓（当前 \(b) dBm ≥ \(s.unlockThreshold)）"
                prediction.textColor = .systemGreen
            } else if b <= s.lockThreshold {
                prediction.stringValue = "此刻若人在解锁状态 → 会触发自动锁屏（当前 \(b) dBm ≤ \(s.lockThreshold)）"
                prediction.textColor = .systemRed
            } else {
                prediction.stringValue = "信号处于过渡区（当前 \(b) dBm），不触发任何动作"
                prediction.textColor = .secondaryLabelColor
            }
        } else {
            prediction.stringValue = "信任设备当前无信号（\(p.presence.rawValue)）"
            prediction.textColor = .secondaryLabelColor
        }

        authFillCheck.state = s.authFillEnabled ? .on : .off
        autoUnlockCheck.state = s.autoUnlockEnabled ? .on : .off
        autoLockCheck.state = s.autoLockEnabled ? .on : .off
        cooldownSlider.doubleValue = s.authCooldown
        cooldownValue.stringValue = "\(Int(s.authCooldown)) 秒"
        delaySlider.doubleValue = s.autoLockDelay
        delayValue.stringValue = "\(Int(s.autoLockDelay)) 秒"
    }

    private func refreshDeviceRows() {
        let s = Settings.shared
        let p = PresenceMonitor.shared

        let devices = p.allDevices().sorted { a, b in
            let at = s.isTrusted(a.id), bt = s.isTrusted(b.id)
            if at != bt { return at }
            return p.displayName(a.id).localizedCompare(p.displayName(b.id)) == .orderedAscending
        }

        emptyHint.isHidden = !devices.isEmpty
        let n = s.trustedDeviceIDs.count
        trustedCount.stringValue = n > 0 ? "已勾选 \(n) 个设备" : ""

        let ids = devices.map { $0.id }
        if Set(ids) != Set(rows.keys) {
            for (id, r) in rows where !ids.contains(id) {
                r.removeFromSuperview()
                rows.removeValue(forKey: id)
            }
        }

        let rowH: CGFloat = 30
        let width = deviceScroll.contentSize.width
        let totalH = max(CGFloat(devices.count) * rowH, 1)
        deviceContainer.frame = NSRect(x: 0, y: 0, width: width, height: totalH)

        for (i, d) in devices.enumerated() {
            let row: DeviceRowView
            if let existing = rows[d.id] {
                row = existing
            } else {
                row = DeviceRowView(deviceID: d.id)
                row.onToggleTrust = { [weak self] on in
                    Settings.shared.setTrusted(d.id, on)
                    Log.info("\(on ? "信任" : "取消信任")设备 \(PresenceMonitor.shared.displayName(d.id))")
                    if on {
                        if Settings.shared.primaryDeviceID == nil {
                            Settings.shared.primaryDeviceID = d.id
                        }
                        // 勾选说明用户在意它，顺手把真名读出来
                        PresenceMonitor.shared.requestRealName(d.id)
                        // 名字还是随机串的话，直接问用户要个真名
                        if PresenceMonitor.shared.isUnknownName(d.id) {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                self?.promptRename(deviceID: d.id)
                            }
                        }
                    }
                    self?.refresh()
                }
                row.onSetPrimary = { [weak self] in
                    Settings.shared.primaryDeviceID = d.id
                    Settings.shared.setTrusted(d.id, true)
                    PresenceMonitor.shared.requestRealName(d.id)
                    Log.info("解锁主设备设为 \(PresenceMonitor.shared.displayName(d.id))")
                    self?.refresh()
                }
                row.onRename = { [weak self] in
                    self?.promptRename(deviceID: d.id)
                }
                rows[d.id] = row
                deviceContainer.addSubview(row)

                // 名字不像真名就主动去读一次
                if !PresenceMonitor.shared.hasRealName(d.id) {
                    PresenceMonitor.shared.requestRealName(d.id)
                }
            }
            row.frame = NSRect(x: 0, y: CGFloat(i) * rowH, width: width, height: rowH)

            let age = Date().timeIntervalSince(d.lastSeen)
            let live = p.liveRSSI(d.id)
            row.update(
                name: p.displayName(d.id),
                rssi: live ?? (age < p.staleThreshold ? Int(d.emaRSSI.rounded()) : nil),
                age: age < 180 ? age : nil,
                trusted: s.isTrusted(d.id),
                primary: s.primaryDeviceID == d.id,
                stale: live == nil,
                pending: p.isResolvingName(d.id),
                unknownName: p.isUnknownName(d.id)
            )
        }
    }

    // MARK: - 动作

    private func promptRename(deviceID: String) {
        let current = Settings.shared.alias(deviceID) ?? PresenceMonitor.shared.displayName(deviceID)
        let alert = NSAlert()
        alert.messageText = "给设备起个名字"
        alert.informativeText = "留空则恢复自动识别的名字。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "例如：我的手机"
        field.stringValue = (current == "未知设备") ? "" : current
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.shared.setAlias(deviceID, name.isEmpty ? nil : name)
        Log.info("设备 \(deviceID.prefix(8)) 重命名为「\(name.isEmpty ? "(自动)" : name)」")
        refresh()
    }

    @objc private func doRescan() {
        PresenceMonitor.shared.rescan()
        refresh()
    }

    @objc private func unlockChanged() {
        Settings.shared.unlockThreshold = Int(unlockSlider.doubleValue.rounded())
        refresh()
    }

    @objc private func lockChanged() {
        Settings.shared.lockThreshold = Int(lockSlider.doubleValue.rounded())
        refresh()
    }

    @objc private func authFillToggled() {
        Settings.shared.authFillEnabled = authFillCheck.state == .on
    }

    @objc private func autoUnlockToggled() {
        Settings.shared.autoUnlockEnabled = autoUnlockCheck.state == .on
    }

    @objc private func autoLockToggled() {
        Settings.shared.autoLockEnabled = autoLockCheck.state == .on
    }

    @objc private func cooldownChanged() {
        Settings.shared.authCooldown = cooldownSlider.doubleValue.rounded()
        cooldownValue.stringValue = "\(Int(Settings.shared.authCooldown)) 秒"
    }

    @objc private func delayChanged() {
        Settings.shared.autoLockDelay = delaySlider.doubleValue.rounded()
        delayValue.stringValue = "\(Int(Settings.shared.autoLockDelay)) 秒"
    }

    @objc private func promptPassword() {
        let alert = NSAlert()
        alert.messageText = "设置登录密码"
        alert.informativeText = """
        密码保存在系统钥匙串（仅本机、解锁后才可读），
        只用于自动填写授权弹窗和自动解锁。
        """
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "登录密码"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var pw = field.stringValue
        guard !pw.isEmpty else { return }

        if KeychainStore.shared.save(pw) {
            Log.shared.registerSecret(pw)
            Log.info("密码已保存到钥匙串")
            Notifier.post(title: "NearbyPass", body: "密码已保存")
        } else {
            Log.error("密码保存失败")
        }
        KeychainStore.zeroString(&pw)
        field.stringValue = ""
    }

    @objc private func showDiag() {
        let ax = AX.isTrusted ? "✅ 已授权" : "❌ 未授权（必须授权）"
        let bt: String
        switch PresenceMonitor.shared.bluetoothState {
        case .poweredOn: bt = "✅ 正常"
        case .poweredOff: bt = "❌ 已关闭"
        case .unauthorized: bt = "❌ 未授权"
        case .unsupported: bt = "❌ 不支持"
        default: bt = "⏳ \(PresenceMonitor.shared.bluetoothState.rawValue)"
        }
        let alert = NSAlert()
        alert.messageText = "权限自检"
        alert.informativeText = """
        辅助功能：\(ax)
        蓝牙：\(bt)
        密码：\(KeychainStore.shared.hasPassword() ? "✅ 已保存" : "❌ 未设置")
        信任设备：\(Settings.shared.isConfigured ? "✅ \(Settings.shared.trustedDeviceIDs.count) 个" : "❌ 未配置")

        「辅助功能」是三个功能的基础。
        """
        alert.addButton(withTitle: "好")
        if !AX.isTrusted {
            alert.addButton(withTitle: "去授权")
            if alert.runModal() == .alertSecondButtonReturn {
                AX.promptTrust()
            }
        } else {
            alert.runModal()
        }
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Log.shared.logFilePath))
    }
}

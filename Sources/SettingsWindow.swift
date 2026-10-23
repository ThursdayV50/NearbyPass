// SettingsWindow.swift — 设置窗口（SwiftUI 承载）
//
// 界面本体在 Sources/UI/SettingsView.swift；这里只负责开窗与生命周期。
// 对外接口保持 show() 不变。

import AppKit
import SwiftUI

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {

    static let shared = SettingsWindow()

    private var window: NSWindow?

    private override init() { super.init() }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            w.orderFrontRegardless()
            AppModel.shared.refresh()
            return
        }
        build()
    }

    private func build() {
        // 先按自然高度量一遍，再按屏幕能容纳的高度开窗，放不下的部分交给 ScrollView
        let probe = NSHostingView(rootView: SettingsView(measured: true))
        let natural = probe.fittingSize.height

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let cap = UserDefaults.standard.double(forKey: "windowHeightCap")
        let maxH = (cap > 0 ? cap : screen.height - 48)
        let height = max(480, min(natural + 2, maxH))

        let host = NSHostingView(rootView: SettingsView())
        let size = NSSize(width: 700, height: height)
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = "NearbyPass 设置"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.backgroundColor = NSColor(white: 0.105, alpha: 1)
        w.isOpaque = false
        // 用一层普通 NSView 兜住，确保 SwiftUI 拿到的是窗口的最终尺寸，
        // 而不是内容自然高度（否则 ScrollView 会按底部对齐显示）
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.autoresizingMask = [.width, .height]
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        w.contentView = container
        w.center()

        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
        AppModel.shared.start()
        Log.info("设置窗口已打开")
    }

    func windowWillClose(_ notification: Notification) {
        // 窗口关掉就停掉每秒轮询，回到常驻时的低占用
        AppModel.shared.stop()
    }
}

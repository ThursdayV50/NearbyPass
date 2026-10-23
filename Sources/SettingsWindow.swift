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
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 812),
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
        w.backgroundColor = NSColor(srgbRed: 0.07, green: 0.08, blue: 0.16, alpha: 1)
        w.isOpaque = false
        w.contentView = NSHostingView(rootView: SettingsView())
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

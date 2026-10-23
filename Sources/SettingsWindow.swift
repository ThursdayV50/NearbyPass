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
        let host = NSHostingView(rootView: SettingsView())
        let fit = host.fittingSize
        let size = NSSize(width: max(700, fit.width), height: max(560, fit.height + 30))
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
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
        w.backgroundColor = NSColor(white: 0.105, alpha: 1)
        w.isOpaque = false
        w.contentView = host
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

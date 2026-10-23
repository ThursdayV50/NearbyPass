// TutorialWindow.swift — 首次启动教程的窗口

import AppKit
import SwiftUI

@MainActor
final class TutorialWindow: NSObject, NSWindowDelegate {

    static let shared = TutorialWindow()

    private var window: NSWindow?

    private override init() { super.init() }

    /// 只在没看过的时候弹
    func showIfNeeded() {
        guard !Settings.shared.hasCompletedOnboard else { return }
        show()
    }

    /// 从菜单里重看
    func show() {
        if window == nil { build() }
        guard let w = window else { return }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
    }

    private func build() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = "欢迎使用 NearbyPass"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.backgroundColor = NSColor(srgbRed: 0.07, green: 0.08, blue: 0.16, alpha: 1)
        w.isOpaque = false
        let host = NSHostingView(rootView: TutorialView { [weak self] in
            self?.finish()
        })
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 600)
        w.contentView = host
        w.setContentSize(NSSize(width: 480, height: 600))
        w.center()
        window = w

        // 出场：轻微放大 + 淡入
        w.alphaValue = 0
        DispatchQueue.main.async {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                w.animator().alphaValue = 1
            }
        }
    }

    private func finish() {
        Settings.shared.hasCompletedOnboard = true
        Log.info("教程已完成")
        window?.close()
        window = nil
        // 教程结束后直接把设置打开，用户能立刻配设备
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            SettingsWindow.shared.show()
        }
    }

    func windowWillClose(_ notification: Notification) {
        // 关窗也视为看过，避免每次都弹
        if !Settings.shared.hasCompletedOnboard {
            Settings.shared.hasCompletedOnboard = true
        }
        window = nil
    }
}

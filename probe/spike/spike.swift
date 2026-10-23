import AppKit
import SwiftUI

struct Content: View {
    @State private var on = false
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.09, green: 0.11, blue: 0.25),
                                    Color(red: 0.35, green: 0.18, blue: 0.42)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 18) {
                Text("NearbyPass").font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
                Text("SwiftUI + Liquid Glass spike").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.08))
                    .frame(width: 300, height: 90)
                    .overlay(Text("卡片").foregroundStyle(.white.opacity(0.85)))
            }
            .padding(28)
            .glassPanel()
        }
        .frame(width: 460, height: 380)
        .onAppear { withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { on = true } }
    }
}

extension View {
    @ViewBuilder func glassPanel() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}

final class Del: NSObject, NSApplicationDelegate {
    var w: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
                           styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.backgroundColor = .clear
        win.isOpaque = false
        win.contentView = NSHostingView(rootView: Content())
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        w = win
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { NSApp.terminate(nil) }
    }
}
let app = NSApplication.shared
let d = Del()
app.delegate = d
app.setActivationPolicy(.regular)
app.run()

// minwin.swift — 最小 AppKit 窗口，用来测「打开一个窗口」本身的系统开销
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let w = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 740, height: 926),
    styleMask: [.titled, .closable],
    backing: .buffered,
    defer: false
)
w.title = "minwin"
w.makeKeyAndOrderFront(nil)
w.center()

print("pid=\(getpid())")
fflush(stdout)

app.run()

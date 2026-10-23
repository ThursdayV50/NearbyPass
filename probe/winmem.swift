// winmem.swift — 逐个控件类型测内存，定位 AppKit 各控件的真实开销
// 用法: winmem <case>   case: empty|chk_conv|chk_raw|lbl_conv|lbl_raw|views200|sliders|status_emoji|status_img|cards
import AppKit

let arg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "empty"
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let w = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 740, height: 926),
    styleMask: [.titled, .closable],
    backing: .buffered,
    defer: false
)
w.title = "winmem-" + arg
w.makeKeyAndOrderFront(nil)
w.center()

let host = w.contentView!

func addRow(_ i: Int) {
    let y = CGFloat(900 - i * 32)
    if y < 0 { return }
    _ = y
}

switch arg {
case "chk_conv":
    for i in 0..<6 {
        let b = NSButton(checkboxWithTitle: "选项 \(i) 这是一个比较长的中文标签文本", target: nil, action: nil)
        b.frame = NSRect(x: 20, y: CGFloat(860 - i * 30), width: 400, height: 22)
        host.addSubview(b)
    }
case "chk_raw":
    for i in 0..<6 {
        let b = NSButton(frame: NSRect(x: 20, y: CGFloat(860 - i * 30), width: 400, height: 22))
        b.setButtonType(.switch)
        b.title = "选项 \(i) 这是一个比较长的中文标签文本"
        host.addSubview(b)
    }
case "lbl_conv":
    for i in 0..<60 {
        let l = NSTextField(labelWithString: "第 \(i) 行标签 -67 dBm 中文测试")
        l.frame = NSRect(x: 20, y: CGFloat(880 - i * 14), width: 400, height: 18)
        host.addSubview(l)
    }
case "lbl_raw":
    for i in 0..<60 {
        let l = NSTextField(frame: NSRect(x: 20, y: CGFloat(880 - i * 14), width: 400, height: 18))
        l.isEditable = false
        l.isBordered = false
        l.drawsBackground = false
        l.stringValue = "第 \(i) 行标签 -67 dBm 中文测试"
        host.addSubview(l)
    }
case "views200":
    for i in 0..<200 {
        let v = NSView(frame: NSRect(x: CGFloat(20 + (i % 20) * 35), y: CGFloat(880 - (i / 20) * 60), width: 30, height: 30))
        v.wantsLayer = true
        host.addSubview(v)
    }
case "sliders":
    for i in 0..<4 {
        let s = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
        s.frame = NSRect(x: 20, y: CGFloat(860 - i * 40), width: 300, height: 22)
        host.addSubview(s)
    }
case "status_emoji":
    let si = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    si.button?.title = "🟢 -67"
    let m = NSMenu()
    m.addItem(NSMenuItem(title: "项目一", action: nil, keyEquivalent: ""))
    m.addItem(.separator())
    m.addItem(NSMenuItem(title: "项目二", action: nil, keyEquivalent: ""))
    si.menu = m
case "status_img":
    let si = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let img = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
        NSColor.systemGreen.setFill()
        NSBezierPath(ovalIn: rect).fill()
        return true
    }
    si.button?.image = img
case "cards":
    final class Card: NSView {
        override var isFlipped: Bool { true }
        override func draw(_ r: NSRect) {
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        }
    }
    for i in 0..<4 {
        let c = Card(frame: NSRect(x: 20, y: CGFloat(60 + i * 200), width: 700, height: 180))
        host.addSubview(c)
    }
default:
    break
}

print("pid=\(getpid()) case=\(arg)")
fflush(stdout)
app.run()

// clickat.swift — clickat <x> <y> [--double]
// 屏幕逻辑坐标，左上角为原点（与 NSScreen/CGEvent 一致）。
import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 3, let x = Double(args[1]), let y = Double(args[2]) else {
    print("用法: clickat <x> <y> [--double]")
    exit(1)
}
let p = CGPoint(x: x, y: y)
let src = CGEventSource(stateID: .hidSystemState)
src?.localEventsSuppressionInterval = 0

CGEvent(mouseEventSource: src, mouseType: .mouseMoved,
        mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(80_000)
CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
        mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(60_000)
let clickCount: Int64 = args.contains("--double") ? 2 : 1
CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
        mouseCursorPosition: p, mouseButton: .left)?.setIntegerValueField(.mouseEventClickState, value: clickCount)
CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
        mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
print("已点击 (\(x), \(y))")

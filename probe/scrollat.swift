// scrollat.swift — 在指定屏幕坐标滚动滚轮
// 用法: scrollat <x> <y> <dy>    dy 为负向下滚，为正向上滚
import Cocoa

let a = CommandLine.arguments
guard a.count >= 4, let x = Double(a[1]), let y = Double(a[2]), let dy = Int32(a[3]) else {
    print("用法: scrollat <x> <y> <dy>"); exit(1)
}
let src = CGEventSource(stateID: .hidSystemState)
src?.localEventsSuppressionInterval = 0

CGEvent(mouseEventSource: src, mouseType: .mouseMoved,
        mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)?
    .post(tap: .cghidEventTap)
usleep(120_000)
let useLine = (a.count > 4 && a[4] == "line")
for _ in 0..<(useLine ? 12 : 6) {
    let e = CGEvent(scrollWheelEvent2Source: src, units: useLine ? .line : .pixel,
                    wheelCount: 1,
                    wheel1: useLine ? (abs(dy) > 100 ? -3 : dy) : dy,
                    wheel2: 0, wheel3: 0)
    e?.setIntegerValueField(.scrollWheelEventIsContinuous, value: useLine ? 0 : 1)
    e?.post(tap: .cghidEventTap)
    usleep(40_000)
}
print("scrolled \(dy) at \(x),\(y)")

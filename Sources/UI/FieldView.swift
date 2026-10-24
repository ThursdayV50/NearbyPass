// FieldView.swift — 同心距离场
//
// 一个圆就是一件事：离得多远。
//   两个阈值环之间的距离 = 迟滞带，环内什么都不做，所以不会在边界抖。
//   设备点漂到哪一侧，就决定了此刻是「在」还是「不在」。
// 半径不是线性的（pow 1.35）：弱信号那段挤在一起，因为 -85 和 -90 的差别
// 本来就不该在视觉上占同样宽的篇幅。

import SwiftUI

struct DistanceField: View {
    /// 当前判定的信号（主设备；没有主设备时用最强的那台）
    var rssi: Int?
    /// 解锁阈值（强于此值解锁）
    var unlock: Int
    /// 锁屏阈值（弱于此值算离开）
    var lock: Int
    var host: HostKind = HostModel.current.kind
    /// 主设备名字，显示在点的旁边；nil 表示还没选设备
    var deviceName: String? = nil
    /// 是否已判定为「在场」，只影响点的配色与脉冲
    var present: Bool = true
    /// 名字显示为「主设备」的占位（教程第 1 步用）
    var placeholderName: Bool = false

    @State private var shownRSSI: Double = -60
    @State private var shownUnlock: Double = -80
    @State private var shownLock: Double = -95
    @State private var pulse: Double = 0
    @State private var didInit = false
    @State private var moveTask: Task<Void, Never>? = nil

    private let dbmNear: Double = -40
    private let dbmFar: Double = -95

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let scale = side / 340

            ZStack {
                Canvas { ctx, size in
                    draw(&ctx, size: size, scale: scale)
                }
                hostGlyph(scale: scale)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear {
            shownUnlock = Double(unlock)
            shownLock = Double(lock)
            shownRSSI = Double(rssi ?? unlock - 8)
            didInit = true
        }
        .onChange(of: rssi) { v in
            animate(to: v.map(Double.init), current: $shownRSSI)
        }
        .onChange(of: unlock) { v in
            animate(to: Double(v), current: $shownUnlock)
        }
        .onChange(of: lock) { v in
            animate(to: Double(v), current: $shownLock)
        }
        .onChange(of: present) { _ in
            withAnimation(.easeOut(duration: 0.5)) { pulse += 1 }
        }
    }

    // MARK: - 半径映射

    private func radius(_ dbm: Double, _ scale: CGFloat) -> CGFloat {
        let p = max(0, min(1, (dbmNear - dbm) / (dbmNear - dbmFar)))
        return (26 + 132 * pow(p, 1.35)) * scale
    }

    // MARK: - 绘制

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, scale: CGFloat) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let rUnlock = radius(shownUnlock, scale)
        let rLock = radius(shownLock, scale)
        let rDevice = radius(shownRSSI, scale)
        let outer = radius(dbmFar, scale) + 10 * scale

        // 最外圈：视野边界，提示「再远就测不到了」
        ctx.stroke(circle(c, outer), with: .color(Theme.hair2), lineWidth: 1)

        // 迟滞带：两环之间什么都不做
        let band = Path { p in
            p.addEllipse(in: CGRect(x: c.x - rUnlock, y: c.y - rUnlock,
                                    width: rUnlock * 2, height: rUnlock * 2))
            p.addEllipse(in: CGRect(x: c.x - rLock, y: c.y - rLock,
                                    width: rLock * 2, height: rLock * 2))
        }
        ctx.fill(band, with: .color(Theme.signal.opacity(0.042)), style: FillStyle(eoFill: true))

        // 两个阈值环
        ctx.stroke(circle(c, rUnlock), with: .color(Theme.signal), lineWidth: 1.5)
        ctx.stroke(circle(c, rLock), with: .color(Theme.signal.opacity(0.45)), lineWidth: 1.5)

        // 环标签：两环贴太近时把角度岔开，避免糊在一起
        let gap = abs(rLock - rUnlock)
        let lockAngle = gap < 26 ? 338.0 : 322.0
        let unlockAngle = 203.0
        drawRingLabel(&ctx, "解锁 \(unlock)", at: c, r: rUnlock, deg: unlockAngle, color: Theme.signal)
        drawRingLabel(&ctx, "锁屏 \(lock)", at: c, r: rLock, deg: lockAngle,
                      color: Theme.signal.opacity(0.75))

        // 设备点：固定方位角，只有半径在动
        if rssi != nil {
            let deg = 22.0 * .pi / 180
            let dp = CGPoint(x: c.x + rDevice * cos(deg), y: c.y + rDevice * sin(deg))
            let tint = present ? Theme.signal : Theme.away

            // 脉冲：判定翻转时向外扩一圈淡影
            if pulse > 0 {
                let k = pulse.truncatingRemainder(dividingBy: 1)
                ctx.stroke(circle(dp, 6 + 10 * k * scale),
                           with: .color(tint.opacity(0.35 * (1 - k))), lineWidth: 1.2)
            }

            ctx.fill(circle(dp, 8.5 * scale), with: .color(tint.opacity(0.13)))
            ctx.fill(circle(dp, 3.4 * scale), with: .color(tint))

            // 标签压在环线上时得有个纸底，否则细线会从字里穿过去
            let name = placeholderName ? "主设备" : (deviceName ?? "主设备")
            let t1 = ctx.resolve(Text(name)
                .font(Theme.text(10, .medium))
                .foregroundStyle(present ? Theme.ink2 : Theme.away))
            let t2 = ctx.resolve(Text("\(Int(shownRSSI.rounded())) dBm")
                .font(Theme.mono(9))
                .foregroundStyle(Theme.ink3))
            let box = CGSize(width: 200, height: 40)
            let w = max(t1.measure(in: box).width, t2.measure(in: box).width)
            let th = t1.measure(in: box).height

            // 先量宽再决定往哪边放：往右会溢出就翻到左边
            let gap = 13 * scale
            let flip = dp.x + gap + w + 4 > size.width
            let anchor: UnitPoint = flip ? .topTrailing : .topLeading
            let tx = dp.x + (flip ? -gap : gap)
            let y1 = dp.y - 9 * scale
            let y2 = dp.y + 3 * scale

            let bx = flip ? tx - w - 3 : tx - 3
            ctx.fill(Path(roundedRect: CGRect(x: bx, y: y1 - 1.5,
                                              width: w + 6, height: th + (y2 - y1) + 1),
                          cornerRadius: 3),
                     with: .color(Theme.sheet.opacity(0.84)))

            ctx.draw(t1, at: CGPoint(x: tx, y: y1), anchor: anchor)
            ctx.draw(t2, at: CGPoint(x: tx, y: y2), anchor: anchor)
        }
    }

    private func circle(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    private func drawRingLabel(_ ctx: inout GraphicsContext, _ text: String,
                               at c: CGPoint, r: CGFloat, deg: Double, color: Color) {
        let a = deg * .pi / 180
        // 标签压在环上，稍微外移一点，不至于盖住环线
        let p = CGPoint(x: c.x + (r + 9) * cos(a), y: c.y + (r + 9) * sin(a))
        let t = ctx.resolve(Text(text).font(Theme.mono(9, .medium)).foregroundStyle(color))
        let sz = t.measure(in: CGSize(width: 160, height: 30))
        let rect = CGRect(x: p.x - sz.width / 2 - 3.5, y: p.y - sz.height / 2 - 1,
                          width: sz.width + 7, height: sz.height + 2)
        ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(Theme.sheet))
        ctx.draw(t, at: p, anchor: .center)
    }

    // MARK: - 场心机型

    private func hostGlyph(scale: CGFloat) -> some View {
        Image(systemName: host.symbol)
            .font(.system(size: 21 * scale, weight: .light))
            .foregroundStyle(Theme.ink.opacity(0.34))
            .allowsHitTesting(false)
    }

    // MARK: - 插值

    /// Canvas 不参与 SwiftUI 动画系统（它是个绘制闭包），所以 withAnimation 是空转的。
    /// 这里自己逐帧逼近，点才是真的"漂"过去而不是跳过去。
    private func animate(to target: Double?, current: Binding<Double>) {
        guard let target else { return }
        let start = current.wrappedValue
        guard abs(target - start) > 0.05 else { return }
        moveTask?.cancel()
        moveTask = Task { @MainActor in
            let t0 = Date()
            let dur = 0.42
            while !Task.isCancelled {
                let p = min(1, Date().timeIntervalSince(t0) / dur)
                let e = 1 - pow(1 - p, 3)          // easeOutCubic
                current.wrappedValue = start + (target - start) * e
                if p >= 1 { break }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }
}

// MARK: - 左栏：场 + 读数

struct FieldPane: View {
    @ObservedObject var m = AppModel.shared

    private var primary: DeviceVM? {
        m.devices.first(where: { $0.primary }) ?? m.devices.first(where: { $0.trusted })
    }

    private var shownRSSI: Int? {
        primary?.rssi ?? m.bestRSSI
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("距离场")
                    .font(Theme.text(10, .medium))
                    .foregroundStyle(Theme.ink3)
                Spacer(minLength: 6)
                Text(primary?.name ?? "未选主设备")
                    .font(Theme.text(10))
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)

            DistanceField(
                rssi: shownRSSI,
                unlock: m.unlockThreshold,
                lock: m.lockThreshold,
                host: HostModel.current.kind,
                deviceName: primary?.name,
                present: m.presenceState == .present
            )
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)

            VStack(spacing: 0) {
                Rectangle().fill(Theme.hair2).frame(height: 1)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("迟滞区间")
                            .font(Theme.text(9.5))
                            .foregroundStyle(Theme.ink3)
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("\(abs(m.unlockThreshold - m.lockThreshold))")
                                .font(Theme.mono(13, .semibold))
                                .foregroundStyle(Theme.ink)
                            Text("dB").font(Theme.mono(9)).foregroundStyle(Theme.ink3)
                        }
                    }
                    Spacer(minLength: 10)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("此刻若锁屏")
                            .font(Theme.text(9.5))
                            .foregroundStyle(Theme.ink3)
                        Text(m.unlockPrediction.ok ? "会自动解锁" : "不会解锁")
                            .font(Theme.text(11.5, .medium))
                            .foregroundStyle(m.unlockPrediction.ok ? Theme.signal : Theme.ink2)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
            }
        }
    }
}

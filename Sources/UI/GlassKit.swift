// GlassKit.swift — 液态玻璃与通用视觉件
//
// macOS 26 起 AppKit/SwiftUI 都有真正的 Liquid Glass。
// 26 以下回退到 ultraThinMaterial（视觉接近，但不是真玻璃）。

import SwiftUI
import AppKit

enum Glass {
    /// 是否支持真玻璃
    static var available: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
}

// MARK: - 玻璃卡片

struct GlassCard<Content: View>: View {
    var radius: CGFloat = 18
    var padding: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(GlassSurface(radius: radius, shape: shape))
    }
}

/// 把一块内容放到玻璃上。26 用真玻璃，以下用材质 + 描边模拟。
struct GlassSurface: ViewModifier {
    var radius: CGFloat
    var shape: RoundedRectangle

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.10), lineWidth: 1))
        }
    }
}

// MARK: - 品牌背景
//
// 窗口本身透明，背景用自绘渐变。玻璃卡片采样的是它，
// 于是能拿到稳定的色晕，不会因为用户换壁纸就变得难看。

struct BrandBackground: View {
    var body: some View {
        ZStack {
            // 中性石墨色，不用彩色。玻璃只需要一点明暗差，颜色交给内容本身。
            LinearGradient(
                colors: [Color(white: 0.145),
                         Color(white: 0.105)],
                startPoint: .top, endPoint: .bottom)
            // 顶部一道极淡的高光，模拟光源在窗口上方
            LinearGradient(
                colors: [Color.white.opacity(0.055), .clear],
                startPoint: .top, endPoint: .center)
        }
    }
}

// MARK: - 小标题

struct CardTitle: View {
    let text: String
    var note: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            if let note {
                Text(note).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 状态胶囊

struct StatusPill: View {
    let text: String
    let dot: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 7, height: 7)
                .shadow(color: dot.opacity(0.7), radius: 3)
            Text(text).font(.system(size: 11.5, weight: .medium)).monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.white.opacity(0.07), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1))
    }
}

// MARK: - 信号条（一列细竖条，替代原来的 5 格）

struct MiniBars: View {
    let dbm: Int?
    var height: CGFloat = 11

    private var lit: Int {
        guard let dbm else { return 0 }
        let t = (Double(dbm) + 95) / 55          // -95…-40 → 0…1
        return max(0, min(5, Int((t * 5).rounded())))
    }
    private var color: Color {
        lit >= 4 ? Color(white: 0.90)
        : lit >= 2 ? Color(white: 0.62)
        : Color(white: 0.38)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(i < lit ? color : Color.white.opacity(0.14))
                    .frame(width: 3, height: height * (0.42 + 0.145 * CGFloat(i)))
            }
        }
        .frame(height: height, alignment: .bottom)
    }
}

// MARK: - 双手柄区间滑块

/// 一条轨道两个手柄：左边手柄 = 锁屏强度，右边手柄 = 解锁强度。
/// 中间是死区（不触发任何动作）。
struct RangeSlider: View {
    @Binding var low: Int          // 锁屏强度（更弱，dBm 更小）
    @Binding var high: Int         // 解锁强度（更强，dBm 更大）
    var bounds: ClosedRange<Int> = -95 ... -40
    var minGap: Int = 5
    var onChange: () -> Void = {}

    @State private var dragging: Int? = nil   // 0 = low, 1 = high

    private let knob: CGFloat = 18

    private func ratio(_ v: Int) -> CGFloat {
        let span = CGFloat(bounds.upperBound - bounds.lowerBound)
        return CGFloat(v - bounds.lowerBound) / span
    }
    private func value(at x: CGFloat, width: CGFloat) -> Int {
        let r = min(max(0, x / max(1, width)), 1)
        let span = bounds.upperBound - bounds.lowerBound
        return bounds.lowerBound + Int((r * CGFloat(span)).rounded())
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - knob
            let xLow = ratio(low) * w + knob / 2
            let xHigh = ratio(high) * w + knob / 2

            ZStack(alignment: .leading) {
                // 轨道
                Capsule().fill(.white.opacity(0.10)).frame(height: 6)
                    .padding(.horizontal, knob / 2)

                // 死区（中间那段）
                Capsule()
                    .fill(LinearGradient(
                        colors: [Color(white: 0.34), Color(white: 0.55), Color(white: 0.88)],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, xHigh - xLow), height: 6)
                    .offset(x: xLow)

                // 手柄
                ForEach([0, 1], id: \.self) { i in
                    Circle()
                        .fill(.white)
                        .frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .overlay(Circle().strokeBorder(.black.opacity(0.10), lineWidth: 0.5))
                        .offset(x: (i == 0 ? xLow : xHigh) - knob / 2)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { g in
                                    let v = value(at: g.location.x - knob / 2, width: w)
                                    if i == 0 {
                                        low = min(v, high - minGap)
                                    } else {
                                        high = max(v, low + minGap)
                                    }
                                    onChange()
                                }
                        )
                }
            }
            .frame(height: knob)
            .contentShape(Rectangle())
        }
        .frame(height: knob)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: low)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: high)
    }
}

// MARK: - 强度曲线（60 根柱）

struct SignalGraph: View {
    let history: [Int?]
    let unlock: Int
    let lock: Int

    private func y(_ dbm: Double, _ h: CGFloat) -> CGFloat {
        let t = (dbm + 100) / 70          // -100…-30
        return h - CGFloat(max(0, min(1, t))) * h
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let n = max(1, history.count)
            let slot = geo.size.width / CGFloat(n)
            let barW = max(1.5, slot * 0.62)

            ZStack(alignment: .topLeading) {
                // 横向网格
                ForEach(0..<4, id: \.self) { i in
                    Rectangle().fill(.white.opacity(0.05)).frame(height: 0.5)
                        .offset(y: h * CGFloat(i) / 3)
                }
                // 阈值虚线
                ForEach([Double(unlock), Double(lock)], id: \.self) { v in
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y(v, h)))
                        p.addLine(to: CGPoint(x: geo.size.width, y: y(v, h)))
                    }
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(v == Double(unlock)
                                     ? Color(white: 0.88).opacity(0.75)
                                     : Color(white: 0.38).opacity(0.75))
                }
                // 柱子
                HStack(alignment: .bottom, spacing: slot - barW) {
                    ForEach(0..<n, id: \.self) { i in
                        let v = history[i]
                        let top = v.map { y(Double($0), h) } ?? h
                        RoundedRectangle(cornerRadius: barW / 2, style: .continuous)
                            .fill(v == nil ? Color.clear
                                  : (Double(v!) >= Double(unlock)
                                     ? Color(white: 0.90)
                                     : Color(white: 0.55)))
                            .frame(width: barW, height: max(1.5, h - top))
                    }
                }
            }
        }
    }
}

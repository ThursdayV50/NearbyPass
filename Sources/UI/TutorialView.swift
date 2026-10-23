// TutorialView.swift — 首次启动的 5 页教程
//
// 动效原则：弹簧 response 0.45 / damping 0.8，进场错开 60ms，
// 系统开启「减弱动态效果」时全部退化为淡入。

import SwiftUI
import AppKit

enum Motion {
    static var reduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    static let spring = Animation.spring(response: 0.45, dampingFraction: 0.8)
    static let quick = Animation.spring(response: 0.3, dampingFraction: 0.85)
}

struct TutorialView: View {
    @State private var page = 0
    var onDone: () -> Void

    private let pages = 5

    var body: some View {
        VStack(spacing: 0) {
            topBar

            ZStack {
                switch page {
                case 0: WelcomePage()
                case 1: DialogPage()
                case 2: LockPage()
                case 3: ThresholdPage()
                default: StarPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Motion.reduced ? .easeInOut(duration: 0.2) : Motion.spring, value: page)

            bottomBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrandBackground())
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        )
    }

    private var topBar: some View {
        HStack {
            Text("NearbyPass").font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
            Button("跳过") { onDone() }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.45))
                .focusEffectDisabled()
        }
        .padding(.horizontal, 18)
        .padding(.top, 26)
    }

    private var bottomBar: some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                ForEach(0..<pages, id: \.self) { i in
                    Capsule()
                        .fill(i == page ? Color.white.opacity(0.9) : Color.white.opacity(0.22))
                        .frame(width: i == page ? 16 : 6, height: 6)
                        .animation(Motion.quick, value: page)
                }
            }
            HStack(spacing: 10) {
                if page > 0 {
                    Button("上一步") { page -= 1 }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                        .focusEffectDisabled()
                }
                Spacer()
                Button {
                    if page == pages - 1 { onDone() } else { page += 1 }
                } label: {
                    Text(page == pages - 1 ? "开始使用" : "下一步")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(.white.opacity(0.92), in: Capsule())
                        .foregroundStyle(.black.opacity(0.85))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 20)
    }
}

// MARK: - 第 1 页 欢迎：扩散波纹

struct WelcomePage: View {
    @State private var phase: CGFloat = 0
    @State private var shown = false

    var body: some View {
        VStack(spacing: 26) {
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .strokeBorder(Color.white.opacity(0.30), lineWidth: 1)
                        .scaleEffect(phase + CGFloat(i) * 0.0)
                        .opacity((1 - phase) * 0.55)
                        .animation(
                            Motion.reduced ? nil :
                                .easeOut(duration: 3.0)
                                .repeatForever(autoreverses: false)
                                .delay(Double(i) * 1.0),
                            value: phase)
                }
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(.white)
            }
            .frame(width: 170, height: 170)
            .onAppear {
                guard !Motion.reduced else { return }
                phase = 1
            }

            VStack(spacing: 10) {
                Text("靠近即解锁")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                Text("设备在附近时解除锁屏，\n离开后自动锁定。")
                    .font(.system(size: 12.5))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.62))
                    .lineSpacing(3)
            }
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 10)
            .animation(Motion.spring.delay(0.1), value: shown)
        }
        .onAppear { shown = true }
    }
}

// MARK: - 第 2 页 授权弹窗

struct DialogPage: View {
    @State private var dots = 0
    @State private var showAsk = false
    @State private var done = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 22) {
            Text("授权弹窗自动填写")
                .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)

            // 模拟的系统密码框
            VStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.white.opacity(0.8))
                Text("“系统设置”想要进行更改。")
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.8))
                Text("输入你的密码以继续。")
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5))

                HStack(spacing: 5) {
                    ForEach(0..<6, id: \.self) { i in
                        Circle()
                            .fill(.white.opacity(i < dots ? 0.9 : 0.15))
                            .frame(width: 7, height: 7)
                    }
                }
                .padding(.vertical, 6)
                .frame(width: 180)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(18)
            .frame(width: 240)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1))

            // App 弹的确认卡
            HStack(spacing: 8) {
                Image(systemName: done ? "checkmark.circle.fill" : "dot.radiowaves.left.and.right")
                    .foregroundStyle(.white.opacity(done ? 0.92 : 0.30))
                Text(done ? "已填好" : "设备在附近，要填密码吗？")
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.9))
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.white.opacity(0.09), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .scaleEffect(showAsk ? 1 : 0.9)
            .opacity(showAsk ? 1 : 0)

            Text("需确认后才会填入，取消则不执行任何操作。")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
        }
        .onAppear { run() }
        .onDisappear { task?.cancel() }
    }

    private func run() {
        dots = 0; showAsk = false; done = false
        task = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_600_000_000)
                if Task.isCancelled { return }
                dots = 0; done = false
                withAnimation(Motion.quick) { showAsk = false }
                try? await Task.sleep(nanoseconds: 500_000_000)
                withAnimation(Motion.spring) { showAsk = true }
                try? await Task.sleep(nanoseconds: 700_000_000)
                for i in 1...6 {
                    if Task.isCancelled { return }
                    withAnimation(.easeOut(duration: 0.12)) { dots = i }
                    try? await Task.sleep(nanoseconds: 110_000_000)
                }
                try? await Task.sleep(nanoseconds: 350_000_000)
                withAnimation(Motion.spring) { done = true; showAsk = true }
            }
        }
    }
}

// MARK: - 第 3 页 解锁 / 锁屏

struct LockPage: View {
    @State private var near = true
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 24) {
            Text("距离判定")
                .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)

            HStack(spacing: 26) {
                Image(systemName: "iphone")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.white.opacity(near ? 0.95 : 0.35))
                    .scaleEffect(near ? 1.04 : 0.94)

                // 中间的信号波纹
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .fill(Color.white.opacity(0.55))
                            .frame(width: 5, height: 5)
                            .opacity(near ? 0.9 - Double(i) * 0.22 : 0.12)
                            .animation(Motion.quick.delay(Double(i) * 0.06), value: near)
                    }
                }

                // 电脑屏幕
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(near ? Color(white: 0.30) : Color(white: 0.10))
                        .frame(width: 84, height: 54)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                        .frame(width: 84, height: 54)
                    if !near {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.75))
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(Motion.spring, value: near)
            }
            .padding(.vertical, 6)

            Text(near ? "设备在场 · 已解锁" : "设备远离 · 已锁屏")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(near
                                 ? Color(white: 0.92)
                                 : Color(white: 0.55))
                .contentTransition(.opacity)

            Text("两个阈值分别对应「在场」与「离开」。\n中间区间留作缓冲，用于抑制信号波动引起的反复切换。")
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.45))
                .lineSpacing(3)
        }
        .onAppear {
            guard !Motion.reduced else { return }
            task = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_400_000_000)
                    if Task.isCancelled { return }
                    withAnimation(Motion.spring) { near.toggle() }
                }
            }
        }
        .onDisappear { task?.cancel() }
    }
}

// MARK: - 第 4 页 阈值

struct ThresholdPage: View {
    @State private var low = -85
    @State private var high = -60

    var body: some View {
        VStack(spacing: 22) {
            Text("阈值")
                .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)

            GlassCard(radius: 14, padding: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    RangeSlider(
                        low: Binding(get: { low }, set: { low = min($0, high - 5) }),
                        high: Binding(get: { high }, set: { high = max($0, low + 5) })
                    )
                    HStack {
                        Text("锁屏 \(low) dBm").font(.system(size: 11)).monospacedDigit()
                            .foregroundStyle(Color.white.opacity(0.55))
                        Spacer()
                        Text("解锁 \(high) dBm").font(.system(size: 11)).monospacedDigit()
                            .foregroundStyle(Color.white.opacity(0.92))
                    }
                    Text("越靠右要求越严格，需更近才解锁。")
                        .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
                }
            }
            .frame(width: 340)

            Text("可随时在设置中调整，默认 -60 / -85。")
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.45))
                .lineSpacing(3)
        }
    }
}

// MARK: - 第 5 页 收尾 + Star

struct StarPage: View {
    @State private var shown = false

    private let repo = "https://github.com/ThursdayV50/NearbyPass"

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "star.fill")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.white.opacity(0.92))
                .shadow(color: Color.black.opacity(0.45), radius: 10, y: 2)
                .scaleEffect(shown ? 1 : 0.7)
                .animation(Motion.spring.delay(0.05), value: shown)

            VStack(spacing: 8) {
                Text("准备就绪")
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                Text("接下来勾选信任设备并设置登录密码，即可开始使用。")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
            }

            VStack(spacing: 10) {
                Text("本项目开源，代码托管于 GitHub。\n若对你有帮助，欢迎 Star。")
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.45))
                    .lineSpacing(3)

                Button {
                    if let u = URL(string: repo) { NSWorkspace.shared.open(u) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "star")
                        Text("在 GitHub 上 Star")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.white.opacity(0.10), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Text("github.com/ThursdayV50/NearbyPass")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.28))
            }
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 8)
            .animation(Motion.spring.delay(0.12), value: shown)
        }
        .onAppear { shown = true }
    }
}

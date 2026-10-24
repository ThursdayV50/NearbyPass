// TutorialView.swift — 首次启动的 5 步引导
//
// 不只是"讲一遍"，而是带着把该设的东西设掉：选主设备、调两个阈值、开权限。
// 每一步都能真的动，动完记进设置，用户走完就等于配置完了。

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
    @State private var page = TutorialView.initialPage
    @ObservedObject private var m = AppModel.shared

    /// 调试用：`--tut-page=2` 直接停在某一页，截图方便。
    private static var initialPage: Int {
        for a in CommandLine.arguments where a.hasPrefix("--tut-page=") {
            if let n = Int(a.dropFirst("--tut-page=".count)) { return max(0, min(4, n)) }
        }
        return 0
    }
    var onDone: () -> Void

    private let titles = ["距离场", "选设备", "调强度", "开权限", "启动方式"]

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack {
                switch page {
                case 0: DemoPage()
                case 1: DevicePage()
                case 2: ThresholdPage()
                case 3: PermissionPage()
                default: LaunchPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(Motion.reduced ? .easeInOut(duration: 0.2) : Motion.spring, value: page)
            bottomBar
        }
        .frame(width: 660, height: 500)
        .background(Theme.sheet)
        .onAppear { m.start() }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 10) {
            Text("NearbyPass")
                .font(Theme.text(11, .medium))
                .foregroundStyle(Theme.ink3)
            Text(titles[min(page, titles.count - 1)])
                .font(Theme.text(11, .medium))
                .foregroundStyle(Theme.ink)
            Spacer()
            HStack(spacing: 5) {
                ForEach(0 ..< titles.count, id: \.self) { i in
                    Capsule()
                        .fill(i == page ? Theme.signal : Theme.hair)
                        .frame(width: i == page ? 16 : 5, height: 5)
                        .animation(Motion.quick, value: page)
                }
            }
            Button("跳过") { onDone() }
                .buttonStyle(.plain)
                .font(Theme.text(11))
                .foregroundStyle(Theme.ink3)
                .padding(.leading, 8)
                .focusEffectDisabled()
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hair2).frame(height: 1)
        }
    }

    // MARK: - 底栏

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if page > 0 {
                Button("上一步") { page -= 1 }
                    .buttonStyle(.plain)
                    .font(Theme.text(11))
                    .foregroundStyle(Theme.ink2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .focusEffectDisabled()
            }
            Spacer()
            Button {
                if page == titles.count - 1 {
                    onDone()
                } else {
                    page += 1
                }
            } label: {
                Text(page == titles.count - 1 ? "开始使用" : "下一步")
                    .font(Theme.text(11.5, .medium))
                    .foregroundStyle(Theme.sheet2)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 7)
                    .background(Theme.ink, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.hair2).frame(height: 1)
        }
    }
}

// MARK: - 01 距离场

private struct DemoPage: View {
    @ObservedObject private var m = AppModel.shared
    @State private var rssi: Int? = -58
    @State private var caption = "手机在口袋里，它知道你在"
    @State private var detail = "信号强过解锁环，屏幕上没有锁"
    @State private var task: Task<Void, Never>?

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            DistanceField(rssi: rssi, unlock: -62, lock: -84,
                          deviceName: m.primaryName.isEmpty ? nil : m.primaryName,
                          present: (rssi ?? -95) >= -84,
                          placeholderName: m.primaryName.isEmpty)
                .frame(width: 296, height: 296)

            VStack(alignment: .leading, spacing: 0) {
                Text("它现在知道你在不在")
                    .font(Theme.text(16, .semibold))
                    .foregroundStyle(Theme.ink)
                    .padding(.bottom, 3)
                Text(caption)
                    .font(Theme.text(11.5, .medium))
                    .foregroundStyle(Theme.signal)
                    .padding(.bottom, 2)
                Text(detail)
                    .font(Theme.text(10.5))
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(height: 46, alignment: .top)

                VStack(alignment: .leading, spacing: 5) {
                    legend(Theme.signal, "解锁环", "信号强于它才能解锁")
                    legend(Theme.signal.opacity(0.45), "锁屏环", "弱于它算离开")
                    legend(Theme.signal.opacity(0.18), "两个环之间", "什么都不做，所以不会在边界抖")
                }
                .padding(.bottom, 8)

                Button("再看一次") { run() }
                    .buttonStyle(.plain)
                    .font(Theme.text(10.5))
                    .foregroundStyle(Theme.ink2)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Theme.sheet2, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hair, lineWidth: 1))
            }
            .frame(maxWidth: 258, alignment: .leading)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { run() }
        .onDisappear { task?.cancel() }
    }

    private func legend(_ c: Color, _ title: String, _ note: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Circle().fill(c).frame(width: 5, height: 5).padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.text(10.5, .medium)).foregroundStyle(Theme.ink2)
                Text(note).font(Theme.text(9.5)).foregroundStyle(Theme.ink3)
            }
        }
    }

    private func run() {
        task?.cancel()
        task = Task { @MainActor in
            while !Task.isCancelled {
                rssi = -58
                caption = "手机在口袋里，它知道你在"
                detail = "信号强过解锁环，屏幕上没有锁"
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                guard !Task.isCancelled else { return }

                rssi = -74
                caption = "你起身走开了"
                detail = "强度掉进两个环之间：不锁，也不解锁，等它继续掉"
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                guard !Task.isCancelled else { return }

                rssi = -88
                caption = "越过锁屏环"
                detail = "开始数判定延迟（默认 45 秒），中途信号回来就取消"
                try? await Task.sleep(nanoseconds: 1_700_000_000)
                guard !Task.isCancelled else { return }

                rssi = -93
                caption = "屏幕锁上了"
                detail = "此刻如果它重新出现，就会自动填密码解锁"
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }

                rssi = -78
                caption = "你回来了"
                detail = "回到带内，但还差一点才够到解锁环"
                try? await Task.sleep(nanoseconds: 1_300_000_000)
                guard !Task.isCancelled else { return }

                rssi = -56
                caption = "越过解锁环，自动解锁"
                detail = "不需要确认，也不需要按任何键"
                try? await Task.sleep(nanoseconds: 1_800_000_000)
            }
        }
    }
}

// MARK: - 02 选设备

private struct DevicePage: View {
    @ObservedObject private var m = AppModel.shared

    private var hasPrimary: Bool { !m.primaryName.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head("挑一台随身设备",
                 "手机或手环最合适——它会跟着你走。星标那台是主设备，解锁和锁屏只认它。")

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(m.displayDevices) { d in
                        row(d)
                        Rectangle().fill(Theme.hair2).frame(height: 1)
                    }
                }
            }
            .frame(height: 244)
            .background(Theme.sheet2)
            .overlay(Rectangle().strokeBorder(Theme.hair, lineWidth: 1))

            HStack(spacing: 8) {
                Image(systemName: hasPrimary ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.system(size: 11))
                    .foregroundStyle(hasPrimary ? Theme.signal : Theme.ink3)
                Text(hasPrimary ? "主设备：\(m.primaryName)" : "还没选主设备：点右边的星标")
                    .font(Theme.text(10.5))
                    .foregroundStyle(hasPrimary ? Theme.ink2 : Theme.away)
                Spacer()
                if m.hiddenDeviceCount > 0 {
                    Text("已隐藏 \(m.hiddenDeviceCount) 个")
                        .font(Theme.text(10))
                        .foregroundStyle(Theme.ink3)
                }
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 24)
    }

    private func row(_ d: DeviceVM) -> some View {
        HStack(spacing: 9) {
            Button { m.toggleTrust(d.id) } label: {
                CheckCircle(on: d.trusted)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            Text(d.name)
                .font(Theme.text(11.5))
                .foregroundStyle(d.rssi == nil ? Theme.ink3 : Theme.ink)
                .lineLimit(1)

            if !d.kind.isPresenceCapable {
                Text(d.kind.badge)
                    .font(Theme.text(9))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Theme.hair2, in: Capsule())
                    .foregroundStyle(Theme.ink3)
            }
            Spacer(minLength: 6)
            Text(d.rssi.map { "\($0) dBm" } ?? "未在附近")
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.ink3)
                .frame(width: 72, alignment: .trailing)
            Button { m.setPrimary(d.id) } label: {
                StarMark(on: d.primary).frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - 03 调强度

private struct ThresholdPage: View {
    @ObservedObject private var m = AppModel.shared

    var body: some View {
        HStack(alignment: .center, spacing: 26) {
            DistanceField(rssi: -72,
                          unlock: m.unlockThreshold,
                          lock: m.lockThreshold,
                          deviceName: m.primaryName.isEmpty ? nil : m.primaryName,
                          present: true,
                          placeholderName: m.primaryName.isEmpty)
                .frame(width: 272, height: 272)

            VStack(alignment: .leading, spacing: 0) {
                head("把两个环放到合适的位置",
                     "解锁环越接近你平时的信号强度，解锁越早；两环隔得越开，越不容易在边界反复抖。")

                slider("解锁强度", "强于此值才解锁", value: Binding(
                    get: { m.unlockThreshold },
                    set: { m.setThresholds(low: m.lockThreshold, high: $0) }))

                slider("锁屏强度", "弱于此值算离开", value: Binding(
                    get: { m.lockThreshold },
                    set: { m.setThresholds(low: $0, high: m.unlockThreshold) }))

                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("迟滞区间")
                        .font(Theme.text(10)).foregroundStyle(Theme.ink3)
                    Text("\(abs(m.unlockThreshold - m.lockThreshold)) dB")
                        .font(Theme.mono(10.5, .medium)).foregroundStyle(Theme.ink)
                    Spacer()
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: 278, alignment: .leading)
        }
        .padding(.horizontal, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func slider(_ title: String, _ hint: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(Theme.text(11, .medium)).foregroundStyle(Theme.ink)
                Spacer()
                Text("\(value.wrappedValue) dBm")
                    .font(Theme.mono(10.5, .medium)).foregroundStyle(Theme.signal)
            }
            Text(hint).font(Theme.text(9.5)).foregroundStyle(Theme.ink3)
            Slider(value: Binding(get: { Double(value.wrappedValue) },
                                  set: { value.wrappedValue = Int($0.rounded()) }),
                   in: -95 ... -40, step: 1)
                .controlSize(.mini)
                .tint(Theme.signal)
        }
        .padding(.bottom, 7)
    }
}

// MARK: - 04 权限

private struct PermissionPage: View {
    @ObservedObject private var m = AppModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head("四项检查",
                 "前两项没给，App 就读不到弹窗、也按不了按钮。")

            VStack(spacing: 0) {
                item(m.axTrusted, "辅助功能",
                     "读授权弹窗、填密码、点「好」都靠它",
                     m.axTrusted ? nil : "去授权") { Dialogs.permissionCheck() }
                item(m.bluetoothOn, "蓝牙",
                     "扫描在场设备的广播强度",
                     m.bluetoothOn ? nil : "打开设置") {
                         if let u = URL(string: "x-apple.systempreferences:com.apple.Bluetooth") {
                             NSWorkspace.shared.open(u)
                         }
                     }
                item(m.hasPassword, "登录密码",
                     "存在本机（权限 600），只用于自动填写",
                     m.hasPassword ? nil : "去设置") { SettingsWindow.shared.show() }
                item(m.axTrusted && m.hasPassword, "锁屏界面可读",
                     "锁屏时由 loginwindow 显示密码框，同样走辅助功能",
                     nil) {}
            }

            Text("系统设置 › 隐私与安全性 › 辅助功能，把 NearbyPass 勾上；改动后要重启 App 才生效。")
                .font(Theme.text(10))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
        .padding(.horizontal, 24)
    }

    private func item(_ ok: Bool, _ title: String, _ note: String,
                      _ action: String?, _ run: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12))
                .foregroundStyle(ok ? Theme.signal : Theme.ink3.opacity(0.5))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.text(11.5, .medium)).foregroundStyle(Theme.ink)
                Text(note).font(Theme.text(10)).foregroundStyle(Theme.ink3)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let action {
                Button(action) { run() }
                    .buttonStyle(.plain)
                    .font(Theme.text(10.5))
                    .foregroundStyle(Theme.ink2)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Theme.sheet2, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hair, lineWidth: 1))
                    .focusEffectDisabled()
            }
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hair2).frame(height: 1)
        }
    }
}

// MARK: - 05 启动方式

private struct LaunchPage: View {
    @ObservedObject private var m = AppModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head("登录时自动启动",
                 "开着它，开机后直接驻留菜单栏，不弹任何窗口。")

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("登录时启动 NearbyPass")
                        .font(Theme.text(11.5, .medium)).foregroundStyle(Theme.ink)
                    Text("不占 Dock，只在菜单栏留一个图标")
                        .font(Theme.text(10)).foregroundStyle(Theme.ink3)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { m.launchAtLogin },
                                         set: { m.setLaunchAtLogin($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(Theme.switchOn)
            }
            .padding(.vertical, 9)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.hair2).frame(height: 1)
            }

            if let p = m.loginItemProblem {
                Text("设置失败：\(p)")
                    .font(Theme.text(10))
                    .foregroundStyle(Theme.away)
                    .padding(.top, 7)
            }

            Text("之后它会这样工作")
                .font(Theme.text(11, .medium))
                .foregroundStyle(Theme.ink)
                .padding(.top, 14)
                .padding(.bottom, 6)

            VStack(alignment: .leading, spacing: 5) {
                it("授权弹窗：弹出来的是系统框，确认后由 NearbyPass 填密码")
                it("锁屏解锁：先判「是不是自己锁的」，你主动锁的不会被解")
                it("离开锁屏：判定延迟之内信号回来就取消")
                it("随时从菜单栏暂停全部动作，不用退出")
            }

            Spacer(minLength: 0)

            Text("点「开始使用」会打开设置窗口；之后随时从菜单栏进这个界面。")
                .font(Theme.text(10))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
    }

    private func it(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Circle().fill(Theme.hair).frame(width: 4, height: 4).padding(.top, 5)
            Text(s).font(Theme.text(10)).foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 共用

private func head(_ title: String, _ note: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(title)
            .font(Theme.text(15, .semibold))
            .foregroundStyle(Theme.ink)
        Text(note)
            .font(Theme.text(11))
            .foregroundStyle(Theme.ink3)
            .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.top, 18)
    .padding(.bottom, 12)
}

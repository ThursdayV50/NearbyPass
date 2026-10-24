// SettingsView.swift — SwiftUI 设置界面
//
// 1.2.10 换皮：冷纸底 + 发丝线分组 + 石墨开关 + 琥珀刻度灯。
// 左栏的同心距离场在 1.3.0 单独加，这一版先保证"信息层级"和"控件手感"到位。

import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var m = AppModel.shared

    /// true 时按内容自然高度渲染，仅用于量尺寸；正常显示时为 false，让内容在窗口内滚动
    var measured: Bool = false
    /// 内容的实测总高度。滚动区必须拿到确切高度，否则 SwiftUI 会把内容压到可视高度，滚不动
    var cardsHeight: CGFloat? = nil

    @State private var renameTarget: DeviceVM? = nil
    @State private var renameText = ""
    @State private var showPasswordSheet = false
    @State private var passwordInput = ""

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            behaviorSection
            thresholdSection
            deviceSection
            advancedSection
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 10)
    }

    var body: some View {
        Group {
            if measured {
                content
                    .frame(width: 515)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                normal
            }
        }
    }

    private var normal: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                FieldPane()
                    .frame(width: 344)
                Rectangle().fill(Theme.hair2).frame(width: 1)
                ScrollView(.vertical, showsIndicators: false) {
                    content
                }
            }
            footer
        }
        .frame(width: 860)
        .sheet(item: $renameTarget) { d in
            renameSheet(d)
        }
        .sheet(isPresented: $showPasswordSheet) { passwordSheet }
        .onAppear { m.start() }
    }

    // MARK: - 头部

    private var header: some View {
        let host = HostModel.current
        return HStack(alignment: .center, spacing: 11) {
            Image(systemName: host.kind.symbol)
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(Theme.ink.opacity(0.46))
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text("NearbyPass")
                    .font(Theme.text(14, .semibold))
                    .foregroundStyle(Theme.ink)
                Text("\(host.kind.title) · 设备在场就解锁，离开就锁屏")
                    .font(Theme.text(10.5))
                    .foregroundStyle(Theme.ink3)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                StatusPillLight(text: pillText, dot: m.presenceDot)
                if m.paused {
                    Text("已暂停")
                        .font(Theme.text(10))
                        .foregroundStyle(Theme.away)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hair2).frame(height: 1)
        }
    }

    private var pillText: String {
        guard m.bluetoothOn else { return "蓝牙已关闭" }
        if let r = m.bestRSSI { return "\(m.presenceText) · \(r) dBm" }
        return m.presenceText
    }

    // MARK: - 行为

    private var behaviorSection: some View {
        Section(title: "行为") {
            VStack(alignment: .leading, spacing: 11) {
                InkToggle(title: "授权弹窗出现时，确认后填入密码",
                          subtitle: "系统弹出「输入密码以继续」时，自动填写",
                          isOn: Binding(get: { m.autoFill }, set: { m.setAutoFill($0) }))
                InkToggle(title: "锁屏后自动解锁",
                          subtitle: "主设备在场，且信号强于解锁强度",
                          isOn: Binding(get: { m.autoUnlock }, set: { m.setAutoUnlock($0) }))
                InkToggle(title: "离开后自动锁屏",
                          subtitle: "信号持续弱于锁屏强度，达到下面的延迟就锁屏",
                          isOn: Binding(get: { m.autoLock }, set: { m.setAutoLock($0) }))

                // 判定延迟是「离开后锁屏」的参数，所以挂在它下面，不另开一组
                SubRow {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("判定延迟")
                                .font(Theme.text(11, .medium))
                                .foregroundStyle(Theme.ink2)
                            Spacer(minLength: 8)
                            Text("\(Int(m.delay)) 秒")
                                .font(Theme.mono(10.5, .medium))
                                .foregroundStyle(Theme.ink)
                        }
                        Slider(value: Binding(get: { m.delay }, set: { m.setDelay($0) }),
                               in: 15 ... 300, step: 5)
                            .controlSize(.mini)
                            .tint(Theme.signal)
                        Text("防的是你起身倒水、走到打印机旁边这种短暂离开。")
                            .font(Theme.text(10))
                            .foregroundStyle(Theme.ink3)
                    }
                    .padding(.trailing, 2)
                }
                .opacity(m.autoLock ? 1 : 0.45)
                .allowsHitTesting(m.autoLock)

                InkToggle(title: "登录时自动启动",
                          subtitle: "开机后静默驻留菜单栏，不弹窗口",
                          isOn: Binding(get: { m.launchAtLogin }, set: { m.setLaunchAtLogin($0) }))

                if let problem = m.loginItemProblem {
                    warn("登录项设置失败：\(problem)")
                } else if m.loginItemNeedsApproval {
                    warn("需要在「系统设置 › 通用 › 登录项」里允许 NearbyPass")
                }
            }
        }
    }

    private func warn(_ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
            Text(text).font(Theme.text(10))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.away)
    }

    // MARK: - 阈值

    private var thresholdSection: some View {
        Section(title: "强度阈值", note: "主设备信号") {
            VStack(alignment: .leading, spacing: 12) {
                thresholdRow(
                    title: "解锁强度",
                    hint: "信号强于此值才解锁",
                    value: Binding(get: { m.unlockThreshold },
                                   set: { v in m.setThresholds(low: m.lockThreshold, high: v) })
                )
                thresholdRow(
                    title: "锁屏强度",
                    hint: "弱于此值即算离开",
                    value: Binding(get: { m.lockThreshold },
                                   set: { v in m.setThresholds(low: v, high: m.unlockThreshold) })
                )
                Text("两环之间不触发任何动作，避免在边界来回抖。")
                    .font(Theme.text(10))
                    .foregroundStyle(Theme.ink3)
            }
        }
    }

    private func thresholdRow(title: String, hint: String,
                              value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Theme.text(11.5, .medium)).foregroundStyle(Theme.ink)
                    Text(hint).font(Theme.text(10)).foregroundStyle(Theme.ink3)
                }
                Spacer(minLength: 8)
                Text("\(value.wrappedValue) dBm")
                    .font(Theme.mono(11.5, .medium))
                    .foregroundStyle(Theme.signal)
            }
            Slider(
                value: Binding(get: { Double(value.wrappedValue) },
                               set: { value.wrappedValue = Int($0.rounded()) }),
                in: -95 ... -40, step: 1)
                .controlSize(.mini)
                .tint(Theme.signal)
        }
    }

    // MARK: - 设备

    private var deviceSection: some View {
        Section(title: "设备", note: "星标 = 主设备：解锁和锁屏只认这一台") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Toggle(isOn: Binding(get: { m.wearableOnly },
                                         set: { m.setWearableOnly($0) })) {
                        Text("只看手机 / 手表 / 手环")
                            .font(Theme.text(10.5))
                            .foregroundStyle(Theme.ink2)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Theme.switchOn)
                    Spacer(minLength: 6)
                    if m.hiddenDeviceCount > 0 {
                        Text("已隐藏 \(m.hiddenDeviceCount) 个")
                            .font(Theme.text(10))
                            .foregroundStyle(Theme.ink3)
                    }
                }

                if m.devices.isEmpty {
                    Text(m.hiddenDeviceCount > 0
                         ? "没有随身设备（已隐藏 \(m.hiddenDeviceCount) 个）"
                         : "正在扫描…")
                        .font(Theme.text(11))
                        .foregroundStyle(Theme.ink3)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            ForEach(m.devices) { d in
                                deviceRow(d)
                                Rectangle()
                                    .fill(Theme.hair2)
                                    .frame(height: 1)
                            }
                        }
                    }
                    .frame(height: 185)      // 5 行整，避免切出半行
                }

                if m.primaryIsWeak {
                    warn("主设备不是随身设备，人离开时可能不会自动锁屏")
                }

                HStack(spacing: 8) {
                    Button {
                        m.rescan()
                    } label: {
                        Label("重新扫描", systemImage: "arrow.clockwise")
                            .font(Theme.text(10.5))
                            .foregroundStyle(Theme.ink2)
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    Text(trustedHint)
                        .font(Theme.text(10))
                        .foregroundStyle(Theme.ink3)
                }
                .padding(.top, 2)
            }
        }
    }

    private func deviceRow(_ d: DeviceVM) -> some View {
        HStack(spacing: 9) {
            Button { m.toggleTrust(d.id) } label: {
                CheckCircle(on: d.trusted)
            }
            .buttonStyle(.plain)
            .help(d.trusted ? "勾选：它在附近就算你在场" : "未勾选：忽略这台")

            Text(d.name)
                .font(Theme.text(11.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(d.rssi == nil ? Theme.ink3 : Theme.ink)
                .onTapGesture(count: 2) {
                    renameText = d.name
                    renameTarget = d
                }

            if d.resolving {
                ProgressView().controlSize(.mini).scaleEffect(0.7)
            }

            if !d.kind.isPresenceCapable {
                Text(d.kind.badge)
                    .font(Theme.text(9))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Theme.hair2, in: Capsule())
                    .foregroundStyle(Theme.ink3)
            }

            Spacer(minLength: 6)

            Text(d.rssi.map { "\($0) dBm" } ?? "未在附近")
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.ink3)
                .frame(width: 76, alignment: .trailing)

            Button { m.setPrimary(d.id) } label: {
                StarMark(on: d.primary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(d.primary ? "主设备：解锁和锁屏只认这一台" : "设为主设备：解锁和锁屏只认这一台")
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private var trustedHint: String {
        let shown = m.devices.filter { $0.trusted }.count
        let missing = m.trustedCount - shown
        if missing > 0 { return "已勾选 \(m.trustedCount) 个（\(missing) 个不在附近）" }
        return "已勾选 \(m.trustedCount) 个"
    }

    // MARK: - 高级

    private var advancedSection: some View {
        Section(title: "其它") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text("弹窗冷却").font(Theme.text(11)).foregroundStyle(Theme.ink2)
                        .frame(width: 62, alignment: .leading)
                    Slider(value: Binding(get: { m.cooldown }, set: { m.setCooldown($0) }),
                           in: 3 ... 120, step: 1)
                        .controlSize(.mini)
                        .tint(Theme.signal)
                    Text("\(Int(m.cooldown)) 秒")
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.ink3)
                        .frame(width: 46, alignment: .trailing)
                }
                InkToggle(title: "在菜单栏显示图标",
                          isOn: Binding(get: { m.showInMenuBar },
                                        set: { m.setShowInMenuBar($0) }))
                Text("隐藏后功能照常运行，重新打开 App 即可回到这里。")
                    .font(Theme.text(10))
                    .foregroundStyle(Theme.ink3)
            }
        }
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 8) {
            footButton(m.hasPassword ? "修改密码" : "设置密码", "key") {
                showPasswordSheet = true
            }
            footButton(m.axTrusted ? "权限正常" : "去授权", "checkmark.shield") {
                Dialogs.permissionCheck()
            }
            footButton("日志", "doc.text") {
                Dialogs.openLog()
            }
            Spacer()
            footButton("v\(Updater.currentVersion)", "arrow.triangle.2.circlepath") {
                Updater.shared.checkInteractive()
            }
            footButton(m.paused ? "恢复运行" : "暂停全部",
                       m.paused ? "play" : "pause") {
                m.setPaused(!m.paused)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 13)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.hair2).frame(height: 1)
        }
    }

    private func footButton(_ title: String, _ symbol: String,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(Theme.text(10.5))
                .foregroundStyle(Theme.ink2)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Theme.sheet2, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Theme.hair, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 弹层

    private func renameSheet(_ d: DeviceVM) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("设备名称").font(Theme.text(13, .semibold))
            Text(d.id).font(Theme.mono(9.5)).foregroundStyle(Theme.ink3)
                .lineLimit(1).truncationMode(.middle)
            TextField("例如 我的手机", text: $renameText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { renameTarget = nil }
                Button("保存") {
                    m.rename(d.id, to: renameText)
                    renameTarget = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 340)
    }

    private var passwordSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("设置登录密码").font(Theme.text(13, .semibold))
            Text("存在本机文件里（权限 600），只用于自动填授权弹窗和自动解锁。")
                .font(Theme.text(10.5)).foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("登录密码", text: $passwordInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit { savePassword() }
            HStack {
                Spacer()
                Button("取消") { passwordInput = ""; showPasswordSheet = false }
                Button("保存") { savePassword() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 380)
    }

    private func savePassword() {
        guard !passwordInput.isEmpty else { return }
        if KeychainStore.shared.save(passwordInput) {
            Log.shared.registerSecret(passwordInput)
            Log.info("密码已保存")
            Notifier.post(title: "NearbyPass", body: "密码已保存")
            m.refresh()
        } else {
            Log.error("密码保存失败")
        }
        passwordInput = ""
        showPasswordSheet = false
    }
}

// MARK: - 状态胶囊（浅色版）

struct StatusPillLight: View {
    let text: String
    let dot: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dot)
                .frame(width: 6, height: 6)
            Text(text)
                .font(Theme.mono(10.5, .medium))
                .foregroundStyle(Theme.ink2)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Theme.sheet2, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hair, lineWidth: 1))
    }
}

// MARK: - 窗口背景

struct WindowGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .underWindowBackground
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

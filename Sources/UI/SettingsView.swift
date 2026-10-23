// SettingsView.swift — SwiftUI 设置界面

import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var m = AppModel.shared

    @State private var renameTarget: DeviceVM? = nil
    @State private var renameText = ""
    @State private var showPasswordSheet = false
    @State private var passwordInput = ""
    @State private var showAdvanced = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    signalCard
                    deviceCard
                    thresholdCard
                    behaviorCard
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            }
            footer
        }
        .frame(width: 700)
        .fixedSize(horizontal: false, vertical: true)
        .background(BrandBackground())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .sheet(item: $renameTarget) { d in
            renameSheet(d)
        }
        .sheet(isPresented: $showPasswordSheet) { passwordSheet }
        .onAppear { m.start() }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("NearbyPass")
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                Text("自动解锁 · 自动锁屏 · 授权弹窗填写")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                StatusPill(text: pillText, dot: m.presenceDot)
                if m.paused {
                    Text("已暂停")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var pillText: String {
        guard m.bluetoothOn else { return "蓝牙已关闭" }
        if let r = m.bestRSSI { return "\(m.presenceText) · \(r) dBm" }
        return m.presenceText
    }

    // MARK: - 信号

    private var signalCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(text: "信号强度", note: "最近 60 秒 · 主设备")
                SignalGraph(history: m.history,
                            unlock: m.unlockThreshold,
                            lock: m.lockThreshold)
                    .frame(height: 74)
                HStack(spacing: 14) {
                    legend(color: Color(white: 0.90),
                           text: "达到解锁强度 ≥ \(m.unlockThreshold)")
                    legend(color: Color(white: 0.45),
                           text: "低于锁屏强度 ≤ \(m.lockThreshold)")
                    Spacer()
                    if let r = m.bestRSSI {
                        Text("\(r) dBm")
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(color.opacity(0.8)).frame(width: 12, height: 2)
            Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    // MARK: - 设备

    private var deviceCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                CardTitle(text: "设备", note: "勾选即视为在场 · ★ 为主设备")
                if m.devices.isEmpty {
                    Text("正在扫描…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 22)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 1) {
                            ForEach(m.devices) { d in
                                deviceRow(d)
                            }
                        }
                    }
                    .frame(maxHeight: 224)
                }
                HStack {
                    Button {
                        m.rescan()
                    } label: {
                        Label("重新扫描", systemImage: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    Text(trustedHint)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
        }
    }

    private func deviceRow(_ d: DeviceVM) -> some View {
        HStack(spacing: 9) {
            Button { m.toggleTrust(d.id) } label: {
                Image(systemName: d.trusted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(d.trusted ? Color.primary : Color.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)

            Button { m.setPrimary(d.id) } label: {
                Image(systemName: d.primary ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundStyle(d.primary ? Color.yellow : Color.secondary.opacity(0.45))
            }
            .buttonStyle(.plain)

            Text(d.name)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(d.rssi == nil ? Color.secondary : Color.primary)
                .onTapGesture(count: 2) {
                    renameText = d.name
                    renameTarget = d
                }

            if d.resolving {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }

            Spacer(minLength: 6)

            MiniBars(dbm: d.rssi)
            Text(d.rssi.map { "\($0) dBm" } ?? "未在附近")
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .trailing)
            Text(ageText(d.age))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var trustedHint: String {
        let shown = m.devices.filter { $0.trusted }.count
        let missing = m.trustedCount - shown
        if missing > 0 { return "已勾选 \(m.trustedCount) 个（\(missing) 个不在附近）" }
        return "已勾选 \(m.trustedCount) 个"
    }

    private func ageText(_ age: TimeInterval) -> String {
        if age < 3 { return "刚刚" }
        if age < 60 { return "\(Int(age))s 前" }
        return "\(Int(age / 60))m 前"
    }

    // MARK: - 阈值

    private var thresholdCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(text: "强度阈值", note: "左键拖动 = 更远才触发，右键 = 更近")
                RangeSlider(
                    low: Binding(get: { m.lockThreshold },
                                 set: { v in m.setThresholds(low: v, high: m.unlockThreshold) }),
                    high: Binding(get: { m.unlockThreshold },
                                  set: { v in m.setThresholds(low: m.lockThreshold, high: v) }),
                    onChange: {}
                )
                HStack {
                    Text("锁屏 \(m.lockThreshold) dBm").font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(Color.secondary)
                    Spacer()
                    Text("解锁 \(m.unlockThreshold) dBm").font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(Color.primary.opacity(0.85))
                }
                Text(m.unlockPrediction.text)
                    .font(.system(size: 10.5))
                    .foregroundStyle(m.unlockPrediction.ok ? Color.green : Color.secondary)
            }
        }
    }

    // MARK: - 行为

    private var behaviorCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(text: "行为")
                Toggle("授权弹窗出现时，确认后填入密码", isOn: Binding(
                    get: { m.autoFill }, set: { m.setAutoFill($0) }))
                    .toggleStyle(.switch)
                    .tint(Color(white: 0.62)).font(.system(size: 11.5))
                Toggle("设备在场时自动解锁", isOn: Binding(
                    get: { m.autoUnlock }, set: { m.setAutoUnlock($0) }))
                    .toggleStyle(.switch)
                    .tint(Color(white: 0.62)).font(.system(size: 11.5))
                Toggle("设备离开后自动锁屏", isOn: Binding(
                    get: { m.autoLock }, set: { m.setAutoLock($0) }))
                    .toggleStyle(.switch)
                    .tint(Color(white: 0.62)).font(.system(size: 11.5))

                DisclosureGroup(isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 8) {
                        sliderRow(title: "弹窗冷却", value: "\(Int(m.cooldown)) 秒",
                                  binding: Binding(get: { m.cooldown }, set: { m.setCooldown($0) }),
                                  range: 3 ... 120)
                        sliderRow(title: "离开后延迟", value: "\(Int(m.delay)) 秒",
                                  binding: Binding(get: { m.delay }, set: { m.setDelay($0) }),
                                  range: 15 ... 300)
                        Toggle("在菜单栏显示图标", isOn: Binding(
                            get: { m.showInMenuBar },
                            set: { m.setShowInMenuBar($0) }))
                            .toggleStyle(.switch)
                            .tint(Color(white: 0.62))
                            .font(.system(size: 11.5))
                        Text("隐藏后功能照常运行，重新打开 App 即可回到这里。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                } label: {
                    Text("高级").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func sliderRow(title: String, value: String,
                           binding: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 11)).frame(width: 74, alignment: .leading)
            Slider(value: binding, in: range, step: 1)
            Text(value).font(.system(size: 10.5)).monospacedDigit()
                .frame(width: 52, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                showPasswordSheet = true
            } label: {
                Label(m.hasPassword ? "修改密码" : "设置密码", systemImage: "key")
            }
            Button {
                Dialogs.permissionCheck()
            } label: {
                Label(m.axTrusted ? "权限正常" : "去授权", systemImage: "checkmark.shield")
            }
            Button {
                Dialogs.openLog()
            } label: {
                Label("日志", systemImage: "doc.text")
            }
            Spacer()
            Button {
                Updater.shared.checkInteractive()
            } label: {
                Label("v\(Updater.currentVersion)", systemImage: "arrow.triangle.2.circlepath")
            }
            .help("检查更新")
            Button {
                m.setPaused(!m.paused)
            } label: {
                Label(m.paused ? "恢复运行" : "暂停全部", systemImage: m.paused ? "play" : "pause")
            }
        }
        .font(.system(size: 11))
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - 弹层

    private func renameSheet(_ d: DeviceVM) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("设备名称").font(.system(size: 13, weight: .semibold))
            Text(d.id).font(.system(size: 9.5)).foregroundStyle(.tertiary)
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
            Text("设置登录密码").font(.system(size: 13, weight: .semibold))
            Text("存在本机文件里（权限 600），只用于自动填授权弹窗和自动解锁。")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
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

import CoreBluetooth
import SwiftUI

struct DeviceDiscoveryView: View {
    @ObservedObject var model: AppModel
    var visibleRows = 4
    var onRename: ((DeviceVM) -> Void)? = nil

    private let rowHeight: CGFloat = 44
    private let panelShape = RoundedRectangle(cornerRadius: 8)

    var body: some View {
        let devices = model.displayDevices
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Theme.hair).frame(height: 1)

            if devices.isEmpty {
                emptyState
                    .frame(minHeight: rowHeight * 2.5)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(devices) { device in
                            deviceRow(device)
                                .frame(height: rowHeight)
                                .overlay(alignment: .bottom) {
                                    if device.id != devices.last?.id {
                                        Rectangle().fill(Theme.hair2).frame(height: 1)
                                    }
                                }
                        }
                    }
                }
                .frame(height: CGFloat(min(visibleRows, devices.count)) * rowHeight)
            }
        }
        .background(Theme.sheet2, in: panelShape)
        .clipShape(panelShape)
        .overlay { panelShape.strokeBorder(Theme.hair).allowsHitTesting(false) }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("设备筛选", selection: Binding(
                get: { model.wearableOnly }, set: { model.setWearableOnly($0) }
            )) {
                Text("随身").tag(true)
                Text("全部").tag(false)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .fixedSize()
            .help("随身显示手机、手表和手环。全部也显示未分类设备。")

            if model.hiddenDeviceCount > 0 {
                Text("\(model.hiddenDeviceCount) 台已隐藏")
                    .font(Theme.text(11).monospacedDigit())
                    .foregroundStyle(Theme.ink2)
            }

            Spacer(minLength: 4)

            Button { model.rescan() } label: {
                Label("重新扫描", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .font(Theme.text(11, .medium))
            .disabled(!model.bluetoothOn)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        let title = model.bluetoothStatusText ?? (model.hiddenDeviceCount > 0
            ? "尚未识别到随身设备" : "等待附近设备广播")
        return VStack(spacing: 6) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(model.bluetoothOn ? Theme.signal : Theme.ink2)
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.text(12, .semibold))
                .foregroundStyle(Theme.ink)
            if model.bluetoothState == .unauthorized {
                emptyHint("在「系统设置 → 隐私与安全性 → 蓝牙」允许 NearbyPass。")
            } else if model.hiddenDeviceCount > 0 && model.bluetoothOn {
                emptyHint("切到「全部」查看未分类设备及最近广播时间。")
            } else if model.bluetoothOn {
                emptyHint("把手机或手环靠近 Mac，并点亮设备屏幕。")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(Theme.text(11))
            .foregroundStyle(Theme.ink2)
            .multilineTextAlignment(.center)
    }

    private func deviceRow(_ device: DeviceVM) -> some View {
        HStack(spacing: 4) {
            Button { model.toggleTrust(device.id) } label: {
                CheckCircle(on: device.trusted)
                    .frame(width: 40, height: rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(device.trusted ? "取消信任 \(device.name)" : "信任 \(device.name)")
            .help(device.trusted ? "从在场判断中移除" : "将这台设备加入在场判断")

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(Theme.text(12, device.primary ? .semibold : .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .onTapGesture(count: 2) { onRename?(device) }
                if device.resolving {
                    Text("正在读取设备名称")
                        .font(Theme.text(10))
                        .foregroundStyle(Theme.ink2)
                } else if device.primary || !device.kind.isPresenceCapable {
                    Text(device.primary ? "解锁主设备" : device.kind.badge)
                        .font(Theme.text(10))
                        .foregroundStyle(device.primary ? Theme.signal : Theme.ink2)
                }
            }

            Spacer(minLength: 8)

            if let onRename {
                Button { onRename(device) } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink2)
                        .frame(width: 36, height: rowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("重命名 \(device.name)")
                .help("重命名")
            }

            signalReading(device)

            Button { model.setPrimary(device.id) } label: {
                StarMark(on: device.primary)
                    .frame(width: 40, height: rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(device.primary ? "\(device.name) 是主设备" : "将 \(device.name) 设为主设备")
            .help(device.primary ? "这台设备可以触发自动解锁" : "设为触发自动解锁的主设备")
        }
        .padding(.horizontal, 4)
        .background(device.primary ? Theme.signalSoft.opacity(0.35) : Color.clear)
    }

    private func signalReading(_ device: DeviceVM) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "wave.3.right")
                    .font(.system(size: 9, weight: .medium))
                    .accessibilityHidden(true)
                Text(device.rssi.map { "\($0) dBm" } ?? "—")
                    .font(Theme.mono(11, .medium))
            }
            .foregroundStyle(device.hasRecentBroadcast ? Theme.signal : Theme.ink2)
            Text(device.broadcastAgeText)
                .font(Theme.text(10).monospacedDigit())
                .foregroundStyle(Theme.ink2)
        }
        .frame(minWidth: 72, alignment: .trailing)
        .help("信号强度和上次收到 BLE 广播的时间")
    }
}

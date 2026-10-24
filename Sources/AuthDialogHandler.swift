// AuthDialogHandler.swift — F1：系统授权弹窗出现时自动填密码
//
// Phase 0 已验证：
//   · 弹窗进程 = SecurityAgent，主窗 layer=1000，尺寸约 260x322
//   · AX 树完整可读可写：AXTextField + AXSubrole=AXSecureTextField，按钮 desc="好" / "取消"
//   · AX setValue 与 CGEventPost 都能写入，回读为空是正常现象（secure field 不露明文）
//   · 并发授权请求会复用同一进程、窗口坐标完全重合 → 按 window number 去重
import Foundation
import CoreGraphics
import ApplicationServices

final class AuthDialogHandler {

    static let shared = AuthDialogHandler()

    private struct Win {
        let pid: pid_t
        let bounds: CGRect
        let number: Int
    }

    private var timer: Timer?
    private var handled: Set<Int> = []
    private var lastSubmit: [Int: Date] = [:]
    /// 已经提示过「设备不在附近」的窗口，避免每 0.4 秒刷一条日志
    private var warnedNotNearby: Set<Int> = []
    private var cooldownUntil: Date?
    private var busy = false
    private var reportedOwners: Set<String> = []

    private init() {}

    func start() {
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Log.info("授权弹窗监听已启用（冷却 \(Int(Settings.shared.authCooldown)) 秒）")
    }

    // MARK: - 轮询

    private func tick() {
        let s = Settings.shared
        guard s.authFillEnabled, !s.paused else { return }
        guard SessionMonitor.shared.state == .unlocked else { return }
        guard !busy else { return }
        if let c = cooldownUntil, Date() < c { return }

        let windows = authMainWindows()
        let live = Set(windows.map { $0.number })
        handled = handled.intersection(live)
        warnedNotNearby = warnedNotNearby.intersection(live)

        guard let fresh = windows.first(where: { !handled.contains($0.number) }) else { return }

        // 顺序很重要：presence 不满足时**不能**标记 handled，
        // 否则 App 恰好在启动瞬间（蓝牙还没扫到任何设备，状态是「未知」）
        // 碰上弹窗，这个弹窗就被永久放弃，等设备靠近也不会再填。
        let presence = PresenceMonitor.shared.presence
        guard presence == .present else {
            if !warnedNotNearby.contains(fresh.number) {
                warnedNotNearby.insert(fresh.number)
                Log.info("检测到授权弹窗，但设备不在附近（\(presence.rawValue)），等设备靠近再填")
            }
            return
        }
        guard KeychainStore.shared.hasPassword() else {
            handled.insert(fresh.number)
            Log.warn("检测到授权弹窗，但还没设置密码")
            return
        }
        handled.insert(fresh.number)

        let size = "\(Int(fresh.bounds.width))x\(Int(fresh.bounds.height))"
        Log.info("检测到授权弹窗（\(size)），准备确认后填写")

        let primaryID = Settings.shared.primaryDeviceID ?? ""
        let devName = primaryID.isEmpty
            ? "（未指定设备）"
            : PresenceMonitor.shared.displayName(primaryID)
        var devRSSI = 0
        if !primaryID.isEmpty {
            if let live = PresenceMonitor.shared.liveRSSI(primaryID) {
                devRSSI = live
            } else if let d = PresenceMonitor.shared.device(primaryID) {
                devRSSI = Int(d.emaRSSI.rounded())
            }
        }
        ConfirmPanel.shared.show(device: devName, rssi: devRSSI, anchor: fresh.bounds,
                                 windowNumber: fresh.number) { [weak self] in
            self?.fill(pid: fresh.pid, windowNumber: fresh.number)
        }
    }

    /// 系统认证弹窗的宿主进程白名单。
    /// - `SecurityAgent`：Authorization Services 路径（`do shell script with administrator privileges`、
    ///   各类 `AuthorizationCopyRights` 请求）
    /// - `coreautha`：LocalAuthenticationUI 路径（`LAContext.evaluatePolicy`；
    ///   系统设置的「解锁」、Passwords.app 等走这条）
    /// 两者弹窗的 AX 结构一致：AXSecureTextField + 「好」/「取消」。
    /// 认证弹窗上「确认」类按钮的文案。不同宿主、不同场景用的词不一样。
    private static let submitLabels = [
        "好", "修改设置", "解锁", "确定", "继续", "允许",
        "OK", "Unlock", "Modify Settings"
    ]

    private static let authOwnerNames: Set<String> = [
        "SecurityAgent", "coreautha", "coreauthd",
        "系统设置", "System Settings", "隐私与安全", "Privacy & Security",
        "密码", "Passwords"
    ]

    /// 系统常驻浮层，永远不是认证弹窗
    private static let ignoreOwners: Set<String> = [
        "Window Server", "CursorUIViewService", "TextInputSwitcher",
        "Input Source Pro", "Control Center", "Notification Center",
        "Spotlight", "Dock"
    ]

    /// 找出当前屏幕上的「系统认证弹窗」。
    ///
    /// 三条现实约束（都是实测踩出来的）：
    /// 1. 宿主进程不固定：SecurityAgent（Authorization Services）、coreautha
    ///    （LocalAuthenticationUI）之外，系统设置自己也会弹 —— macOS 换版本就可能换人，
    ///    所以只写死进程名必然漏。
    /// 2. **layer 不固定**：SecurityAgent/coreautha 的独立弹窗是 layer=1000+，
    ///    但挂在「系统设置」上的 sheet 实测是 **layer=0**（260x338 @ 616,345）。
    ///    只认 layer>=1000 会永远抓不到后者。
    /// 3. 判据的最终裁判是「AX 树里能不能找到 AXSecureTextField」——
    ///    系统设置主窗口（740x968）里没有 secure field，不会误判。
    private func authMainWindows() -> [Win] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        var out: [Win] = []
        for w in list {
            guard let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let num = (w[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  pid != getpid()
            else { continue }
            let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer >= 0, layer < 100_000 else { continue }

            let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
            let title = (w[kCGWindowName as String] as? String) ?? ""
            if Self.ignoreOwners.contains(owner) { continue }

            var bounds = CGRect.zero
            if let b = w[kCGWindowBounds as String] as? NSDictionary,
               let r = CGRect(dictionaryRepresentation: b as CFDictionary) {
                bounds = r
            }
            // 认证弹窗的实际尺寸区间（SecurityAgent 260x322 / coreautha 260x302 /
            // 系统设置 sheet 260x338），放宽一些留余量
            guard bounds.width >= 200, bounds.width <= 700,
                  bounds.height >= 150, bounds.height <= 800 else { continue }

            // 只认系统认证宿主。绝不因为"某个进程里有密码框"就当成授权弹窗——
            // 浏览器页面里的密码输入框也会命中，那样在网页里打字就会误弹。
            let known = Self.authOwnerNames.contains(owner)
                || Self.authOwnerNames.contains(title)
            guard known else {
                // 只记录一次候选，便于以后发现新的认证宿主；不采取任何动作
                if bounds.width <= 520, bounds.height <= 520,
                   !reportedOwners.contains(owner),
                   !AX.secureFields(pid: pid).isEmpty {
                    reportedOwners.insert(owner)
                    Log.debug("忽略疑似窗口（非认证宿主）: \(owner) \(Int(bounds.width))x\(Int(bounds.height)) layer=\(layer)")
                }
                continue
            }

            // 即便宿主在白名单里，也要求窗口里确实有密码框，避免把启动瞬间的空窗口当真
            guard !AX.secureFields(pid: pid).isEmpty else { continue }
            out.append(Win(pid: pid, bounds: bounds, number: num))
        }
        return out
    }

    // MARK: - 填写

    private func fill(pid: pid_t, windowNumber: Int) {
        busy = true
        var password = KeychainStore.shared.load() ?? ""

        guard !password.isEmpty else {
            Log.error("密码为空，放弃填写")
            busy = false
            return
        }

        // ① 目标弹窗还在吗？不在说明用户已经自己完成了
        guard Self.windowExists(windowNumber) else {
            Log.info("目标弹窗已消失（你已手动完成），不做任何注入")
            ConfirmPanel.shared.updateStatus("你已完成，未做操作")
            ConfirmPanel.shared.finish(after: 0.9)
            KeychainStore.zeroString(&password)
            busy = false
            handled.insert(windowNumber)
            return
        }

        if findField(pid: pid, deadline: Date().addingTimeInterval(2)) == nil {
            // 可能是 Touch ID 形态，先点「使用密码…」
            if pressUsePassword(pid: pid) {
                usleep(500000)
            }
        }

        guard let field = findField(pid: pid, deadline: Date().addingTimeInterval(3)) else {
            Log.error("授权弹窗中找不到密码框，放弃")
            KeychainStore.zeroString(&password)
            fail(windowNumber: windowNumber, reason: "找不到密码框")
            return
        }

        // ② 密码框里已经有内容 → 用户自己输入了，只帮它点提交，绝不覆盖
        if AX.fieldHasText(field) {
            Log.info("检测到密码框已有内容（你手动输入了），只提交、不覆盖")
            KeychainStore.zeroString(&password)
            submit(pid: pid, windowNumber: windowNumber, userTyped: true)
            return
        }

        // 优先 AX 直接写值：不依赖键盘焦点。
        // 这条弹窗是挂在「系统设置」上的 sheet，焦点不一定在密码框上，
        // 合成键盘事件有可能打到别处（实测就是这个原因导致填不进去）。
        let focusErr = AX.focus(field)
        usleep(60000)
        let setErr = AX.setValue(field, password)
        if setErr != .success {
            if Self.canTypeSafely(pid: pid) {
                Log.warn("AX 写值失败（\(setErr.rawValue)），焦点确认在密码框，改用键盘投递")
                if !Injector.shared.typeText(password, perCharDelayMS: 12) {
                    Log.error("键盘投递也失败")
                }
            } else {
                // 宁可不填，也不能把密码打进别的窗口
                Log.error("AX 写值失败且焦点不在该密码框，放弃键盘投递")
                KeychainStore.zeroString(&password)
                fail(windowNumber: windowNumber, reason: "无法安全写入密码")
                return
            }
        } else {
            Log.debug("AX 写值成功（焦点 err=\(focusErr.rawValue)）")
        }
        KeychainStore.zeroString(&password)
        usleep(250000)

        submit(pid: pid, windowNumber: windowNumber, userTyped: false)
    }

    /// 提交密码。userTyped=true 表示内容是用户自己敲的，我们只按按钮。
    private func submit(pid: pid_t, windowNumber: Int, userTyped: Bool) {
        // 幂等：同一个窗口 3 秒内不重复提交
        let now = Date()
        if let last = lastSubmit[windowNumber], now.timeIntervalSince(last) < 3 {
            Log.info("该弹窗 3 秒内已提交过，跳过重复提交")
            return
        }
        lastSubmit[windowNumber] = now

        ConfirmPanel.shared.updateStatus(userTyped ? "正在提交你输入的内容…" : "正在提交…")

        // 只在目标窗口的 AX 子树里找按钮，避免多窗口时按错
        var buttons: [String] = []
        if let win = AX.authWindow(pid: pid) {
            buttons = AX.buttons(in: win).map { $0.label }
        }
        Log.debug("弹窗按钮: \(buttons.prefix(12).joined(separator: " / "))")

        var pressed: String? = nil
        for label in Self.submitLabels where buttons.contains(label) {
            if AX.pressButton(pid: pid, label: label) { pressed = label; break }
        }
        if let l = pressed {
            Log.info("已点击「\(l)」，等待验证")
        } else if userTyped {
            // 用户输入的内容不代按 Return，避免和他自己的操作打架
            Log.warn("没找到提交按钮，也未按 Return（内容是你输入的）")
        } else {
            Log.warn("没有匹配到提交按钮，改用 Return")
            Injector.shared.pressReturn()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.verify(windowNumber: windowNumber, attempts: 8)
        }
    }

    /// 注入前的安全校验：焦点必须真的在这个弹窗的密码框上
    private static func canTypeSafely(pid: pid_t) -> Bool {
        guard let f = AX.focusedElement() else { return false }
        return AX.pidOf(f) == pid
            && AX.role(f) == "AXTextField"
            && AX.subrole(f) == "AXSecureTextField"
    }

    static func windowExists(_ number: Int) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        return list.contains { ($0[kCGWindowNumber as String] as? Int) == number }
    }

    private func verify(windowNumber: Int, attempts: Int) {
        if !authMainWindows().contains(where: { $0.number == windowNumber }) {
            Log.info("自动填写成功 ✅")
            busy = false
            ConfirmPanel.shared.updateStatus("已填写")
            ConfirmPanel.shared.finish(after: 1.0)
            return
        }
        guard attempts > 0 else {
            Log.error("自动填写失败：弹窗仍在（密码可能不正确）")
            ConfirmPanel.shared.updateStatus("密码可能不正确")
            ConfirmPanel.shared.finish(after: 1.4)
            fail(windowNumber: windowNumber, reason: "密码可能不正确")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.verify(windowNumber: windowNumber, attempts: attempts - 1)
        }
    }

    private func findField(pid: pid_t, deadline: Date) -> AXUIElement? {
        while Date() < deadline {
            let fields = AX.secureFields(pid: pid)
            if let f = fields.first(where: { AX.isFocused($0) }) ?? fields.first {
                return f
            }
            usleep(150000)
        }
        return nil
    }

    /// Touch ID 界面上点「使用密码…」
    private func pressUsePassword(pid: pid_t) -> Bool {
        let candidates = AX.buttons(pid: pid)
        for (el, label) in candidates {
            let l = label.lowercased()
            if l.contains("use password") || l.contains("使用密码") || l.contains("输入密码") {
                Log.info("点击「\(label)」切换到密码输入")
                if AX.press(el) == .success {
                    return true
                }
            }
        }
        return false
    }

    private func fail(windowNumber: Int, reason: String) {
        busy = false
        cooldownUntil = Date().addingTimeInterval(Settings.shared.authCooldown)
        Log.error("授权弹窗填写终止：\(reason)。冷却 \(Int(Settings.shared.authCooldown)) 秒。")
        Notifier.post(title: "自动填写失败", body: reason)
        ConfirmPanel.shared.updateStatus("未能填写")
        ConfirmPanel.shared.finish(after: 1.4)
    }
}

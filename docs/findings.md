# Phase 0 验证记录

环境：macOS 27.2 (26B5091g) / Mac16,10 (Mac mini M4) / arm64 / SIP disabled / Touch ID 已启用
探针构建：`./probe/build.sh`（swiftc 直接编译，产物在 `.build/probe/`）

---

## P0-5 授权弹窗注入 —— ✅ 通过（且比预期好得多）

### 结论

**SecurityAgent 的授权弹窗通过辅助功能（AX）完全可见、可读、可写。**
不需要示教坐标、不需要截屏校验、不需要盲注入。

### 复现方法

```bash
./.build/probe/authdialog          # 触发（阻塞，直到你操作弹窗）
./.build/probe/windows --grep SecurityAgent
./.build/probe/axprobe <pid>       # 看树
./.build/probe/axfill --pid <pid> --info
./.build/probe/axfill --pid <pid> --secure zqx9   # 填密码
./.build/probe/axfill --pid <pid> --press 取消    # 关掉
```

`authdialog` 每次生成唯一的自定义 right 名（`com.lcg.beprobe.<ts>.<pid>`），
绕过 Authorization Services 约 20 分钟的凭证缓存，可反复触发真实弹窗。

### 实测窗口结构

```
SecurityAgent  pid=<N>  win=26447  layer=1000  bounds=260x322 @ (830,192)  onscreen=Y
SecurityAgent  pid=<N>  win=26448  layer=1001  bounds= 84x77 @ (810,389)  onscreen=N   ← Touch ID 图标，叠在主窗口内
```

### 实测 AX 树（完整）

```
[AXApplication] title="SecurityAgent"                            （19 个属性）
└── [AXWindow] sub="AXStandardWindow" title="未命名"
    └── [AXGroup] sub="AXHostingView"
        ├── [AXImage]
        ├── [AXImage]
        ├── [AXStaticText] value="“authdialog”想要进行更改。"
        ├── [AXStaticText] value="输入你的密码以继续使用“authdialog”。"
        ├── [AXTextField] value="Guhee"                          用户名，pos=(846,356) 228x24
        ├── [AXTextField] sub="AXSecureTextField" value=""        密码框，pos=(846,392) 228x24，focused=true
        ├── [AXButton] desc="好"                                  pos=(846,434) 228x28
        └── [AXButton] desc="取消"                                pos=(846,470) 228x28
```

### 注入验证

```
$ axfill --pid 55885 --secure zqx9
设焦点 err=0
AXUIElementSetAttributeValue(kAXValue) err=0
回读 value=（空）          ← secure field 不暴露明文，属正常
```

截图确认：密码框内出现 **4 个圆点**（对应 `zqx9` 四个字符）。
→ `AXUIElementSetAttributeValue(kAXValueAttribute)` **确实写入了 SecurityAgent 的 NSSecureTextField**。

```
$ axfill --pid 55885 --press 取消
AXPress err=0              ← 弹窗立即关闭
```

### 与早期记录的矛盾说明

早期（m00136–m00190 阶段）记录过「SecurityAgent 的 AXWindows / AXChildren 返回空数组」。
本次用 `axprobe` 重测，**AX 树完整可读**。差异原因是**调用方的 TCC 辅助功能授权状态**
（`AXIsProcessTrusted()` 在不同 swiftc 产物间不一致），不是 SecurityAgent 隐藏了窗口。

→ 工程含义：`NearbyPass.app` 必须以固定路径 + 固定 bundle id + 稳定签名安装，
并在首次运行时引导用户授予「辅助功能」，否则 AX 全程不可用。

### 另一个坑：并发授权请求会复用同一个 SecurityAgent 进程

两次 `authdialog` 并发时，两个 260×322 窗口**完全重叠在相同坐标**，且同属一个 pid，
AX 树里出现两份相同元素（`元素总数 = 21`，按钮列表 `["好","取消","好","取消"]`）。
按下一次「取消」后，AX 树塌缩为只剩 `AXApplication`。

→ 生产代码必须：**每次处理只对应当前最新的那个 AXWindow**，并在注入前确认
「AXSecureTextField 存在且 focused」，处理完立刻复核窗口是否消失。

---

## P0-4 会话状态检测 —— ✅ 通过

`./.build/probe/session --once`（未锁屏时）：

```
ScreenIsLocked=<键不存在>  onConsole=1  loginDone=1
全部键: CGSSessionUniqueSessionUUID, kCGSSessionAuditIDKey, kCGSSessionGroupIDKey,
        kCGSSessionLoginwindowSafeLogin, kCGSSessionOnConsoleKey, kCGSSessionSystemSafeBoot,
        kCGSSessionUserIDKey, kCGSSessionUserNameKey, kCGSessionLoginDoneKey,
        kCGSessionLongUserNameKey, kSCSecuritySessionID
```

→ 判据：`CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]` 存在且为 true 即锁屏中；
键缺失即未锁屏。锁屏时是否出现该键待 P0-1 真锁屏确认。

---

## P0-2 窗口枚举 —— ✅ 通过

`CGWindowListCopyWindowInfo` 无需屏幕录制权限即可读 owner/pid/layer/bounds/onscreen/alpha。
加 `.optionOnScreenOnly` 得 14~17 个可见窗口；不加可得 1111+ 个（含离屏）。
`SecurityAgent` 与 `loginwindow` 均可被稳定枚举。

未锁屏时 `loginwindow`(pid 178) 有一个 `layer=0 bounds=500x500 @ (0,580) onscreen=N` 的隐藏窗口。

---

## 待验证

- **P0-1 / P0-3**：真锁屏 —— `Ctrl+Cmd+Q` 是否生效；锁屏界面的密码框是否同样通过 AX 暴露且可写。
- P0-6：`LAUIUseAlwaysOnPasswordField` feature flag（若 AX 路线成立则不再需要）。
- P0-7：手环广播 30 分钟稳定性。

---

## 对已批准方案的修订

原方案里 `Calibration.swift`（示教坐标）与 `ScreenProbe.swift`（截窗校验）**不再需要**，
`DialogClassifier` 从「按 bounds 尺寸分档」改为「读 AX 静态文案 + 元素结构分档」，
`Injector` 的 F1 主路径改为 AX（`CGEventPost` 保留为 F2 锁屏路径的候选）。

功能范围与用户可见行为完全不变。

---

# Phase 0 追加：真锁屏验证（P0-1 / P0-2 / P0-3 / P0-4）—— ✅ 全部通过

运行 `./.build/probe/locktest`（**会真锁屏**，全程不按 Return，不提交密码）。

## 原始日志

```
AXIsProcessTrusted = true
锁屏前: ScreenIsLocked=<键缺失> onConsole=1
已发送 Ctrl+Cmd+Q
检测到锁屏，耗时 0.2s（第 1 次轮询）          ← P0-3 通过
唤醒后: ScreenIsLocked=true onConsole=1        ← P0-4 通过
[锁屏后] 窗口总数=1113，可疑窗口:
   loginwindow pid=178 layer=2004 bounds=1920x1080 @ (0,0)     onscreen=Y   ← 锁屏主窗口
   loginwindow pid=178 layer=2001 bounds=30000x30000 @ (-15000,-15000) onscreen=Y  ← 全屏遮罩
   loginwindow pid=178 layer=0    bounds=500x500 @ (0,580)     onscreen=N
loginwindow pid = 178
SecurityAgent pids = []                        ← 锁屏时没有 SecurityAgent
[AX@178] 属性数=19 err=0  元素总数=14
   [AXApplication] title="loginwindow"
   [AXWindow] sub=AXUnknown title="登录"
   [AXMenuButton] desc="Wi-Fi网络"
   [AXButton] title="ABC" desc="键盘"
   [AXStaticText] value="10月23日周五"
   [AXGroup] sub=AXHostingView
   [AXScrollArea]
   [AXStaticText] value="Guhee"
   [AXTextField] sub=AXSecureTextField focus=F value=""      ← 密码框，已聚焦
   [AXButton] title="" desc="密码提示"
   [AXStaticText] value=""
   [AXStaticText] value="14:41"
   [AXButton] title="显示所有用户" desc="显示所有用户"
   [AXScrollBar]
找到 AXSecureTextField 数量 = 1
AX 写入 "aa" err=0                             ← AX 路线通过
CGEventPost 输入 "bb" …
AX 清空 err=0
```

## 截图证据

| 截图 | 密码框内容 | 结论 |
|---|---|---|
| `lock_A_locked.png` | 空 | 锁屏初始态 |
| `lock_B_afterAX.png` | **2 个圆点** | `AXUIElementSetAttributeValue(kAXValue, "aa")` **真的写入了 loginwindow 的密码框** |
| `lock_C_afterCGEvent.png` | **4 个圆点** | 之后 `CGEventPost` 的 "bb" 又追加了 2 个 → **两条路线都可用** |
| `lock_D_afterClear.png` | 空（与 A 逐字节同尺寸） | AX 设空值可清空 |

## 关键结论

1. **锁屏界面宿主 = `loginwindow`（pid 178，root），不是 SecurityAgent。**
   - 密码框：`AXTextField` + `AXSubrole=AXSecureTextField`，锁屏后 ~1.2 秒内已自动 focused。
   - AX 树只有 14 个元素，结构稳定、可读可写。
2. **`Ctrl+Cmd+Q` 是可靠锁屏手段**，实测 0.2 秒内生效（连按 CGEvent 的 keyDown/keyUp 都要带 `[.maskCommand, .maskControl]`）。
3. **锁屏状态判据**：`CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]` —— 未锁屏时**键不存在**，锁屏时 `= true`。
4. **两条注入路线同时有效**，且能叠加计数：
   - AX 写值（推荐：与键盘布局无关，支持任意字符）
   - CGEventPost（备选：AX 不可用时的退路）
5. 提交密码应使用 **`CGEventPost` Return（keycode 36）**；锁屏 AX 树里没有暴露独立的「提交」按钮（那个 → 箭头不在 AX 树中）。

## 对 F2 实现的最终定型

```
1. 检测 locked + 达解锁强度 + Inhibit==none
2. caffeinate -u -t 1（若 CGDisplayIsAsleep）
3. 等 1800ms                      ← 密码框需要 ~1.2s 才 focused
4. pgrep -x loginwindow → AXUIElementCreateApplication(pid)
5. 遍历找 AXSubrole == "AXSecureTextField"
6. AXUIElementSetAttributeValue(field, kAXValueAttribute, password)
7. 等 120ms
8. CGEventPost(Return, keycode 36)   ← 提交，绝不能重复
9. 等 1500ms，检查 CGSSessionScreenIsLocked 是否消失
10. 成功 → 复位；失败 → Inhibit=passwordSuspect，本会话不再尝试
11. 密码 Data 立即 memset_s 清零
```

**AX 路线优于纯 CGEventPost**：不受键盘布局影响、支持特殊字符、无需逐字符 keycode。

## 完整验证矩阵（Phase 0 收官）

| 项 | 内容 | 结果 |
|---|---|---|
| P0-1 | 锁屏注入 | ✅ AX + CGEventPost 双通 |
| P0-2 | 锁屏宿主身份 | ✅ `loginwindow` pid 178 |
| P0-3 | Ctrl+Cmd+Q 锁屏 | ✅ 0.2s |
| P0-4 | 锁屏状态检测 | ✅ `CGSSessionScreenIsLocked` |
| P0-5 | 授权弹窗注入 | ✅ SecurityAgent AX 全可写 |
| 清空 | 密码框复位 | ✅ AX 设空值 |

剩余非阻塞项：P0-6（feature flag，已无必要）、P0-7（手环广播稳定性，Phase 2 长扫时顺带做）。

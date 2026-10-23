# NearbyPass

蓝牙在场驱动的 macOS 自动化：**人在就解锁，人走就锁屏**。

三个功能：

| 功能 | 说明 |
|---|---|
| **授权弹窗自动填密码** | 修改系统设置等操作弹出「输入密码以允许」时，若手机/手环在附近，右下角浮窗 3 秒倒计时后自动填密码（可点「取消」打断） |
| **锁屏自动解锁** | 锁屏后只要主设备在附近，全自动输入密码解锁，**不需要任何确认** |
| **远离自动锁屏** | 设备信号弱到「锁屏强度」并持续一段时间，自动锁屏 |

---

## 安装

```bash
./build.sh              # 编译 → .build/NearbyPass.app
./build.sh --install    # 编译并安装到 /Applications（若被系统拦截需手动拖）
```

App 是菜单栏程序（`LSUIElement`），没有 Dock 图标。菜单栏显示：

- `🟢 -52` 当前主设备的信号强度
- `🟡` 过渡区　`🔴` 已离开　`⚪️` 蓝牙关闭／未配置　`⏸` 已暂停

---

## 首次使用（三个必做步骤）

### 1. 授予「辅助功能」

系统设置 → 隐私与安全性 → 辅助功能 → 勾选 **NearbyPass**。

这是三个功能的**唯一硬依赖**：填密码、解锁、锁屏都靠合成键盘事件，没有这个权限什么都不会发生。
App 启动时若发现未授权，会自动弹出系统引导。

> 蓝牙权限会在首次启动时由系统弹窗询问，点「允许」即可。

### 2. 勾选信任设备

打开「设置…」，在设备列表里勾选你的手机或手环。

- **勾选** = 这台设备算作「人在」。可以勾多个，任一在场即算人在。
- **★** = 「解锁主设备」。**只有它能触发自动解锁**，请选信号最稳的那台（手机比手环稳）。

设备名如果是 `NGMeCvX2Lpr6xumgxKmaOTmRY` 这种乱码，那是 Android 的随机广播名 ——
点它，用 `5s 前` 判断哪台是你手机，勾上即可。绑定靠的是设备 UUID，和名字无关。

### 3. 设置密码

点「设置密码…」，输入你的**登录密码**。

密码存在系统钥匙串（`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`，只能本机、解锁后可读），
只用于自动填写，永远不会出现在日志、偏好设置或界面上。

---

## 设备列表怎么读

- 设备名优先用系统广播名；广播名是随机串时，会尝试通过 GATT 的 `Device Information` 服务读出真实型号（如 `iPhone18,3 · Apple Inc.`）。读不到就点名字右边的「改」自己命名，名字会记住。
- 信号强度后面的时间戳是**最后一次收到广播**距现在多久。iPhone / Android 的 BLE 广播间隔本来就有 10–20 秒，所以显示「5s 前」是正常的。
- **20 秒**没收到广播：数值变灰并加一个 `·`，表示是最后一次的旧值。
- **60 秒**没收到广播：显示「未在附近」，不再显示 dBm。
- **150 秒**没收到广播且不是信任设备：从列表里直接移除。
- 信任设备即使离开也不会被移除（方便你取消信任），只是显示「未在附近」。

关掉手机蓝牙后，列表上残留的信号值最多再显示 60 秒就会变成「未在附近」——这不是「还在附近」，锁屏判定也只认 60 秒内的广播。

## 双阈值

| 阈值 | 默认 | 含义 |
|---|---|---|
| **解锁强度** | -60 dBm | 信号**强于**此值才允许自动解锁 |
| **锁屏强度** | -85 dBm | 信号**弱于**此值并持续一段时间才自动锁屏 |

滑块左端 = 更远（更弱），右端 = 更近（更强）。两个阈值之间是**过渡区（死区）**：
信号落在这里什么都不做，避免在边界来回抖动。

调整时界面上的预测文案会实时告诉你「此刻若锁屏 → 会自动解锁 ✓ / ✗」。

**调整建议**：先把手机放到你常用的位置，看列表里的实时 dBm，把「解锁强度」设在那个数字略低 3~5 dB 处；
再拿着手机走到你希望触发锁屏的距离，看 dBm，把「锁屏强度」设在那个数字略高处。

---

## 安全设计

- **手动锁屏保护**：如果你主动锁屏时手机就放在桌上，NearbyPass 不会立刻给你解锁
  （锁屏瞬间检测到设备在场 → 判定为「人还在，主动锁屏」）。
  必须等设备**先离开、再回来**才解除这条保护。
- **自动解锁绝不重试**：解锁失败一次就停手并通知你。macOS 连续输错密码会锁定账户。
- **每次锁屏最多尝试一次解锁**。
- **密码用后立即清零**（`memset_s`），日志里的密码串会被替换成 `***`。
- **信号未知时不锁屏**：蓝牙关闭或未配置设备时 `presence = unknown`，绝不会触发锁屏。
- 全部用户态实现：不注入系统进程、不修改 SIP、不使用 root、不替换 SecurityAgent 或 loginwindow 的任何认证逻辑。

---

## 内存占用

| 状态 | 活动监视器「内存」 |
|---|---|
| 只跑在菜单栏（设置窗口关着） | **约 45 MB** |
| 设置窗口打开 | **约 72 MB** |

早期版本设置窗口会吃到 310 MB。根因不是控件、不是 emoji、不是字体缓存，而是
`NSBezierPath(roundedRect:).fill()` 逐根绘制 60 根柱子时，macOS 26 的
CoreGraphics 会走 Metal 光栅化路径，一次性把 Metal 着色器归档（~180 MB）、
系统 Assets.car（~112 MB）私有化进本进程。

改用 60 个 `CALayer`（GPU 合成，不经过 CoreGraphics 逐根填充）后，同样的
外观只花 2 MB。曲线上还顺带修了一个方向 bug：柱高原本按 `base - top` 算，
在 AppKit 的 y 向上坐标系里是负数，导致所有柱子高度都被 clamp 成 1.5 像素。

## 开发

```bash
./build.sh          # 编译
./build.sh --run    # 编译 + 安装 + 启动
```

日志：`~/Library/Logs/NearbyPass/nearbypass.log`（菜单栏「查看日志」直接打开）

### 关于签名（重要）

`.signing/np.keychain` 里有一张自签名证书 `NearbyPass Dev`，`build.sh` 优先用它签名。
这样签出来的是

```
identifier "com.lcg.nearbypass" and certificate leaf = H"77b8..."
```

—— 这个 designated requirement **与二进制内容无关**，所以重新编译不会让系统忘记
你授予过的辅助功能权限。若退回 `codesign --sign -`（ad-hoc），requirement 变成 cdhash，
每次编译都要重新授权。

重建签名身份：

```bash
./.signing/setup.sh
```

### 探针工具

`probe/` 下是 Phase 0 验证用的独立小工具（`./probe/build.sh <name>` 编译）：

| 工具 | 用途 |
|---|---|
| `session` | 打印/监听锁屏状态 |
| `lockkey` | 触发 Ctrl+Cmd+Q 锁屏 |
| `windows` | CGWindowList 窗口枚举 |
| `inject` | 独立键盘注入（hid／pid／private 三种模式） |
| `authdialog` | 触发真实的 SecurityAgent 授权弹窗 |
| `axprobe` / `axfill` | 打印 AX 树 / 往密码框写值 |
| `locktest` | 锁屏注入的综合测试 |

技术验证记录见 `docs/findings.md`。

---

## 应用图标

图标是程序化画出来的，不是位图素材：`Resources/make-icon.swift` 用 CoreGraphics 绘制「深靛蓝圆角方块 + 白色蓝牙符文」，输出 1024×1024 PNG，再经 `sips` + `iconutil` 打成 `Resources/AppIcon.icns`。`build.sh` 会把它拷进 `Contents/Resources/` 并在 `Info.plist` 里写 `CFBundleIconFile`。

改图标就改 `make-icon.swift` 里的颜色/线宽/缩放，然后：

```bash
SWIFT_MODULE_CACHE_PATH=$PWD/.cache CLANG_MODULE_CACHE_PATH=$PWD/.cache \
  swiftc -O -o /tmp/mkicon Resources/make-icon.swift
/tmp/mkicon /tmp/icon.png
# 生成 iconset 后 iconutil -c icns 打包，替换 Resources/AppIcon.icns
./build.sh
```

界面用的是系统磨砂玻璃（`NSVisualEffectView`，`.underWindowBackground` + `.behindWindow`）打底，卡片是在玻璃上叠的半透明色块 + 顶部高光。macOS 27 目前没有公开的 `NSGlassEffectView` API（`NSClassFromString` 查不到），所以这是用系统原生材质模拟的液态玻璃。

## 从源码构建（别人 clone 下来怎么跑）

```bash
git clone <仓库地址> NearbyPass && cd NearbyPass
./build.sh --run
```

`build.sh` 会自动检测 `.signing/np.keychain`：存在就用固定证书签名，不存在就回退 ad-hoc。

**这会影响辅助功能授权**：ad-hoc 签名的 designated requirement 是 `cdhash H"..."`，每次重新编译都会变，因此每次 build 完都要去「系统设置 → 隐私与安全性 → 辅助功能」重新勾选一次。想避免这个麻烦就自己生成一套固定签名身份（`bash .signing/setup.sh` 的写法可以参照，注意 `.signing/` 已被 `.gitignore` 排除，私钥绝不入库）。

首次运行还需要手动完成三件事（辅助功能授权、勾选信任设备、设置密码），见上面的「首次使用」。

## 许可

MIT，见 [LICENSE](LICENSE)。

## 卸载

```bash
launchctl unload ~/Library/LaunchAgents/com.lcg.nearbypass.plist 2>/dev/null
rm -f ~/Library/LaunchAgents/com.lcg.nearbypass.plist
rm -rf /Applications/NearbyPass.app
rm -rf ~/Library/Logs/NearbyPass
rm -rf ~/Library/Application\ Support/NearbyPass
defaults delete com.lcg.nearbypass
security delete-generic-password -s com.lcg.nearbypass
```

---

## 已知限制

- **手环广播不稳定**：小米手环在连着手机时常停止 BLE 广播，作为解锁主设备不如手机可靠。
- **Android 随机广播名**：手机的名字可能每次扫描都不同，绑定靠 UUID，不要靠名字识别。
- **睡眠唤醒**：显示器黑屏时锁屏界面不接收合成键盘事件，NearbyPass 会先 `caffeinate -u` 唤醒再注入。
- **本机 `sleep 0` / `displaysleep 0`**：系统从不休眠，自动锁屏只走 Ctrl+Cmd+Q 路径。

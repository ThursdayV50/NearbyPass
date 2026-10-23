# NearbyPass 1.1 计划

目标：首次启动有教程、界面更简洁、用上液态玻璃、内置自动更新。

## 调研结论

**液态玻璃 API 是有的。** 之前我以为没有，是因为探测脚本写错了。刚才重新验证：本机 macOS 27.2 上 `NSGlassEffectView` 和 `NSGlassEffectContainerView` 都真实存在、可实例化，可访问的属性有 `cornerRadius`、`tintColor`、`contentView`、`style`，另有 `effectIsInteractive` 等一批私有开关。Apple 的用法建议是——玻璃只贴在"浮在顶层的关键控件"上，相邻的多块玻璃要用 container 包起来，否则各自的采样会不一致、看起来像几块脏玻璃。

**动效参考。** Apple 在 WWDC25 的 "Build an AppKit app with the new design" 里讲了新设计的取舍：玻璃克制使用、动效服务于层级变化。业界做法（Figma、Notion、Pitch）一致：教程要短、可跳过、交互式，不要放长视频。

**自动更新。** macOS 标准方案是 Sparkle，但它需要嵌入 framework 加一个 XPC 服务，还要配 EdDSA 密钥和 appcast。我们是 swiftc 手工构建、没有 Xcode 工程，嵌 Sparkle 的代价不小。改自己写一个，逻辑不到 200 行，可控性更好。

## 阶段 1 · 视觉重构（约 2 天）

现在 `SettingsWindow.swift` 1092 行是纯 AppKit 绝对坐标手写，740x926 固定高度，改一处布局要挪几十个 y 值。继续在上面做精细动效会很痛苦。

- 用 SwiftUI 重写设置界面，`NSHostingView` 塞进现有的 NSPanel。swiftc 编 SwiftUI 没问题，不需要 Xcode 工程。
- 卡片改 `.glassEffect()`，相邻玻璃用 `GlassEffectContainer` 包住；窗口本身仍保留 `NSVisualEffectView` 打底。
- 精简结构：顶部只留一个状态胶囊（在场/离开 + 当前 dBm）；设备行去掉 5 格信号条，改成一列细竖条 + 数字；两个阈值滑块合成一个双手柄区间滑块，中间死区直接画成半透明的带子，拖动时实时显示「现在这个位置，锁屏会不会触发」。
- 三个开关收进默认展开的「基础」区，延迟/冷却这类收进折叠的「高级」。
- 深色优先，跟随系统。

## 阶段 2 · 首次启动教程（约 1.5 天）

5 页，480x600 的玻璃卡片，右上角常驻「跳过」。

动效设计：

- 第 1 页 蓝牙涟漪：三个同心圆错开相位向外扩散，3 秒一循环，中间一个静止的蓝牙符文。
- 第 2 页 授权弹窗：迷你密码框逐字输入（模拟，不调真接口），输完密码框收缩成一个绿色勾，旁边浮出确认卡片。
- 第 3 页 解锁演示：手机图标与电脑图标之间跑信号波纹，靠近时电脑屏幕由黑变亮，远离时反过来。
- 第 4 页 阈值：让你直接拖着玩那个双滑块，看到色带跟着变。
- 第 5 页 收尾：项目地址 + 一个「去 GitHub 点个 Star」的按钮（打开 `https://github.com/ThursdayV50/NearbyPass`），下面一行小字「以后再说」。

动效参数统一：弹簧 `response 0.45 / damping 0.8`，元素进场错开 60ms，页面切换用共享元素位移加淡入，尊重系统「减弱动态效果」开关。

## 阶段 3 · 自动更新（约 1.5 天）

不引入 Sparkle，自己实现：

- 启动 10 秒后查一次，之后每 24 小时查一次 `api.github.com/repos/ThursdayV50/NearbyPass/releases/latest`，比对 tag 与 `CFBundleShortVersionString`。
- 有新版：菜单栏图标加角标，设置里出现「发现新版本 1.1.0 · 查看」。
- 点更新后：下载 dmg，先验签（`codesign` 校验 identifier 必须是 `com.lcg.nearbypass`、证书指纹必须是当前那把固定证书），验不过直接丢弃。
- 装上：写一个游离脚本到临时目录，等主进程退出 → `rm -rf /Applications/NearbyPass.app` → `ditto` 新版本 → 重新打开 → 删脚本。运行中的 App 不能替换自己，只能这样绕。
- 设置里加「自动检查更新」开关和「立即检查」按钮。

前提：必须装在 `/Applications`。装在别处就只提示、不下载。

## 阶段 4 · 发布 1.1.0（约 0.5 天）

打 dmg、写 Release notes、更新 README 的界面截图、推送。

## 风险

1. SwiftUI 在没有 Xcode 工程的情况下首次编译通过，有不确定性。所以先花半小时做一次 spike（空 SwiftUI 窗口 + 一个 `NSGlassEffectView`），跑通了再动大改。
2. `NSGlassEffectView` 是 macOS 26+ 的 API，而我们的最低支持版本是 14。需要做版本判断，26 以下回退 `NSVisualEffectView`。
3. 自动更新要覆盖 `/Applications` 里的 App，需要管理员权限。当前账户在 admin 组、目录可写，实测过能 `ditto` 进去，但别的机器上可能弹授权框。

## 需要你定的三件事

1. **设置界面**：完全重写成 SwiftUI（我推荐，动效和玻璃都好做），还是保留现在这套 AppKit 只换皮？
2. **教程**：可以随时跳过，还是第一次必须看完？另外第 2 页演示要不要用真实的授权弹窗（更真实，但会打断你一次），还是纯模拟（我推荐模拟）。
3. **自动更新**：接受「只有装在 /Applications 才生效」这个限制吗？

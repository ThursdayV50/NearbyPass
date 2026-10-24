// Theme.swift — 1.2.10 的视觉基线
//
// 设计取自 docs/redesign/index.html：冷纸底、石墨字、琥珀刻度灯。
// 这里只放"值"，不放布局：布局在 SettingsView 里，距离场在 1.3.0 单独加。

import SwiftUI
import AppKit

enum Theme {

    // MARK: 色

    /// 窗口底：冷纸灰，比纯白低一档，长时间看不刺眼
    static let paper = Color(red: 0.906, green: 0.918, blue: 0.922)      // #E7EAEB
    /// 面板底：稍亮一点，用来和 header / footer 分层
    static let sheet = Color(red: 0.957, green: 0.961, blue: 0.965)      // #F4F5F6
    static let sheet2 = Color(red: 0.984, green: 0.984, blue: 0.988)     // #FBFBFC

    static let ink = Color(red: 0.082, green: 0.098, blue: 0.106)        // #15191B
    static let ink2 = Color(red: 0.298, green: 0.325, blue: 0.349)       // #4C5359
    static let ink3 = Color(red: 0.541, green: 0.569, blue: 0.592)       // #8A9197

    /// 发丝线：深墨 10%，压在浅底上刚好"看得见但不抢"
    static let hair = Color(red: 0.20, green: 0.24, blue: 0.26).opacity(0.11)
    static let hair2 = Color(red: 0.20, green: 0.24, blue: 0.26).opacity(0.055)

    /// 琥珀刻度灯：只给"会变的东西"——阈值、主设备、活数据
    static let signal = Color(red: 0.545, green: 0.369, blue: 0.0)       // #8B5E00
    static let signalSoft = Color(red: 0.604, green: 0.416, blue: 0.0).opacity(0.16)
    /// 离开 / 警告
    static let away = Color(red: 0.643, green: 0.275, blue: 0.184)       // #A4462F

    /// 开关打开时的石墨实心：灰调开关在浅底上开/关几乎没差别，必须给实心
    static let switchOn = Color(red: 0.227, green: 0.255, blue: 0.271)   // #3A4145

    // MARK: 字

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    /// 小标题：全大写 + 拉开字距，比正文低一档存在感
    static func label() -> Font { .system(size: 10, weight: .semibold) }
}

// MARK: - 分组

/// 一个分组：小标题 + 内容，下面一条发丝线。
/// 不用卡片：卡片堆叠会让每一块都像独立的窗口，翻一遍很累。
struct Section<Content: View>: View {
    let title: String
    var note: String? = nil
    var noteIsSignal: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .font(Theme.label())
                    .tracking(0.9)
                    .foregroundStyle(Theme.ink3)
                Spacer(minLength: 8)
                if let note {
                    Text(note)
                        .font(Theme.text(10))
                        .foregroundStyle(noteIsSignal ? Theme.signal : Theme.ink3)
                }
            }
            content()
        }
        .padding(.top, 14)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hair2).frame(height: 1)
        }
    }
}

/// 从属行：挂在上面那个开关底下的参数，靠缩进和一根竖线表达归属
struct SubRow<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(Theme.hair)
                .frame(width: 1)
                .padding(.leading, 4)
                .padding(.vertical, 2)
            content()
                .padding(.leading, 11)
        }
    }
}

// MARK: - 开关

/// 统一开关外观：石墨实心 + 小号
struct InkToggle: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.text(11.5, .medium)).foregroundStyle(Theme.ink)
                if let subtitle {
                    Text(subtitle).font(Theme.text(10)).foregroundStyle(Theme.ink3)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(Theme.switchOn)
    }
}

// MARK: - 勾选

/// 设备行的勾选：空心圆 → 实心黑圆 + 白勾。
/// 用 SF Symbol 的 checkmark.circle.fill 会有个粗白圈，和行高不配，所以自绘。
struct CheckCircle: View {
    let on: Bool
    var size: CGFloat = 15

    var body: some View {
        ZStack {
            Circle()
                .fill(on ? Theme.ink : Color.clear)
            Circle()
                .strokeBorder(on ? Theme.ink : Theme.ink.opacity(0.30), lineWidth: 1.4)
            if on {
                Path { p in
                    p.move(to: CGPoint(x: size * 0.30, y: size * 0.52))
                    p.addLine(to: CGPoint(x: size * 0.44, y: size * 0.66))
                    p.addLine(to: CGPoint(x: size * 0.71, y: size * 0.35))
                }
                .stroke(Theme.sheet, style: StrokeStyle(lineWidth: 1.7,
                                                        lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 星标

/// 五角星。选中时 fill + 同色描边（描边把尖角磨圆），所以看起来是圆润的实心星，
/// 而不是系统 star.fill 那种锐角。
struct StarShape: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.47
        var p = Path()
        for i in 0 ..< 10 {
            let r = i % 2 == 0 ? outer : inner
            let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
            let pt = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

struct StarMark: View {
    let on: Bool
    var size: CGFloat = 15

    var body: some View {
        ZStack {
            if on {
                StarShape().fill(Theme.signal)
            }
            StarShape().stroke(
                on ? Theme.signal : Theme.ink.opacity(0.26),
                style: StrokeStyle(lineWidth: on ? 1.1 : 1.7,
                                   lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 本机机型

/// 从 hw.model 认机型。SF Symbols 里有一套 mac* 线稿图标，风格和这套界面一致，
/// 好过自己画五个 path 还要一个个调比例。
enum HostKind: String {
    case mini, laptop, imac, studio, pro, unknown

    var symbol: String {
        switch self {
        case .mini: return "macmini"
        case .laptop: return "macbook"
        case .imac: return "imac"
        case .studio: return "macstudio"
        case .pro: return "macpro"
        case .unknown: return "desktopcomputer"
        }
    }

    var title: String {
        switch self {
        case .mini: return "Mac mini"
        case .laptop: return "MacBook"
        case .imac: return "iMac"
        case .studio: return "Mac Studio"
        case .pro: return "Mac Pro"
        case .unknown: return "这台 Mac"
        }
    }

    static func from(model: String) -> HostKind {
        if model.hasPrefix("MacBook") { return .laptop }
        if model.hasPrefix("iMac") { return .imac }
        if model.hasPrefix("Macmini") { return .mini }
        if model.hasPrefix("MacPro") { return .pro }
        // Mac13,x / Mac14,x(13|14) 是 Mac Studio；Mac16,10 是 M4 Mac mini
        if model.hasPrefix("Mac13,") || model.hasPrefix("Mac14,13") || model.hasPrefix("Mac14,14") {
            return .studio
        }
        if model == "Mac16,10" { return .mini }
        if model.hasPrefix("Mac16,") { return .mini }
        return .unknown
    }
}

enum HostModel {
    private static var cached: (kind: HostKind, model: String)?

    static var current: (kind: HostKind, model: String) {
        if let cached { return cached }
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = ""
        if size > 0 {
            var buf = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 {
                model = String(cString: buf)
            }
        }
        let r = (HostKind.from(model: model), model)
        cached = r
        return r
    }
}

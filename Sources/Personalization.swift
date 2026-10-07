import Cocoa
import SwiftUI

enum TaskLayout: String, Codable, CaseIterable, Identifiable {
    case grid, list
    var id: String { rawValue }
    var title: String { self == .grid ? "四宫格" : "条式列表" }
    var columns: Int { self == .grid ? 2 : 1 }
}
enum TaskProgressStyle: String, Codable, CaseIterable, Identifiable {
    case bar, ring, segments
    var id: String { rawValue }
    var title: String { [Self.bar: "条形", .ring: "圆环", .segments: "分段"][self]! }
}
enum TaskClickAction: Equatable { case open, select, minimize }
enum TaskOpenMode: String, Codable, CaseIterable, Identifiable {
    case single, double, both, neither
    var id: String { rawValue }
    var title: String {
        switch self {
        case .single: return "单击打开任务"
        case .double: return "双击打开任务"
        case .both: return "单击打开，双击切换任务窗口"
        case .neither: return "右键打开任务"
        }
    }
    var singleClickOpens: Bool {
        get { self == .single || self == .both }
        set { self = Self.mode(single: newValue, double: doubleClickOpens) }
    }
    var doubleClickOpens: Bool {
        get { self == .double || self == .both }
        set { self = Self.mode(single: singleClickOpens, double: newValue) }
    }
    private static func mode(single: Bool, double: Bool) -> Self {
        single ? (double ? .both : .single) : (double ? .double : .neither)
    }
    var help: String { explanation(target: "任务聊天") }
    func explanation(target: String) -> String {
        switch self {
        case .single: return "单击打开\(target)，双击最小化\(target)窗口"
        case .double: return "单击选中任务；双击打开\(target)，已展开时双击最小化"
        case .both: return "单击打开\(target)；双击在打开与最小化之间切换，不重复打开已展开的窗口"
        case .neither: return "单击选中任务，双击最小化\(target)窗口；右键可打开任务"
        }
    }
    func action(clickCount: Int, windowIsOpen: Bool = false) -> TaskClickAction {
        if clickCount == 1 { return singleClickOpens ? .open : .select }
        if clickCount == 2 { return doubleClickOpens && !windowIsOpen ? .open : .minimize }
        return .select
    }
}
struct RGBColor: Codable, Equatable {
    let red: Double
    let green: Double
    let blue: Double
    init(hex: UInt32) {
        red = Double((hex >> 16) & 255) / 255
        green = Double((hex >> 8) & 255) / 255
        blue = Double(hex & 255) / 255
    }
    init(color: Color) {
        let value = NSColor(color).usingColorSpace(.sRGB) ?? .black
        red = min(1, max(0, value.redComponent))
        green = min(1, max(0, value.greenComponent))
        blue = min(1, max(0, value.blueComponent))
    }
    var valid: Bool { [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) } }
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
    var isLight: Bool { 0.2126 * red + 0.7152 * green + 0.0722 * blue > 0.55 }
}
struct PersonalizationSettings: Codable, Equatable {
    var layout: TaskLayout = .grid
    var progressStyle: TaskProgressStyle = .bar
    var openMode: TaskOpenMode = .single
    var background = RGBColor(hex: 0x11141F)
    var backgroundOpacity: Double = 1
    var progress = RGBColor(hex: 0x2DCBE8)
    var completion = RGBColor(hex: 0x29D653)
    var scheme: ColorScheme { background.isLight ? .light : .dark }
    var foreground: Color { background.isLight ? Color(red: 0.08, green: 0.1, blue: 0.15) : .white }
    var cardBackground: Color { foreground.opacity(0.055) }
    var track: Color { foreground.opacity(0.12) }
    var waiting: Color { foreground.opacity(0.5) }
    var floatingBackground: Color { background.color.opacity(backgroundOpacity) }
    func statusColor(_ project: ProjectRow) -> Color {
        project.completed ? completion.color : project.running ? progress.color : project.waiting ? waiting : .orange
    }
    static func load(from preferences: UserDefaults) -> Self {
        guard let data = preferences.data(forKey: "personalization"),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.background.valid, value.progress.valid, value.completion.valid,
              value.backgroundOpacity.isFinite, (0...1).contains(value.backgroundOpacity) else { return Self() }
        return value
    }
    func save(to preferences: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { preferences.set(data, forKey: "personalization") }
    }
}
extension PersonalizationSettings {
    enum CodingKeys: String, CodingKey { case layout, progressStyle, openMode, background, progress, completion, backgroundOpacity }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        layout = try values.decode(TaskLayout.self, forKey: .layout)
        progressStyle = try values.decode(TaskProgressStyle.self, forKey: .progressStyle)
        openMode = try values.decode(TaskOpenMode.self, forKey: .openMode)
        background = try values.decode(RGBColor.self, forKey: .background)
        progress = try values.decode(RGBColor.self, forKey: .progress)
        completion = try values.decode(RGBColor.self, forKey: .completion)
        // Older installations have no opacity key; preserve their saved appearance.
        backgroundOpacity = try values.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 1
    }
}
enum PersonalizationPreset: String, CaseIterable, Identifiable {
    case classic, minimal, violet, paper
    var id: String { rawValue }
    var title: String {
        switch self { case .classic: return "经典四格"; case .minimal: return "简洁条式"; case .violet: return "暮色圆环"; case .paper: return "清爽浅色" }
    }
    var settings: PersonalizationSettings {
        switch self {
        case .classic: return PersonalizationSettings()
        case .minimal: return PersonalizationSettings(layout: .list, background: RGBColor(hex: 0x13221E), progress: RGBColor(hex: 0x54DDB7), completion: RGBColor(hex: 0x93E86C))
        case .violet: return PersonalizationSettings(progressStyle: .ring, background: RGBColor(hex: 0x201A32), progress: RGBColor(hex: 0xC4A7FF), completion: RGBColor(hex: 0x72E3B1))
        case .paper: return PersonalizationSettings(progressStyle: .segments, background: RGBColor(hex: 0xF4F6FA), progress: RGBColor(hex: 0x2779D6), completion: RGBColor(hex: 0x16834D))
        }
    }
    func matches(_ value: PersonalizationSettings) -> Bool {
        var compared = settings; compared.openMode = value.openMode
        return compared == value
    }
}
struct ProgressRing: View {
    var percent: Int
    var label: String
    var color: Color
    var track: Color
    var size: CGFloat = 34
    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: 3)
            Circle().trim(from: 0, to: CGFloat(min(100, max(0, percent))) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
            Text(label).font(.system(size: size < 36 ? 8 : 10, weight: .medium)).monospacedDigit().foregroundColor(color).minimumScaleFactor(0.65).lineLimit(1).padding(3)
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}
struct SegmentedProgressBar: View {
    var percent: Int
    var color: Color
    var track: Color
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<10) { segment in
                GeometryReader { geometry in
                    let fraction = min(1, max(0, Double(percent) / 10 - Double(segment)))
                    RoundedRectangle(cornerRadius: 1).fill(track)
                        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1).fill(color).frame(width: geometry.size.width * fraction) }
                }
            }
        }.frame(height: 6).accessibilityHidden(true)
    }
}
struct TaskCardContent: View {
    let project: ProjectRow
    let settings: PersonalizationSettings
    var height: CGFloat = 84
    var accent: Color { settings.statusColor(project) }
    var hasProgress: Bool { project.running || project.completed }
    var title: some View {
        HStack(alignment: .top, spacing: 3) {
            Text(project.name).font(.system(size: 11, weight: .semibold)).lineLimit(settings.layout == .grid ? 2 : 1)
                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true).help(project.name)
            if project.pinned { Spacer(minLength: 0); Image(systemName: "pin.fill").font(.system(size: 8)).foregroundColor(.orange).help("已固定到任务栏") }
        }
    }
    var phase: some View {
        HStack(spacing: 4) {
            Circle().fill(accent).frame(width: 5, height: 5)
            Text(project.phaseLabel).font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1)
        }
    }
    var remainingText: String {
        if project.completed && !settings.openMode.singleClickOpens {
            if settings.openMode.doubleClickOpens { return project.pinned ? "已固定 · 双击查看" : "双击查看后移除" }
            return project.pinned ? "已固定 · 右键查看" : "右键查看后移除"
        }
        return project.remaining
    }
    var remaining: some View { Text(remainingText).font(.system(size: 8)).foregroundColor(.secondary).lineLimit(1) }
    @ViewBuilder var bar: some View {
        if settings.progressStyle == .segments {
            SegmentedProgressBar(percent: project.percent, color: accent, track: settings.track)
        } else { CompactProgressBar(percent: project.percent, color: accent, track: settings.track) }
    }
    var percent: some View { Text(project.progressLabel).font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundColor(accent).lineLimit(1) }
    var ring: some View { ProgressRing(percent: project.percent, label: hasProgress ? project.progressLabel : "—", color: accent, track: settings.track, size: settings.layout == .list ? 28 : 34) }
    @ViewBuilder var body: some View {
        Group {
            if settings.layout == .list {
                HStack(spacing: 8) {
                    if settings.progressStyle == .ring { ring }
                    VStack(alignment: .leading, spacing: 3) {
                        title
                        if hasProgress && settings.progressStyle != .ring {
                            HStack(spacing: 6) { phase; bar; percent }
                        } else { phase }
                    }
                }.padding(.horizontal, 8).padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    title
                    Spacer(minLength: 0)
                    if settings.progressStyle == .ring {
                        HStack(spacing: 7) { ring; VStack(alignment: .leading, spacing: 4) { phase; remaining }; Spacer(minLength: 0) }
                    } else {
                        phase
                        if hasProgress { HStack(spacing: 6) { bar; percent } }
                        else { Text(project.progressLabel).font(.system(size: 9)).foregroundColor(accent).frame(maxWidth: .infinity).padding(.vertical, 2).background(Capsule().fill(settings.track.opacity(0.5))) }
                        remaining
                    }
                }.padding(8)
            }
        }.frame(maxWidth: .infinity).frame(height: height).foregroundColor(settings.foreground)
    }
}
struct PersonalizationPreview: View {
    let settings: PersonalizationSettings
    var projects: [ProjectRow] {
        var active = TaskRow(id: "preview-active", title: "示例任务", project: "预览", path: "", state: "运行中")
        active.progress.stage = .verify
        let done = TaskRow(id: "preview-done", title: "完成的任务", project: "预览", path: "", state: "本轮结束")
        return [ProjectRow(id: active.id, tasks: [active]), ProjectRow(id: done.id, tasks: [done])]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Image(systemName: "waveform.path.ecg").foregroundColor(settings.progress.color); Text("效果预览").font(.caption); Spacer(); Text("自动保存").font(.caption2).foregroundColor(.secondary) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: settings.layout.columns), spacing: 6) {
                ForEach(projects) { project in
                    TaskCardContent(project: project, settings: settings, height: settings.layout == .list ? 40 : 84)
                        .background(settings.cardBackground).cornerRadius(12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(settings.statusColor(project).opacity(0.25)))
                }
            }
        }.padding(12).background(settings.floatingBackground).cornerRadius(14).preferredColorScheme(settings.scheme)
            .accessibilityElement(children: .ignore).accessibilityLabel("效果预览，" + settings.layout.title + "，" + settings.progressStyle.title + "进度，" + settings.openMode.title)
    }
}
struct PersonalizationView: View {
    @ObservedObject var model: Model
    var close: () -> Void
    func colorBinding(_ path: WritableKeyPath<PersonalizationSettings, RGBColor>) -> Binding<Color> {
        Binding(get: { model.settings[keyPath: path].color }, set: { model.settings[keyPath: path] = RGBColor(color: $0) })
    }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PersonalizationPreview(settings: model.settings)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("个性化方案").font(.headline)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ForEach(PersonalizationPreset.allCases) { preset in
                                Button { model.applyPreset(preset) } label: {
                                    HStack(spacing: 8) {
                                        Circle().fill(preset.settings.progress.color).frame(width: 10, height: 10)
                                        Text(preset.title).font(.system(size: 12))
                                        Spacer(minLength: 0)
                                        Image(systemName: preset.matches(model.settings) ? "checkmark.circle.fill" : "circle").foregroundColor(.secondary)
                                    }.padding(10).frame(maxWidth: .infinity).background(Color.primary.opacity(0.05)).cornerRadius(8)
                                }.buttonStyle(.plain).accessibilityLabel("应用方案：" + preset.title)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("显示样式").font(.headline)
                        Picker("浮窗排列", selection: $model.settings.layout) { ForEach(TaskLayout.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                        Picker("进度样式", selection: $model.settings.progressStyle) { ForEach(TaskProgressStyle.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("颜色").font(.headline)
                        ColorPicker("进行中进度", selection: colorBinding(\.progress), supportsOpacity: false)
                        ColorPicker("完成提示", selection: colorBinding(\.completion), supportsOpacity: false)
                        ColorPicker("界面背景", selection: colorBinding(\.background), supportsOpacity: false)
                        HStack {
                            Text("界面透明度")
                            Slider(value: Binding(get: { 1 - model.settings.backgroundOpacity }, set: { model.settings.backgroundOpacity = 1 - $0 }), in: 0...1)
                                .accessibilityLabel("界面透明度")
                            Text("\(Int(((1 - model.settings.backgroundOpacity) * 100).rounded()))%")
                                .monospacedDigit().frame(width: 40, alignment: .trailing)
                        }
                        HStack {
                            Button("不透明") { model.settings.backgroundOpacity = 1 }
                            Button("半透明") { model.settings.backgroundOpacity = 0.5 }
                            Button("透明背景") { model.settings.backgroundOpacity = 0 }
                        }.controlSize(.small)
                        Text("仅调整浮窗和圆球背景，任务文字与进度保持清晰。颜色和透明度会一起保存。")
                            .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("打开任务的方式").font(.headline)
                        Picker("打开位置", selection: $model.chatDestination) { ForEach(TaskChatDestination.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                        Toggle("单击打开任务", isOn: Binding(get: { model.settings.openMode.singleClickOpens }, set: { model.settings.openMode.singleClickOpens = $0 })).toggleStyle(.checkbox)
                        Toggle("双击打开 / 最小化任务", isOn: Binding(get: { model.settings.openMode.doubleClickOpens }, set: { model.settings.openMode.doubleClickOpens = $0 })).toggleStyle(.checkbox)
                        Text(model.taskClickHelp + "。每次只打开所选的一种对话框。")
                            .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                        if model.chatDestination == .codex {
                            Button("辅助功能权限 / 修复") { AppDelegate.shared.showPermissionSettings() }
                        }
                        if model.chatDestination == .builtIn {
                            Picker("最近消息", selection: $model.recentChatCount) { ForEach([5, 10, 20], id: \.self) { Text("最近 \($0) 条").tag($0) } }.pickerStyle(.segmented)
                            Text("仅限制内置窗口显示的消息条数，任务的完整上下文会保留。").font(.caption).foregroundColor(.secondary)
                        }
                    }
                }.padding(20)
            }
            Divider()
            HStack {
                Button("恢复默认") { model.settings = PersonalizationSettings() }
                Spacer()
                Text("即时生效 · 自动保存").font(.caption).foregroundColor(.secondary)
                Button("完成", action: close).keyboardShortcut(.defaultAction)
            }.padding(14)
        }.frame(minWidth: 360, minHeight: 420).preferredColorScheme(model.settings.scheme)
    }
}

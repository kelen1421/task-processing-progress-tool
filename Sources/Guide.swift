import SwiftUI

enum GuideStep: Int, CaseIterable, Identifiable {
    case tasks, progress, pinning, entry, personalization, orb
    var id: Int { rawValue }
    var title: String { ["打开与查看任务", "理解任务进度", "固定任务与查看详情", "新建或进入任务", "调整你的工作台", "缩成进度圆球"][rawValue] }
    var symbol: String { ["square.grid.2x2", "chart.bar", "pin", "plus.bubble", "slider.horizontal.3", "circle"][rawValue] }
    func explanation(mode: TaskOpenMode) -> String {
        switch self {
        case .tasks: return "每个聊天任务占一个位置，进行中的任务优先显示；可按项目筛选，用滚轮上下翻页或点击底部箭头。当前设置：\(mode.help)。"
        case .progress: return "百分比帮助判断当前阶段。有计划时按已完成步骤计算；没有计划时用 ≈ 标注准备、实现、验证、收尾的阶段估计，不表示精确剩余时间。完成任务显示 100%，打开查看后清除提醒。"
        case .pinning: return "右键任务，可固定到任务栏、取消锁定、打开聊天、最小化窗口或查看详情。固定任务会保留，未开始时显示等待中；已完成任务打开后改为等待中，仍保留位置，再次执行后更新进度。"
        case .entry: return "点击空白位置，选择进入已有任务，或填写新任务和项目。四个位置占满时向下滚动，下一页保留空白入口。新建内容会带入聊天输入框，需要在 Codex 中点击发送后才开始执行。菜单栏也有任务入口。"
        case .personalization: return "滑杆按钮打开个性化设置。可选择四宫格或条式列表，条形、圆环或分段进度，颜色与预设方案，以及单击或双击打开任务。预览即时更新，设置自动保存。"
        case .orb: return "右上角减号把工作台旋转聚拢成圆球；拖动标题栏到屏幕任一边缘并松开也会收起。中心是任务数，描边参考进度最快的进行中任务；完成时高亮。点击圆球恢复，拖动可移动；拖动窗口边缘调整大小。开启系统减少动态效果时简化动画。"
        }
    }
}
extension View {
    func guideHighlight(_ active: Bool) -> some View {
        overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(active ? 0.9 : 0), lineWidth: 2).padding(-3).allowsHitTesting(false))
    }
}
struct GuideView: View {
    @ObservedObject var model: Model
    var close: () -> Void
    var step: GuideStep { model.guideStep ?? .tasks }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: step.symbol).font(.system(size: 27)).foregroundColor(model.settings.progress.color)
                    .frame(width: 54, height: 54).background(model.settings.track).cornerRadius(12)
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(step.rawValue + 1) / \(GuideStep.allCases.count)").font(.caption).foregroundColor(.secondary)
                    Text(step.title).font(.headline)
                }
            }
            Text(step.explanation(mode: model.settings.openMode)).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("相关位置已在浮窗中描边提示。可随时关闭，之后点击圆圈问号继续查看。")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Button("上一步") { model.guideStep = GuideStep(rawValue: step.rawValue - 1) }.disabled(step == .tasks)
                Spacer()
                Button("关闭", action: close)
                Button(step == .orb ? "完成" : "下一步") {
                    if step == .orb { close() } else { model.guideStep = GuideStep(rawValue: step.rawValue + 1) }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(minWidth: 320, minHeight: 280).preferredColorScheme(model.settings.scheme)
    }
}

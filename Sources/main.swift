import Cocoa
import SwiftUI
import SQLite3
import ApplicationServices

enum WindowMinimizeResult: Equatable { case minimized, noWindow, needsPermission, failed }
struct PermissionNoticeState {
    private(set) var automaticNoticeShown = false
    mutating func shouldPresent(authorized: Bool, explicitlyRequested: Bool = false) -> Bool {
        if authorized { automaticNoticeShown = false; return explicitlyRequested }
        if explicitlyRequested { automaticNoticeShown = true; return true }
        guard !automaticNoticeShown else { return false }
        automaticNoticeShown = true
        return true
    }
    mutating func observe(authorized: Bool) { if authorized { automaticNoticeShown = false } }
}
final class AccessibilityPermissionStatus: ObservableObject {
    @Published var authorized = false
    let applicationPath: String
    let check: () -> Bool
    init(applicationPath: String = Bundle.main.bundlePath, check: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.applicationPath = applicationPath; self.check = check; refresh()
    }
    func refresh() { authorized = check() }
}
struct AccessibilityPermissionView: View {
    @ObservedObject var status: AccessibilityPermissionStatus
    var restart: () -> Void
    var close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(status.authorized ? "辅助功能权限已生效" : "辅助功能权限尚未生效", systemImage: status.authorized ? "checkmark.circle.fill" : "lock.circle")
                .font(.headline).foregroundColor(status.authorized ? .green : .primary)
            Text(status.authorized ? "可以关闭此窗口，再双击任务方框最小化聊天窗口。" : "系统设置中的开关开启后，这里会自动检测。若开关已开启却仍未生效，请删除旧的同名条目，再点 + 添加下面这份应用并开启权限。")
                .fixedSize(horizontal: false, vertical: true)
            Text("当前运行的应用").font(.caption).foregroundColor(.secondary)
            Text(status.applicationPath).font(.caption).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8).background(Color.secondary.opacity(0.1)).cornerRadius(6)
            HStack {
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: status.applicationPath)]) }
                Button("打开辅助功能设置") { ChatWindowController.openPermissionSettings() }
            }
            Text("已重新添加却仍未生效时，请重启浮窗后重试。任务固定状态和窗口大小会保留。")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("重新检测") { status.refresh() }
                Button("重启浮窗", action: restart)
                Spacer()
                Button("关闭", action: close).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(minWidth: 360, idealWidth: 420, maxWidth: .infinity)
    }
}
struct WindowMinimizeOperation<Window> {
    var authorized: () -> Bool
    var windows: () -> (focused: Window?, main: Window?, all: [Window])
    var available: (Window) -> Bool
    var minimize: (Window) -> Bool
    func run() -> WindowMinimizeResult {
        guard authorized() else { return .needsPermission }
        let source = windows()
        let candidates = [source.focused, source.main].compactMap { $0 } + source.all
        guard let window = candidates.first(where: available) else { return .noWindow }
        return minimize(window) ? .minimized : .failed
    }
}
enum ChatWindowController {
    private static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }
    private static func element(_ owner: AXUIElement, _ name: String) -> AXUIElement? {
        guard let result = value(owner, name), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }
    private static func canMinimize(_ window: AXUIElement) -> Bool {
        guard value(window, kAXRoleAttribute) as? String == kAXWindowRole else { return false }
        if let subrole = value(window, kAXSubroleAttribute) as? String, subrole != kAXStandardWindowSubrole { return false }
        if value(window, kAXMinimizedAttribute) as? Bool == true { return false }
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(window, kAXMinimizedAttribute as CFString, &settable) == .success && settable.boolValue
            || element(window, kAXMinimizeButtonAttribute) != nil
    }
    private static func minimize(_ window: AXUIElement) -> Bool {
        if AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success { return true }
        guard let button = element(window, kAXMinimizeButtonAttribute) else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }
    static func minimizeChatWindow() -> WindowMinimizeResult {
        guard AXIsProcessTrusted() else { return .needsPermission }
        guard let link = URL(string: "codex://threads"),
              let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: link),
              let identifier = Bundle(url: applicationURL)?.bundleIdentifier,
              let application = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first(where: { !$0.isTerminated }) else { return .noWindow }
        let owner = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(owner, 1)
        var result: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(owner, kAXWindowsAttribute as CFString, &result)
        guard error == .success else { return AXIsProcessTrusted() ? .failed : .needsPermission }
        return WindowMinimizeOperation<AXUIElement>(authorized: { AXIsProcessTrusted() }, windows: {
            (element(owner, kAXFocusedWindowAttribute), element(owner, kAXMainWindowAttribute), result as? [AXUIElement] ?? [])
        }, available: canMinimize, minimize: minimize).run()
    }
    static func openPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
}

enum WorkStage: Int {
    case prepare, implement, verify, finish
    var title: String { ["准备", "实现", "验证", "收尾"][rawValue] }
    var estimate: Int { [10, 45, 75, 90][rawValue] }
    var remaining: String { ["后续：实现、验证、收尾", "后续：验证、收尾", "后续：收尾", "等待本轮结束"][rawValue] }
}
struct ProgressEvidence {
    var stage: WorkStage = .prepare
    var reason = "尚未记录到编辑或验证操作"
    mutating func observe(name: String, input: String) {
        if name.contains("apply_patch") {
            stage = .implement; reason = "正在修改文件"; return
        }
        if name == "js", input.contains("getScreenshot") || input.contains("getAXState") {
            stage = .verify; reason = "正在检查实际界面"; return
        }
        guard name.contains("exec") else { return }
        var commands: [String] = []
        if let data = input.data(using: .utf8), let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let command = args["cmd"] as? String {
            commands.append(command)
        } else {
            // Inspect only command arguments, not comments, plans or quoted tool output.
            let regex = try! NSRegularExpression(pattern: #"\bcmd"?\s*:\s*(\"(?:\\.|[^\"\\])*\")"#)
            let ns = input as NSString
            for match in regex.matches(in: input, range: NSRange(location: 0, length: ns.length)) {
                if let d = ns.substring(with: match.range(at: 1)).data(using: .utf8), let command = try? JSONSerialization.jsonObject(with: d, options: .fragmentsAllowed) as? String { commands.append(command) }
            }
            if input.contains("tools.apply_patch(") { stage = .implement; reason = "正在修改文件" }
        }
        for command in commands {
            // Ignore heredoc bodies: writing a test file does not mean the test ran.
            var delimiter: String?
            for rawLine in command.components(separatedBy: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if let end = delimiter { if line == end { delimiter = nil }; continue }
                if let r = line.range(of: #"<<-?\s*['\"]?(\w+)['\"]?"#, options: .regularExpression) {
                    let marker = String(line[r]).replacingOccurrences(of: #"[<\-\s'\"]"#, with: "", options: .regularExpression)
                    delimiter = marker
                }
                let lower = line.lowercased()
                if lower.range(of: #"(^|[;&|\s])(pytest|swiftc|xcrun\s+swiftc|npm\s+(test|run\s+(test|build))|cargo\s+test|go\s+test|.*build\.command)(\s|$)"#, options: .regularExpression) != nil || lower.range(of: #"\bpython3?\s+[^\s]*(tests/|test_|check\.)"#, options: .regularExpression) != nil {
                    stage = .verify; reason = "已开始编译、测试或检查"
                } else if lower.range(of: #"(^|[;&|\s])(cat\s*>|sed\s+-i|apply_patch|mkdir\s|python3?\s+[^\s]*(update|patch|grid))"#, options: .regularExpression) != nil {
                    stage = .implement; reason = "正在创建或修改项目文件"
                }
            }
        }
    }
}
struct TaskRow: Identifiable {
    var id: String
    var title: String
    var project: String
    var path: String
    var projectKey = ""
    var state = "暂无状态"
    var detail = "等待会话记录"
    var steps: [(String, String)] = []
    var progress = ProgressEvidence()
    var completionKey: String?
    var completedAt: Date?
    var updated = Date.distantPast
    var color: Color { state == "运行中" ? .cyan : state == "本轮结束" ? .green : state == "已中断" ? .orange : .gray }
}
struct SidebarProject: Identifiable {
    var id: String
    var name: String
    var path: String
}
struct SidebarCatalog {
    var projects: [SidebarProject] = []
    var assignments: [String: String] = [:]
    var nativeIds: [String: String] = [:]
    init(root: String) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: root + "/.codex-global-state.json")), let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let local = state["local-projects"] as? [String: [String: Any]] ?? [:]
        let order = state["project-order"] as? [String] ?? []
        for id in order + local.keys.filter({ !order.contains($0) }).sorted() {
            guard let entry = local[id], let name = entry["name"] as? String, let paths = entry["rootPaths"] as? [String], let path = paths.first else { continue }
            projects.append(SidebarProject(id: id, name: name, path: path))
        }
        let memberships = state["thread-project-assignments"] as? [String: [String: Any]] ?? [:]
        let projectless = Set(state["projectless-thread-ids"] as? [String] ?? [])
        for (thread, entry) in memberships where !projectless.contains(thread) && entry["projectKind"] as? String == "local" {
            if let id = entry["projectId"] as? String { assignments[thread] = id }
        }
        let mappings = state["app-server-project-id-by-legacy-project-id-by-host"] as? [String: [String: String]] ?? [:]
        for (legacy, native) in mappings["local:" + root] ?? [:] { nativeIds[native] = legacy }
    }
    func project(thread: String, native: String) -> SidebarProject? {
        let id = nativeIds[native] ?? (native.isEmpty ? assignments[thread] : native)
        return projects.first { $0.id == id }
    }
}
struct Snapshot { var rows: [TaskRow]; var error: String?; var projects: [SidebarProject] = [] }
final class Reader {
    let root: String
    private var cache: [String: (offset: UInt64, row: TaskRow)] = [:]
    init(root: String) { self.root = root }
    func read(including pinnedIDs: [String] = []) -> Snapshot {
        var db: OpaquePointer?
        guard sqlite3_open_v2(root + "/state_5.sqlite", &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }
            return Snapshot(rows: [], error: "无法读取 Codex 数据库，请确认已在本机使用 Codex。")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        var stmt: OpaquePointer?
        let catalog = SidebarCatalog(root: root)
        let pinned = Array(Set(pinnedIDs)).sorted()
        let eligible = "archived=0 AND agent_role IS NULL AND source NOT LIKE '%subagent%'"
        let pinnedClause = pinned.isEmpty ? "" : " OR id IN (" + Array(repeating: "?", count: pinned.count).joined(separator: ",") + ")"
        let sql = "SELECT id,COALESCE(NULLIF(name,''),title),cwd,rollout_path,project_id FROM threads WHERE \(eligible) AND (id IN (SELECT id FROM threads WHERE \(eligible) ORDER BY updated_at DESC LIMIT 80)\(pinnedClause)) ORDER BY updated_at DESC"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return Snapshot(rows: [], error: "Codex 数据格式已变化，请更新浮窗工具。") }
        defer { sqlite3_finalize(stmt) }
        for (index, id) in pinned.enumerated() { sqlite3_bind_text(stmt, Int32(index + 1), id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        func str(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
        var rows: [TaskRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row = TaskRow(id: str(0), title: str(1), project: URL(fileURLWithPath: str(2)).lastPathComponent, path: str(2))
            if let project = catalog.project(thread: row.id, native: str(4)) { row.project = project.name; row.projectKey = project.id }
            else if !catalog.projects.isEmpty { row.project = "无项目"; row.projectKey = "projectless" }
            else { row.projectKey = row.path }
            let rolloutPath = str(3)
            if rolloutPath.isEmpty { row.detail = "等待任务开始"; rows.append(row); continue }
            let url = URL(fileURLWithPath: rolloutPath)
            do {
                let f = try FileHandle(forReadingFrom: url); defer { try? f.close() }
                let size = try f.seekToEnd()
                var offset: UInt64 = 0
                if let saved = cache[url.path], saved.offset <= size {
                    let title = row.title, project = row.project, path = row.path, projectKey = row.projectKey
                    row = saved.row; row.title = title; row.project = project; row.path = path; row.projectKey = projectKey
                    offset = saved.offset
                } else {
                    // Locate the current turn once, then consume only appended records.
                    var end = size
                    while end > 0 {
                        let begin = end > 524288 ? end - 524288 : 0
                        try f.seek(toOffset: begin)
                        let chunk = try f.read(upToCount: Int(end - begin)) ?? Data()
                        let text = String(decoding: chunk, as: UTF8.self)
                        let found = text.split(separator: "\n").contains { line in
                            guard line.contains("task_started"), let data = String(line).data(using: .utf8), let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let payload = event["payload"] as? [String: Any] else { return false }
                            return event["type"] as? String == "event_msg" && payload["type"] as? String == "task_started"
                        }
                        offset = begin
                        if found || begin == 0 { break }
                        // Overlap so a lifecycle record crossing a chunk boundary is complete.
                        end = begin + min(UInt64(65536), end - begin - 1)
                    }
                }
                try f.seek(toOffset: offset)
                let data = try f.readToEnd() ?? Data()
                let completeCount = data.lastIndex(of: 10).map { data.distance(from: data.startIndex, to: $0) + 1 } ?? 0
                var lines = String(decoding: data.prefix(completeCount), as: UTF8.self).split(separator: "\n")
                if cache[url.path] == nil && offset > 0 && !lines.isEmpty { lines.removeFirst() }
                for line in lines {
                    guard let d = String(line).data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let p = obj["payload"] as? [String: Any] else { continue }
                    let type = p["type"] as? String ?? ""
                    if obj["type"] as? String == "event_msg" {
                        switch type {
                        case "task_started": row.state = "运行中"; row.detail = "正在处理任务"; row.steps = []; row.progress = ProgressEvidence(); row.completionKey = nil; row.completedAt = nil
                        case "task_complete":
                            row.state = "本轮结束"
                            let stamp = obj["timestamp"] as? String ?? ""
                            row.completionKey = row.id + ":" + (stamp.isEmpty ? String(line) : stamp)
                            let formatter = ISO8601DateFormatter()
                            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                            row.completedAt = formatter.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp)
                        case "turn_aborted", "task_aborted": row.state = "已中断"
                        case "agent_message": if let s = p["message"] as? String { row.detail = s }
                        default: break
                        }
                    }
                    if obj["type"] as? String == "response_item" {
                        if type == "function_call" || type == "custom_tool_call" {
                            row.progress.observe(name: p["name"] as? String ?? "", input: p["input"] as? String ?? p["arguments"] as? String ?? "")
                        }
                        if type == "message", p["role"] as? String == "assistant" {
                            let content = p["content"] as? [[String: Any]] ?? []
                            let s = content.compactMap { $0["text"] as? String }.joined(separator: " ")
                            if !s.isEmpty { row.detail = s }
                            if p["phase"] as? String == "final_answer" || p["phase"] as? String == "final" { row.progress.stage = .finish; row.progress.reason = "正在给出本轮结果" }
                        }
                        if type == "function_call", let name = p["name"] as? String, name.contains("update_plan"), let args = p["arguments"] as? String, let d = args.data(using: .utf8), let a = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let plan = a["plan"] as? [[String: Any]] {
                            row.steps = plan.compactMap { x in guard let s = x["step"] as? String, let status = x["status"] as? String else { return nil }; return (s, status) }
                        }
                    }
                }
                row.updated = (try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
                cache[url.path] = (offset + UInt64(completeCount), row)
            } catch { row.state = "记录不可读"; row.detail = "会话文件暂时不可访问" }
            row.detail = String(row.detail.replacingOccurrences(of: "\n", with: " ").prefix(500))
            rows.append(row)
        }
        return Snapshot(rows: rows, error: nil, projects: catalog.projects)
    }
}
final class Model: ObservableObject {
    @Published var rows: [TaskRow] = []
    @Published var sidebarProjects: [SidebarProject] = []
    @Published var error: String?
    @Published var selected = "全部项目"
    @Published var collapsed = false
    @Published var refreshed = Date()
    @Published var selectedTaskID: String?
    @Published var guideStep: GuideStep?
    @Published var visiblePage = 0
    @Published var chatDestination: TaskChatDestination { didSet { preferences.set(chatDestination.rawValue, forKey: "chatDestination") } }
    @Published var recentChatCount: Int { didSet { preferences.set(recentChatCount, forKey: "recentChatCount") } }
    @Published var settings: PersonalizationSettings { didSet { settings.save(to: preferences) } }
    @Published private var dismissed: Set<String>
    @Published private(set) var pinnedTaskIDs: [String]
    private var busy = false
    let reader: Reader
    let preferences: UserDefaults
    let trackingSince: Date
    init(reader: Reader = Reader(root: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"), preferences: UserDefaults = .standard, now: Date = Date()) {
        self.reader = reader; self.preferences = preferences
        self.settings = PersonalizationSettings.load(from: preferences)
        self.chatDestination = preferences.string(forKey: "chatDestination").flatMap(TaskChatDestination.init(rawValue:)) ?? .builtIn
        let recent = preferences.integer(forKey: "recentChatCount")
        self.recentChatCount = [5, 10, 20].contains(recent) ? recent : 10
        self.collapsed = preferences.bool(forKey: "orbMode")
        self.dismissed = Set(preferences.stringArray(forKey: "dismissedCompletions") ?? [])
        self.pinnedTaskIDs = (preferences.stringArray(forKey: "pinnedTasks") ?? []).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        if let start = preferences.object(forKey: "completionTrackingSince") as? Date { trackingSince = start }
        else { trackingSince = now; preferences.set(now, forKey: "completionTrackingSince") }
    }
    func acknowledge(_ project: ProjectRow) {
        for row in project.tasks { if let key = row.completionKey { dismissed.insert(key) } }
        preferences.set(Array(dismissed), forKey: "dismissedCompletions")
    }
    var taskClickHelp: String {
        let target = chatDestination == .builtIn ? "内置对话" : "Codex 对话"
        return settings.openMode == .single ? "单击打开\(target)，双击最小化\(target)窗口" : "单击选中任务，双击打开\(target)"
    }
    func applyPreset(_ preset: PersonalizationPreset) {
        let mode = settings.openMode
        var updated = preset.settings; updated.openMode = mode
        settings = updated
    }
    func movePage(by direction: Int) {
        let last = TaskPagination.pageCount(visible.count) - 1
        visiblePage = min(last, max(0, min(last, visiblePage) + direction))
    }
    func isPinned(_ id: String) -> Bool { pinnedTaskIDs.contains(id) }
    func togglePin(_ id: String) {
        if isPinned(id) { pinnedTaskIDs.removeAll { $0 == id } }
        else { pinnedTaskIDs.append(id) }
        preferences.set(pinnedTaskIDs, forKey: "pinnedTasks")
    }
    func isPendingCompletion(_ row: TaskRow) -> Bool {
        row.state == "本轮结束" && (row.completedAt ?? .distantPast) >= trackingSince && row.completionKey.map { !dismissed.contains($0) } == true
    }
    var pendingCompletionIDs: Set<String> { Set(rows.filter(isPendingCompletion).map(\.id)) }
    func displayRow(_ row: TaskRow) -> TaskRow {
        guard isPinned(row.id), row.state == "本轮结束", let key = row.completionKey, dismissed.contains(key) else { return row }
        var waiting = row
        waiting.state = "等待中"; waiting.steps = []; waiting.progress = ProgressEvidence()
        waiting.detail = "上一轮已查看，等待新任务开始。"
        return waiting
    }
    func card(for row: TaskRow) -> ProjectRow {
        ProjectRow(id: row.id, tasks: [displayRow(row)], pinned: isPinned(row.id), completionPending: isPendingCompletion(row))
    }
    var projects: [SidebarProject] {
        var result = sidebarProjects
        for row in rows where !result.contains(where: { $0.id == row.projectKey }) {
            result.append(SidebarProject(id: row.projectKey, name: row.project, path: row.path))
        }
        return result
    }
    var visible: [TaskRow] { rows.filter { row in
        return (isPinned(row.id) || row.state == "运行中" || isPendingCompletion(row)) && (selected == "全部项目" || row.projectKey == selected)
    }.sorted { a, b in
        let aPin = pinnedTaskIDs.firstIndex(of: a.id), bPin = pinnedTaskIDs.firstIndex(of: b.id)
        if let aPin = aPin, let bPin = bPin { return aPin < bPin }
        if (aPin != nil) != (bPin != nil) { return aPin != nil }
        if (a.state == "运行中") != (b.state == "运行中") { return a.state == "运行中" }; return a.updated > b.updated
    }.map(displayRow) }
    func refresh() {
        guard !busy else { return }; busy = true
        let pins = pinnedTaskIDs
        DispatchQueue.global(qos: .utility).async { [self] in
            let snap = reader.read(including: pins)
            DispatchQueue.main.async { self.rows = snap.rows; self.sidebarProjects = snap.projects; self.error = snap.error; self.refreshed = Date(); self.busy = false }
        }
    }
}
struct ProjectRow: Identifiable {
    var id: String
    var tasks: [TaskRow]
    var pinned = false
    var completionPending = true
    var name: String { tasks.first.map { $0.title.isEmpty ? "未命名任务" : $0.title } ?? "未命名任务" }
    var running: Bool { tasks.contains { $0.state == "运行中" } }
    var completed: Bool { !tasks.isEmpty && tasks.allSatisfy { $0.state == "本轮结束" } }
    var waiting: Bool { !tasks.isEmpty && tasks.allSatisfy { $0.state == "暂无状态" || $0.state == "等待中" } }
    var statusColor: Color { completed ? .green : running ? .cyan : waiting ? .secondary : .orange }
    var hasPlan: Bool { !tasks.isEmpty && tasks.allSatisfy { !$0.steps.isEmpty } }
    var total: Int { tasks.reduce(0) { $0 + $1.steps.count } }
    var done: Int { tasks.reduce(0) { $0 + $1.steps.filter { $0.1 == "completed" }.count } }
    var evidence: ProgressEvidence { tasks.first?.progress ?? ProgressEvidence() }
    var percent: Int { completed ? 100 : !running ? 0 : hasPlan ? Int(Double(done) / Double(total) * 100) : evidence.stage.estimate }
    var progressLabel: String { running || completed ? "\(hasPlan || completed ? "" : "≈")\(percent)%" : phaseLabel }
    var phaseLabel: String {
        if completed { return "已完成" }
        if waiting { return "等待中" }
        if !running { return tasks.first?.state == "已中断" ? "已中断" : "读取异常" }
        if hasPlan { return tasks.flatMap(\.steps).first { $0.1 == "in_progress" }?.0 ?? (done == total ? "计划已完成" : "按计划推进") }
        return evidence.stage.title + " · 估计"
    }
    var remaining: String {
        if completed { return pinned ? "已固定 · 点击查看" : "点击移除" }
        if waiting { return "开始任务后更新进度" }
        if !running { return tasks.first?.state == "已中断" ? "打开聊天可继续" : "记录暂时不可读" }
        return hasPlan ? "剩余 \(total - done) 个计划步骤" : evidence.stage.remaining
    }
}
struct TaskOrbSummary {
    let tasks: [ProjectRow]
    init(rows: [TaskRow], pendingCompletionIDs: Set<String>? = nil) {
        tasks = rows.map { ProjectRow(id: $0.id, tasks: [$0], completionPending: pendingCompletionIDs?.contains($0.id) ?? true) }
    }
    var taskCount: Int { tasks.count }
    var runningCount: Int { tasks.filter(\.running).count }
    var waitingCount: Int { tasks.filter(\.waiting).count }
    var completedCount: Int { tasks.filter { $0.completed && $0.completionPending }.count }
    var hasCompletion: Bool { completedCount > 0 }
    var reference: ProjectRow? {
        let active = tasks.filter(\.running)
        let pending = tasks.filter { $0.completed && $0.completionPending }
        let candidates = !active.isEmpty ? active : !pending.isEmpty ? pending : waitingCount > 0 ? [] : tasks.filter(\.completed)
        return candidates.max { a, b in
            if a.percent != b.percent { return a.percent < b.percent }
            let aDate = a.tasks.first?.updated ?? .distantPast
            let bDate = b.tasks.first?.updated ?? .distantPast
            if aDate != bDate { return aDate < bDate }
            return a.id < b.id
        }
    }
    var percent: Int { reference?.percent ?? 0 }
    var description: String {
        var text = "\(taskCount) 个任务，\(runningCount) 个进行中，\(waitingCount) 个等待中，\(completedCount) 个完成待查看。"
        if let task = reference {
            text += "参考：\(task.name)，\(task.hasPlan || task.completed ? "" : "≈")\(task.percent)%\(task.hasPlan || task.completed ? "" : "（阶段估计）")。"
        } else if waitingCount > 0 {
            text += "等待任务开始。"
        }
        return text + "点击展开，拖动移动。"
    }
}
struct TaskOrb: View {
    @ObservedObject var model: Model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragFrame: NSRect?
    @State private var dragMouse: NSPoint?
    var summary: TaskOrbSummary { TaskOrbSummary(rows: model.visible, pendingCompletionIDs: model.pendingCompletionIDs) }
    var accent: Color { model.error != nil ? .orange : summary.hasCompletion ? model.settings.completion.color : summary.runningCount > 0 ? model.settings.progress.color : model.settings.waiting }
    var idleCaption: String {
        if model.error != nil { return "读取异常" }
        if summary.runningCount == 0 && summary.waitingCount > 0 { return "等待中" }
        if summary.runningCount == 0 && summary.reference?.completed == true { return "已完成" }
        return "任务"
    }
    var body: some View {
        ZStack {
            Circle().fill(model.settings.floatingBackground)
            Circle().stroke(accent.opacity(summary.hasCompletion ? 0.45 : 0.16), lineWidth: 1)
            if summary.hasCompletion {
                TimelineView(.animation(minimumInterval: 0.1, paused: reduceMotion)) { timeline in
                    let glow = reduceMotion ? 0.65 : 0.5 + 0.25 * sin(timeline.date.timeIntervalSinceReferenceDate * .pi / 1.2)
                    Circle().stroke(model.settings.completion.color.opacity(glow), lineWidth: 1).shadow(color: model.settings.completion.color.opacity(glow), radius: 4)
                }.allowsHitTesting(false)
            }
            Circle().stroke(model.settings.track, lineWidth: 3)
            Circle().trim(from: 0, to: CGFloat(summary.percent) / 100)
                .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.3), value: summary.percent)
            VStack(spacing: 1) {
                Text("\(summary.taskCount)").font(.system(size: 17, weight: .semibold)).monospacedDigit().foregroundColor(model.settings.foreground)
                if summary.hasCompletion {
                    Text("\(summary.completedCount) 已完成").font(.system(size: 7, weight: .medium)).foregroundColor(model.settings.completion.color)
                } else {
                    Text(idleCaption).font(.system(size: 7)).foregroundColor(.secondary)
                }
            }
        }.padding(6).frame(width: 64, height: 64).contentShape(Circle())
            .onTapGesture { AppDelegate.shared.setOrbMode(false) }
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { _ in
                    let mouse = NSEvent.mouseLocation
                    if dragFrame == nil { dragFrame = AppDelegate.shared.panel.frame; dragMouse = mouse }
                    if let frame = dragFrame, let origin = dragMouse { AppDelegate.shared.moveOrb(from: frame, translation: NSSize(width: mouse.x - origin.x, height: mouse.y - origin.y)) }
                }.onEnded { _ in dragFrame = nil; dragMouse = nil })
            .help(model.error ?? summary.description)
            .accessibilityElement(children: .ignore).accessibilityAddTraits(.isButton)
            .accessibilityLabel("ai工作台圆球，" + summary.description)
            .accessibilityAction { AppDelegate.shared.setOrbMode(false) }
            .contextMenu {
                Button("展开任务浮窗") { AppDelegate.shared.setOrbMode(false) }
                Button("新建 / 进入任务") { AppDelegate.shared.showTaskChooser() }
                Button("个性化设置") { AppDelegate.shared.showPersonalization() }
                Button("使用指引") { AppDelegate.shared.showGuide() }
                Button("移回右上角") { AppDelegate.shared.position() }
            }
    }
}
struct CompactProgressBar: View {
    var percent: Int
    var color: Color = .cyan
    var track: Color = .white.opacity(0.09)
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(color).frame(width: geo.size.width * Double(min(100, max(0, percent))) / 100)
            }
        }.frame(height: 6).accessibilityHidden(true)
    }
}
struct ProjectDetails: View {
    var project: ProjectRow
    var settings = PersonalizationSettings()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(project.name).font(.headline)
                Text(project.phaseLabel).font(.subheadline).foregroundColor(settings.statusColor(project))
                if project.running || project.completed { ProgressView(value: Double(project.percent), total: 100).tint(settings.statusColor(project)) }
                Text(project.remaining).font(.caption)
                if project.running {
                    Text(project.hasPlan ? "百分比为已完成计划步骤占比，步骤工作量可能不同。" : "阶段位置估计：准备 10%、实现 45%、验证 75%、收尾 90%。依据：\(project.evidence.reason)。这不是实际工作量完成率；验证后可能返回修改，无法据此预测剩余时间。")
                        .font(.caption2).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(project.tasks) { row in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(row.title.isEmpty ? "未命名任务" : row.title).font(.system(size: 13, weight: .semibold))
                        Text(row.detail).font(.system(size: 12)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                        ForEach(row.steps.indices, id: \.self) { i in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: row.steps[i].1 == "completed" ? "checkmark.circle.fill" : row.steps[i].1 == "in_progress" ? "arrow.triangle.2.circlepath" : "circle").foregroundColor(.cyan)
                                Text(row.steps[i].0)
                            }.font(.caption)
                        }
                        HStack {
                            Text(row.state).foregroundColor(row.color)
                            Spacer()
                            Button("打开聊天") { if let u = URL(string: "codex://threads/" + row.id) { _ = AppDelegate.shared.openTaskChatURL(u) } }
                        }.font(.caption)
                    }
                    Divider()
                }
            }.padding(16)
        }.frame(width: 320, height: 340).background(settings.background.color).preferredColorScheme(settings.scheme)
    }
}
struct TaskPinMenu: View {
    @ObservedObject var model: Model
    let id: String
    var body: some View {
        Button { model.togglePin(id) } label: {
            Label(model.isPinned(id) ? "取消锁定" : "固定到任务栏", systemImage: model.isPinned(id) ? "pin.slash" : "pin")
        }
    }
}
struct ProjectCard: View {
    @ObservedObject var model: Model
    var project: ProjectRow
    var height: CGFloat = 84
    var onDoubleClick: () -> Void = {}
    var openChatURL: (URL) -> Bool = { AppDelegate.shared.openTaskChatURL($0) }
    @State private var showingDetails = false
    @State private var openFailed = false
    var accessibleProgress: String { project.running || project.completed ? project.phaseLabel + "，" + project.progressLabel : project.progressLabel }
    func openChat() {
        guard let id = project.tasks.first?.id, let url = URL(string: "codex://threads/" + id), openChatURL(url) else { openFailed = true; return }
        model.selectedTaskID = project.id
        if project.completed { model.acknowledge(project) }
    }
    func performClick(_ count: Int) {
        switch model.settings.openMode.action(clickCount: count) {
        case .open: openChat()
        case .select: model.selectedTaskID = project.id
        case .minimize: onDoubleClick()
        }
    }
    var body: some View {
            TaskCardContent(project: project, settings: model.settings, height: height)
                .background(model.settings.cardBackground).cornerRadius(14)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(model.selectedTaskID == project.id ? model.settings.progress.color : model.settings.statusColor(project).opacity(0.22), lineWidth: model.selectedTaskID == project.id ? 2 : 1))
                .contentShape(RoundedRectangle(cornerRadius: 14))
            .gesture(TapGesture(count: 2).exclusively(before: TapGesture(count: 1)).onEnded { gesture in
                switch gesture {
                case .first: performClick(2)
                case .second: performClick(1)
                }
            })
            .accessibilityElement(children: .ignore).accessibilityAddTraits(.isButton)
            .accessibilityLabel("\(project.name)，\(project.pinned ? "已锁定，" : "")\(accessibleProgress)，\(project.remaining)，打开聊天")
            .accessibilityAction { openChat() }
            .accessibilityAction(named: Text("最小化聊天窗口")) { onDoubleClick() }
            .help(model.taskClickHelp)
            .contextMenu {
                Button("打开任务聊天") { openChat() }
                TaskPinMenu(model: model, id: project.id)
                Button("最小化聊天窗口") { onDoubleClick() }
                Divider(); Button("查看进度详情") { showingDetails = true }
            }
            .popover(isPresented: $showingDetails, arrowEdge: .leading) { ProjectDetails(project: project, settings: model.settings) }
            .alert("未能打开聊天", isPresented: $openFailed) { Button("确定", role: .cancel) {} } message: { Text("请确认 Codex 已安装。方框会继续保留。") }
    }
}
enum ChatLink {
    static func newTask(prompt: String, path: String?) -> URL? {
        if let path = path {
            var directory: ObjCBool = false
            guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else { return nil }
        }
        var components = URLComponents()
        components.scheme = "codex"; components.host = "threads"; components.path = "/new"
        var items: [URLQueryItem] = []
        if !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { items.append(URLQueryItem(name: "prompt", value: prompt)) }
        if let path = path { items.append(URLQueryItem(name: "path", value: path)) }
        if !items.isEmpty {
            components.queryItems = items
            // URLSearchParams treats a literal plus as a space.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        return components.url
    }
}
struct TaskChooser: View {
    @ObservedObject var model: Model
    var close: () -> Void
    @State private var mode = 0
    @State private var prompt = ""
    @State private var workspace = ""
    @State private var search = ""
    @State private var failure: String?
    var choices: [TaskRow] {
        model.rows.map(model.displayRow).filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.project.localizedCaseInsensitiveContains(search) }.sorted {
            if ($0.state == "运行中") != ($1.state == "运行中") { return $0.state == "运行中" }
            return $0.updated > $1.updated
        }
    }
    var folders: [SidebarProject] {
        var result = model.projects.filter { $0.id != "projectless" }
        if workspace.hasPrefix("/"), !result.contains(where: { $0.id == workspace }) { result.append(SidebarProject(id: workspace, name: URL(fileURLWithPath: workspace).lastPathComponent, path: workspace)) }
        return result
    }
    var selectedPath: String? { folders.first { $0.id == workspace }?.path }
    func chooseFolder() {
        let picker = NSOpenPanel()
        picker.canChooseFiles = false; picker.canChooseDirectories = true; picker.allowsMultipleSelection = false
        picker.prompt = "选择项目"
        if picker.runModal() == .OK, let path = picker.url?.path { workspace = path }
    }
    func create() {
        guard let url = ChatLink.newTask(prompt: prompt, path: workspace.isEmpty ? nil : selectedPath) else { failure = "项目目录不存在，请重新选择。"; return }
        if model.chatDestination == .builtIn {
            AppDelegate.shared.chatController.newTask(prompt: prompt, workspace: workspace.isEmpty ? "" : selectedPath ?? "")
        } else if !AppDelegate.shared.externalChatOpener(url) { failure = "无法打开 Codex，请确认已安装。"; return }
        close()
    }
    func enter(_ row: TaskRow) {
        guard let url = URL(string: "codex://threads/" + row.id), AppDelegate.shared.openTaskChatURL(url) else { failure = "无法打开该聊天。"; return }
        if row.state == "本轮结束" { model.acknowledge(ProjectRow(id: row.id, tasks: [row])) }
        close()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("任务入口", selection: $mode) {
                Text("新建任务").tag(0)
                Text("已有任务").tag(1)
            }.pickerStyle(.segmented)
            if mode == 0 {
                HStack {
                    Picker("项目", selection: $workspace) {
                        Text("不指定项目").tag("")
                        ForEach(folders) { project in Text(project.name).tag(project.id) }
                    }
                    Button { chooseFolder() } label: { Image(systemName: "folder.badge.plus") }.help("选择其他项目文件夹")
                }
                if let path = selectedPath { Text(path).font(.caption2).foregroundColor(.secondary).lineLimit(1).help(path) }
                Text("任务内容").font(.subheadline)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $prompt).font(.system(size: 13)).padding(4)
                    if prompt.isEmpty { Text("描述你想完成的任务…").font(.system(size: 13)).foregroundColor(.secondary).padding(9).allowsHitTesting(false) }
                }.frame(maxHeight: .infinity).background(Color.white.opacity(0.05)).cornerRadius(8)
                Text(model.chatDestination == .builtIn ? "打开后在内置对话框点击发送，开始执行任务。" : "打开后在 Codex 中点击发送，开始执行任务。").font(.caption2).foregroundColor(.secondary)
                HStack { Spacer(); Button("新建并打开") { create() }.buttonStyle(.borderedProminent).tint(.cyan) }
            } else {
                TextField("搜索任务标题或项目", text: $search).textFieldStyle(.roundedBorder)
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(choices) { row in
                            Button { enter(row) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(alignment: .top) {
                                        Text(row.title.isEmpty ? "未命名任务" : row.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                        Spacer(minLength: 0)
                                        if model.isPinned(row.id) { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundColor(.orange) }
                                    }
                                    HStack { Text(row.project); Spacer(); Text(row.state == "暂无状态" ? "等待中" : row.state) }.font(.caption2).foregroundColor(.secondary)
                                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Color.white.opacity(0.05)).cornerRadius(8)
                            }.buttonStyle(.plain).accessibilityLabel("进入任务：" + row.title + (model.isPinned(row.id) ? "，已锁定" : ""))
                                .contextMenu { TaskPinMenu(model: model, id: row.id); Divider(); Button("打开任务") { enter(row) } }
                        }
                        if choices.isEmpty { Text("没有匹配的任务").font(.caption).foregroundColor(.secondary).padding(20) }
                    }
                }
            }
            if let failure = failure { Text(failure).font(.caption).foregroundColor(.orange) }
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity).background(model.settings.background.color).preferredColorScheme(model.settings.scheme)
            .onAppear { if model.selected != "全部项目" && model.selected != "projectless" { workspace = model.selected } }
    }
}
struct EmptyTaskCard: View {
    var height: CGFloat = 84
    var settings = PersonalizationSettings()
    var body: some View {
        Button { AppDelegate.shared.showTaskChooser() } label: {
            Group {
                if settings.layout == .list {
                    HStack(spacing: 6) { Image(systemName: "plus.circle").font(.system(size: 15)); Text("新建 / 进入任务").font(.system(size: 10)) }
                } else {
                    VStack(spacing: 6) { Image(systemName: "plus.circle").font(.system(size: 18)); Text("新建 / 进入任务").font(.system(size: 9)) }
                }
            }.foregroundColor(settings.progress.color.opacity(0.8)).frame(maxWidth: .infinity).frame(height: height)
                .background(settings.cardBackground.opacity(0.5)).cornerRadius(14)
        }.buttonStyle(.plain).accessibilityLabel("新建任务或进入已有任务")
    }
}
struct PanelMoveHandle: ViewModifier {
    @State private var startFrame: NSRect?
    @State private var startMouse: NSPoint?
    func body(content: Content) -> some View {
        content.contentShape(Rectangle()).help("拖动移动，靠屏幕边缘松开后收起")
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { value in
                    if startFrame == nil {
                        startFrame = AppDelegate.shared.panel.frame
                        let mouse = NSEvent.mouseLocation
                        startMouse = NSPoint(x: mouse.x - value.translation.width, y: mouse.y + value.translation.height)
                    }
                    if let frame = startFrame, let mouse = startMouse {
                        let current = NSEvent.mouseLocation
                        AppDelegate.shared.moveProgress(from: frame, translation: NSSize(width: current.x - mouse.x, height: mouse.y - current.y))
                    }
                }
                .onEnded { _ in
                    if startFrame != nil { AppDelegate.shared.endProgressMove() }
                    startFrame = nil; startMouse = nil
                })
    }
}
struct PanelResizeHandle: View {
    var leading = false
    @State private var startFrame: NSRect?
    var body: some View {
        Image(systemName: leading ? "arrow.up.right.and.arrow.down.left" : "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9)).foregroundColor(.secondary)
            .frame(width: 18, height: 18).contentShape(Rectangle())
            .help("拖动调整浮窗大小；也可拖动窗口边缘")
            .accessibilityLabel("拖动调整浮窗大小")
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if startFrame == nil { startFrame = AppDelegate.shared.panel.frame }
                    if let frame = startFrame { AppDelegate.shared.resizeProgress(from: frame, translation: value.translation, leading: leading) }
                }
                .onEnded { _ in startFrame = nil; AppDelegate.shared.endHandleResize() })
    }
}
struct Dashboard: View {
    @ObservedObject var model: Model
    var onMinimize: () -> Void = { AppDelegate.shared.minimizeChatWindow() }
    var openChatURL: (URL) -> Bool = { AppDelegate.shared.openTaskChatURL($0) }
    var projects: [ProjectRow] { model.visible.map { model.card(for: $0) } }
    var pages: Int { TaskPagination.pageCount(projects.count) }
    var currentPage: Int { max(0, min(model.visiblePage, pages - 1)) }
    var body: some View {
        if model.collapsed {
            TaskOrb(model: model).preferredColorScheme(model.settings.scheme).transition(.identity)
        } else {
            GeometryReader { geometry in
                let grid = model.settings.layout == .grid
                let cardHeight = max(CGFloat(grid ? 84 : 38), (geometry.size.height - (grid ? 105 : 120)) / (grid ? 2 : 4))
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        HStack {
                            Image(systemName: "waveform.path.ecg").foregroundColor(model.settings.progress.color)
                            Text("ai工作台").font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text("\(projects.filter { $0.running }.count) 进行中").font(.system(size: 10)).foregroundColor(.secondary)
                        }.frame(maxHeight: .infinity).modifier(PanelMoveHandle())
                        Button(action: { AppDelegate.shared.setOrbMode(true) }) {
                            Image(systemName: "minus").font(.system(size: 12, weight: .semibold))
                                .frame(width: 32, height: 26).contentShape(Rectangle())
                        }
                            .buttonStyle(.plain).help("最小化为进度圆球").accessibilityLabel("最小化为进度圆球")
                            .accessibilityAction { AppDelegate.shared.setOrbMode(true) }
                            .guideHighlight(model.guideStep == .orb)
                    }.frame(height: 26)
                    HStack {
                        Picker("项目", selection: $model.selected) {
                            Text("全部项目").tag("全部项目")
                            ForEach(model.projects) { project in Text(project.name).tag(project.id) }
                        }.labelsHidden().controlSize(.small).onChange(of: model.selected) { _ in model.visiblePage = 0 }
                        Spacer(minLength: 0)
                        Button { AppDelegate.shared.showPersonalization() } label: { Image(systemName: "slider.horizontal.3").frame(width: 20, height: 20) }
                            .buttonStyle(.plain).help("个性化设置").accessibilityLabel("个性化设置")
                            .guideHighlight(model.guideStep == .personalization)
                        Button { AppDelegate.shared.showGuide() } label: { Image(systemName: "questionmark.circle").frame(width: 20, height: 20) }
                            .buttonStyle(.plain).help("使用指引").accessibilityLabel("使用指引")
                    }.guideHighlight(model.guideStep == .tasks)
                    if let error = model.error { Text(error).font(.caption2).foregroundColor(.orange).lineLimit(2) }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: model.settings.layout.columns), spacing: 6) {
                        ForEach(0..<4, id: \.self) { slot in
                            let index = currentPage * 4 + slot
                            if index < projects.count {
                                let project = projects[index]
                                ProjectCard(model: model, project: project, height: cardHeight, onDoubleClick: onMinimize, openChatURL: openChatURL).id(project.id)
                            } else {
                                EmptyTaskCard(height: cardHeight, settings: model.settings)
                            }
                        }
                    }.guideHighlight(model.guideStep == .progress || model.guideStep == .pinning || model.guideStep == .entry)
                    HStack {
                        Text("每 3 秒刷新").font(.system(size: 10)).foregroundColor(.secondary)
                        Spacer()
                        Button { model.movePage(by: -1) } label: { Image(systemName: "chevron.left") }.disabled(currentPage == 0).accessibilityLabel("上一页")
                        Text("\(currentPage + 1)/\(pages)").font(.caption2).foregroundColor(.secondary)
                        Button { model.movePage(by: 1) } label: { Image(systemName: "chevron.right") }.disabled(currentPage >= pages - 1).accessibilityLabel("下一页")
                    }.buttonStyle(.plain).padding(.horizontal, 16)
                }.padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(model.settings.floatingBackground).preferredColorScheme(model.settings.scheme)
                    .overlay(alignment: .bottom) {
                        HStack { PanelResizeHandle(leading: true); Spacer(); PanelResizeHandle() }.padding(2)
                    }
            }.onChange(of: model.pinnedTaskIDs) { _ in model.visiblePage = 0 }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var shared: AppDelegate!
    let model: Model
    private let injectedChatService: ChatService?
    let externalChatOpener: (URL) -> Bool
    private let externalChatMinimizer: (() -> Void)?
    init(model: Model = Model(), chatService: ChatService? = nil, externalChatOpener: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }, externalChatMinimizer: (() -> Void)? = nil) {
        self.model = model; self.injectedChatService = chatService; self.externalChatOpener = externalChatOpener
        self.externalChatMinimizer = externalChatMinimizer; super.init()
    }
    var panel: NSPanel!
    var item: NSStatusItem!
    var timer: Timer?
    private var wheelMonitor: Any?
    private var wheelPageGate = WheelPageGate()
    var taskChooser: NSPanel?
    var personalizationWindow: NSWindow?
    var guideWindow: NSWindow?
    private var guideRestoreCollapsed = false
    var permissionWindow: NSWindow?
    lazy var chatController = BuiltInChatController(model: model, service: injectedChatService)
    func openTaskChatURL(_ url: URL) -> Bool {
        if model.chatDestination == .codex { return externalChatOpener(url) }
        guard url.scheme == "codex", url.host == "threads", let id = url.pathComponents.last,
              let row = model.rows.first(where: { $0.id == id }) else { return false }
        chatController.open(row); return true
    }
    let permissionStatus = AccessibilityPermissionStatus()
    var permissionNotice = PermissionNoticeState()
    var expandedSize = NSSize(width: 240, height: 268)
    let orbSize = NSSize(width: 64, height: 64)
    private var changingMode = false
    private var animatingOrb = false
    private var resizingFromHandle = false
    private var movingFromHeader = false
    private var edgeDragTimer: Timer?
    private var ignoreEdgeMovesUntil = Date.distantPast
    let minimumProgressSize = NSSize(width: 240, height: 268)
    let minimumChooserSize = NSSize(width: 300, height: 280)
    func savedSize(_ key: String, fallback: NSSize, minimum: NSSize) -> NSSize {
        let width = model.preferences.double(forKey: key + "Width")
        let height = model.preferences.double(forKey: key + "Height")
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1600, height: 1000)
        return NSSize(width: min(screen.width, max(minimum.width, width > 0 ? width : fallback.width)), height: min(screen.height - 40, max(minimum.height, height > 0 ? height : fallback.height)))
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSApp.setActivationPolicy(.accessory)
        expandedSize = savedSize("progress", fallback: expandedSize, minimum: minimumProgressSize)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: expandedSize), styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.minSize = minimumProgressSize; panel.delegate = self
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false; panel.isMovableByWindowBackground = true
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        let dashboard = NSHostingView(rootView: Dashboard(model: model))
        dashboard.sizingOptions = []
        panel.contentView = dashboard
        panel.minSize = minimumProgressSize
        panel.contentView?.wantsLayer = true; panel.contentView?.layer?.cornerRadius = 14; panel.contentView?.layer?.masksToBounds = true
        resize()
        position(); panel.orderFrontRegardless()
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self = self, event.window === self.panel, !self.model.collapsed, !self.animatingOrb else { return event }
            let direction = self.wheelPageGate.consume(delta: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas,
                                                       phase: event.phase, momentum: event.momentumPhase, time: Date().timeIntervalSinceReferenceDate)
            if direction != 0 { self.model.movePage(by: direction) }
            return nil
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "ai工作台")
        let menu = NSMenu()
        menu.addItem(withTitle: "显示 / 隐藏浮窗", action: #selector(toggle), keyEquivalent: "")
        menu.addItem(withTitle: "切换圆球 / 浮窗", action: #selector(toggleOrbMode), keyEquivalent: "")
        menu.addItem(withTitle: "移回右上角", action: #selector(position), keyEquivalent: "")
        menu.addItem(withTitle: "新建 / 进入任务", action: #selector(showTaskChooser), keyEquivalent: "")
        menu.addItem(withTitle: "个性化设置", action: #selector(showPersonalization), keyEquivalent: "")
        menu.addItem(withTitle: "使用指引", action: #selector(showGuide), keyEquivalent: "")
        menu.addItem(withTitle: "辅助功能权限 / 修复", action: #selector(showPermissionSettings), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q")
        for entry in menu.items { entry.target = self }; item.menu = menu
        model.refresh(); timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.model.refresh()
            self?.refreshPermissionStatus()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(position), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        if CommandLine.arguments.contains("--show-permissions") { showPermissionSettings() }
        if CommandLine.arguments.contains("--show-personalization") { showPersonalization() }
    }
    @objc func position() {
        guard let screen = panel?.screen ?? NSScreen.main else { return }
        let v = screen.visibleFrame
        ignoreEdgeMovesUntil = Date().addingTimeInterval(0.2)
        panel.setFrameOrigin(NSPoint(x: v.maxX - panel.frame.width - 18, y: v.maxY - panel.frame.height - 18))
    }
    @objc func showTaskChooser() {
        if let chooser = taskChooser { NSApp.activate(ignoringOtherApps: true); chooser.makeKeyAndOrderFront(nil); return }
        let size = savedSize("chooser", fallback: NSSize(width: 340, height: 350), minimum: minimumChooserSize)
        let chooser = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        chooser.delegate = self
        chooser.title = "新建或进入任务"; chooser.level = .floating; chooser.isReleasedWhenClosed = false
        let content = NSHostingView(rootView: TaskChooser(model: model, close: { [weak self] in self?.taskChooser?.close(); self?.taskChooser = nil }))
        content.sizingOptions = []
        chooser.contentView = content
        chooser.contentMinSize = minimumChooserSize
        chooser.center(); taskChooser = chooser
        NSApp.activate(ignoringOtherApps: true); chooser.makeKeyAndOrderFront(nil)
    }
    @objc func showPersonalization() {
        if let window = personalizationWindow { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); return }
        let minimum = NSSize(width: 380, height: 460)
        let size = savedSize("personalization", fallback: NSSize(width: 420, height: 610), minimum: minimum)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "个性化设置"; window.level = .floating; window.delegate = self; window.isReleasedWhenClosed = false
        // Keep the native color editor above the always-on-top settings window.
        NSColorPanel.shared.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        let content = NSHostingView(rootView: PersonalizationView(model: model, close: { [weak self] in self?.personalizationWindow?.close() }))
        content.sizingOptions = []; window.contentView = content; window.contentMinSize = minimum
        window.center(); personalizationWindow = window
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    @objc func showGuide() {
        if let window = guideWindow { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); return }
        guideRestoreCollapsed = model.collapsed
        if model.collapsed { setOrbMode(false) }
        model.guideStep = .tasks
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 320), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "ai工作台 · 使用指引"; window.level = .floating; window.delegate = self; window.isReleasedWhenClosed = false
        let content = NSHostingView(rootView: GuideView(model: model, close: { [weak self] in self?.guideWindow?.close() }))
        content.sizingOptions = []; window.contentView = content; window.contentMinSize = NSSize(width: 340, height: 300)
        window.center()
        if let screen = panel.screen?.visibleFrame, panel.frame.minX - 12 - window.frame.width >= screen.minX {
            window.setFrameOrigin(NSPoint(x: panel.frame.minX - window.frame.width - 12, y: max(screen.minY, panel.frame.maxY - window.frame.height)))
        }
        guideWindow = window; NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    @objc func toggleOrbMode() { setOrbMode(!model.collapsed) }
    func setOrbMode(_ compact: Bool, atEdge edge: PanelDockEdge = []) {
        guard model.collapsed != compact, !animatingOrb else { return }
        let placement = compact && !edge.isEmpty ? (panel.screen ?? NSScreen.main).map { edge.orbFrame(panel.frame, screen: $0.visibleFrame) } : nil
        if compact {
            expandedSize = panel.frame.size
            model.preferences.set(expandedSize.width, forKey: "progressWidth")
            model.preferences.set(expandedSize.height, forKey: "progressHeight")
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                animatingOrb = true
                let destination = placement.map { CGPoint(x: $0.midX - panel.frame.minX, y: $0.midY - panel.frame.minY) }
                if OrbCollapseTransition.animate(panel: panel, destination: destination, completion: { [weak self] in
                    self?.animatingOrb = false; self?.finishOrbMode(true, placement: placement)
                }) { return }
                animatingOrb = false
            }
        }
        finishOrbMode(compact, placement: placement)
    }
    private func finishOrbMode(_ compact: Bool, placement: NSRect? = nil) {
        model.collapsed = compact
        model.preferences.set(compact, forKey: "orbMode")
        resize()
        if let placement = placement { panel.setFrameOrigin(placement.origin) }
    }
    func resize() {
        ignoreEdgeMovesUntil = Date().addingTimeInterval(0.2)
        changingMode = true
        defer { changingMode = false }
        let anchor = NSPoint(x: panel.frame.maxX, y: panel.frame.maxY)
        panel.maxSize = NSSize(width: 10000, height: 10000)
        panel.minSize = model.collapsed ? orbSize : minimumProgressSize
        if model.collapsed { panel.styleMask.remove(.resizable); panel.maxSize = orbSize }
        else { panel.styleMask.insert(.resizable) }
        panel.isMovableByWindowBackground = !model.collapsed
        let size = model.collapsed ? orbSize : expandedSize
        var frame = NSRect(x: anchor.x - size.width, y: anchor.y - size.height, width: size.width, height: size.height)
        if let screen = (panel.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(screen.maxX - size.width, max(screen.minX, frame.minX))
            frame.origin.y = min(screen.maxY - size.height, max(screen.minY, frame.minY))
        }
        panel.setFrame(frame, display: true)
    }
    func moveOrb(from frame: NSRect, translation: NSSize) {
        guard model.collapsed, let screen = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: min(screen.maxX - frame.width, max(screen.minX, frame.minX + translation.width)), y: min(screen.maxY - frame.height, max(screen.minY, frame.minY + translation.height))))
    }
    func minimizeChatWindow() {
        if model.chatDestination == .builtIn { chatController.minimize(); return }
        if let minimize = externalChatMinimizer { minimize(); return }
        refreshPermissionStatus()
        switch ChatWindowController.minimizeChatWindow() {
        case .minimized, .noWindow: return
        case .needsPermission:
            if permissionNotice.shouldPresent(authorized: false) { presentPermissionWindow() }
        case .failed:
            let alert = NSAlert()
            alert.messageText = "暂时无法最小化 ChatGPT 窗口"
            alert.informativeText = "辅助功能权限已开启，但未能操作聊天窗口。请关闭聊天中的弹窗，再双击一次；也可从菜单栏的“辅助功能权限 / 修复”检查当前应用。"
            alert.addButton(withTitle: "确定")
            NSApp.activate(ignoringOtherApps: true); alert.runModal()
        }
    }
    func applicationDidBecomeActive(_ notification: Notification) { refreshPermissionStatus() }
    func refreshPermissionStatus() {
        permissionStatus.refresh()
        permissionNotice.observe(authorized: permissionStatus.authorized)
    }
    @objc func showPermissionSettings() {
        refreshPermissionStatus()
        _ = permissionNotice.shouldPresent(authorized: permissionStatus.authorized, explicitlyRequested: true)
        presentPermissionWindow()
    }
    func presentPermissionWindow() {
        if let window = permissionWindow {
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 310), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "辅助功能权限 / 修复"; window.level = .floating
        window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView: AccessibilityPermissionView(status: permissionStatus, restart: { [weak self] in self?.restartApplication() }, close: { [weak self] in self?.permissionWindow?.close() }))
        window.center(); permissionWindow = window
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    func restartApplication() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if error == nil { NSApp.terminate(nil) }
                else {
                    let alert = NSAlert(); alert.messageText = "无法自动重启"
                    alert.informativeText = "请退出浮窗，再重新打开「ai工作台」。"
                    alert.runModal()
                }
            }
        }
    }
    func resizeProgress(from frame: NSRect, translation: CGSize, leading: Bool) {
        guard !model.collapsed, !animatingOrb else { return }
        resizingFromHandle = true; cancelEdgeDrag(); ignoreEdgeMovesUntil = Date().addingTimeInterval(0.2)
        guard let screen = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        let width = min(screen.width, max(minimumProgressSize.width, frame.width + (leading ? -translation.width : translation.width)))
        let height = min(screen.height, max(minimumProgressSize.height, frame.height + translation.height))
        let x = min(screen.maxX - width, max(screen.minX, leading ? frame.maxX - width : frame.minX))
        let y = min(screen.maxY - height, max(screen.minY, frame.maxY - height))
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
    private func cancelEdgeDrag() { edgeDragTimer?.invalidate(); edgeDragTimer = nil }
    func moveProgress(from frame: NSRect, translation: CGSize) {
        guard !model.collapsed, !animatingOrb else { return }
        movingFromHeader = true; cancelEdgeDrag()
        let mouse = NSEvent.mouseLocation
        guard let screen = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: min(screen.maxX - frame.width, max(screen.minX, frame.minX + translation.width)),
                                     y: min(screen.maxY - frame.height, max(screen.minY, frame.minY - translation.height))))
    }
    func endProgressMove() {
        movingFromHeader = false; cancelEdgeDrag()
        guard !model.collapsed, !animatingOrb, let screen = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        let edge = PanelDockEdge.touching(panel.frame, screen: screen)
        if !edge.isEmpty { setOrbMode(true, atEdge: edge) }
    }
    func endHandleResize() { resizingFromHandle = false; cancelEdgeDrag(); ignoreEdgeMovesUntil = Date().addingTimeInterval(0.2) }
    func windowWillStartLiveResize(_ notification: Notification) { cancelEdgeDrag() }
    func windowDidEndLiveResize(_ notification: Notification) { cancelEdgeDrag(); ignoreEdgeMovesUntil = Date().addingTimeInterval(0.2) }
    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel,
              !model.collapsed, !changingMode, !animatingOrb, !resizingFromHandle, !movingFromHeader,
              !panel.inLiveResize, Date() >= ignoreEdgeMovesUntil, edgeDragTimer == nil else { return }
        let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            self.cancelEdgeDrag()
            guard !self.model.collapsed, !self.animatingOrb, !self.resizingFromHandle, !self.panel.inLiveResize,
                  let screen = (self.panel.screen ?? NSScreen.main)?.visibleFrame else { return }
            let edge = PanelDockEdge.touching(self.panel.frame, screen: screen)
            if !edge.isEmpty { self.setOrbMode(true, atEdge: edge) }
        }
        edgeDragTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === panel && !model.collapsed && !changingMode {
            expandedSize = window.frame.size
            model.preferences.set(expandedSize.width, forKey: "progressWidth")
            model.preferences.set(expandedSize.height, forKey: "progressHeight")
        } else if window === taskChooser, let size = window.contentView?.bounds.size {
            model.preferences.set(size.width, forKey: "chooserWidth")
            model.preferences.set(size.height, forKey: "chooserHeight")
        } else if window === personalizationWindow, let size = window.contentView?.bounds.size {
            model.preferences.set(size.width, forKey: "personalizationWidth")
            model.preferences.set(size.height, forKey: "personalizationHeight")
        }
    }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === taskChooser { taskChooser = nil }
        if let window = notification.object as? NSWindow, window === permissionWindow { permissionWindow = nil }
        if let window = notification.object as? NSWindow, window === personalizationWindow { personalizationWindow = nil }
        if let window = notification.object as? NSWindow, window === guideWindow {
            guideWindow = nil; model.guideStep = nil
            if guideRestoreCollapsed { setOrbMode(true) }; guideRestoreCollapsed = false
        }
    }
    @objc func toggle() { if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() } }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard chatController.service.activeCount > 0 else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "内置对话中仍有任务正在执行"
        alert.informativeText = "退出工作台会停止这些任务。仅关闭聊天窗口，任务会继续执行。"
        alert.addButton(withTitle: "继续执行"); alert.addButton(withTitle: "退出并停止")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) { chatController.shutdown() }
}
if let flag = CommandLine.arguments.firstIndex(of: "--selfcheck-chat"), CommandLine.arguments.count > flag + 3 {
    ChatChecks.run(python: CommandLine.arguments[flag + 1], fixture: CommandLine.arguments[flag + 2], root: CommandLine.arguments[flag + 3]); exit(0)
}
if CommandLine.arguments.contains("--selfcheck-installation") {
    func checkInstallation() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("ai-workbench-install-test-" + UUID().uuidString)
    let user = root.appendingPathComponent("user"), system = root.appendingPathComponent("system")
    try manager.createDirectory(at: system, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    var stops: [String] = []
    func install() throws -> URL { try AppInstallation.install(source: Bundle.main.bundleURL, userApplications: user, systemApplications: system, stop: { stops.append($0?.path ?? "all") }) }
    let target = try install()
    precondition(target.path == user.appendingPathComponent(AppInstallation.currentName).path && AppInstallation.verified(target), "The installed app must have the expected path and a valid signature")
    precondition(stops.count == 2)
    let unchanged = try Data(contentsOf: target.appendingPathComponent(AppInstallation.binary))
    stops = []; _ = try install()
    precondition(stops == [target.path], "Identical installations must reuse the signed app")
    let reused = try Data(contentsOf: target.appendingPathComponent(AppInstallation.binary))
    precondition(reused == unchanged)
    let suite = "local.codex.progress.install.test." + UUID().uuidString
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let model = Model(preferences: preferences)
    model.settings = PersonalizationPreset.violet.settings; model.settings.openMode = .double
    model.togglePin("fixture-pin"); preferences.set(310.0, forKey: "progressWidth")
    let settings = model.settings
    let legacy = user.appendingPathComponent(AppInstallation.legacyName)
    try manager.moveItem(at: target, to: legacy)
    _ = try install()
    precondition(!manager.fileExists(atPath: legacy.path) && manager.fileExists(atPath: target.path), "Rename upgrades must replace the old app, without duplicates")
    let restored = Model(preferences: preferences)
    precondition(restored.settings == settings && restored.isPinned("fixture-pin") && preferences.double(forKey: "progressWidth") == 310)
    try manager.moveItem(at: target, to: system.appendingPathComponent(AppInstallation.legacyName))
    let systemTarget = try install()
    precondition(systemTarget.path == system.appendingPathComponent(AppInstallation.currentName).path, "System-wide installations keep their location")
    var metadata = AppInstallation.info(systemTarget)!
    metadata["CFBundleShortVersionString"] = "99.0.0"
    let plist = systemTarget.appendingPathComponent("Contents/Info.plist")
    try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0).write(to: plist)
    precondition(AppInstallation.run("/usr/bin/codesign", ["--force", "--sign", "-", systemTarget.path]))
    _ = try install()
    precondition(AppInstallation.version(systemTarget) == [99, 0, 0], "Old installers must not downgrade a valid newer app")
    let invalidPlist = try Data(contentsOf: plist) + Data("\n".utf8)
    try invalidPlist.write(to: plist)
    _ = try install()
    precondition(AppInstallation.same(Bundle.main.bundleURL, systemTarget), "A corrupt bundle must be repaired")
    let unrelated = user.appendingPathComponent(AppInstallation.currentName)
    try manager.copyItem(at: systemTarget, to: unrelated)
    metadata["CFBundleIdentifier"] = "fixture.unrelated"
    try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0).write(to: unrelated.appendingPathComponent("Contents/Info.plist"))
    try manager.moveItem(at: systemTarget, to: root.appendingPathComponent("saved.app"))
    do { _ = try install(); preconditionFailure("An unrelated destination must never be replaced") }
    catch AppInstallationError.unrelatedDestination {}
    precondition(AppInstallation.info(unrelated)?["CFBundleIdentifier"] as? String == "fixture.unrelated")
    print("PASS: native installer, repeat-install identity, legacy rename, location preservation, settings/pins/size migration, downgrade protection, corrupt-bundle repair and unrelated-app protection")
    }
    try checkInstallation()
    exit(0)
}
if CommandLine.arguments.contains("--install-app") {
    do { print(try AppInstallation.install(source: Bundle.main.bundleURL).path); exit(0) }
    catch { FileHandle.standardError.write(Data(("无法安装 ai工作台：" + error.localizedDescription + "\n").utf8)); exit(1) }
}
if CommandLine.arguments.contains("--selfcheck-personalization") {
    for (count, expected) in [(0, 1), (3, 1), (4, 2), (5, 2), (8, 3), (9, 3)] { precondition(TaskPagination.pageCount(count) == expected) }
    var wheel = WheelPageGate()
    precondition(wheel.consume(delta: -1, precise: false, phase: [], momentum: [], time: 1) == 1)
    precondition(wheel.consume(delta: -1, precise: false, phase: [], momentum: [], time: 1.1) == 0)
    precondition(wheel.consume(delta: 1, precise: false, phase: [], momentum: [], time: 1.4) == -1)
    precondition(wheel.consume(delta: -10, precise: true, phase: .began, momentum: [], time: 2) == 0)
    precondition(wheel.consume(delta: -25, precise: true, phase: .changed, momentum: [], time: 2.1) == 1)
    precondition(wheel.consume(delta: -80, precise: true, phase: .changed, momentum: [], time: 2.2) == 0)
    precondition(wheel.consume(delta: 0, precise: true, phase: .ended, momentum: [], time: 2.3) == 0)
    precondition(wheel.consume(delta: -90, precise: true, phase: [], momentum: .changed, time: 2.4) == 0)
    precondition(wheel.consume(delta: 40, precise: true, phase: .began, momentum: [], time: 3) == -1)
    let suite = "local.codex.progress.personalization.test." + UUID().uuidString
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let now = Date()
    let model = Model(preferences: preferences, now: now)
    model.rows = (0..<4).map { TaskRow(id: "page-\($0)", title: "分页测试", project: "fixture", path: "", state: "运行中") }
    model.movePage(by: 1); precondition(model.visiblePage == 1, "Full pages must lead to an empty task-entry page")
    model.movePage(by: 1); precondition(model.visiblePage == 1)
    model.movePage(by: -1); precondition(model.visiblePage == 0)
    precondition(model.settings == PersonalizationSettings(), "Existing users keep the original layout and click mode")
    model.togglePin("done")
    model.preferences.set(320.0, forKey: "progressWidth")
    model.settings.openMode = .double
    for preset in PersonalizationPreset.allCases {
        model.applyPreset(preset)
        precondition(preset.matches(model.settings) && model.settings.openMode == .double, "Appearance presets must keep the user's click mode")
        let restored = Model(preferences: preferences)
        precondition(restored.settings == model.settings && restored.isPinned("done"))
        precondition(preferences.double(forKey: "progressWidth") == 320, "Appearance changes must keep pins and panel size")
    }
    model.settings.progress = RGBColor(hex: 0x123ABC)
    model.settings.backgroundOpacity = 0.5
    model.settings.background = RGBColor(hex: 0xFAFAFA)
    model.settings.completion = RGBColor(hex: 0x385B3E)
    model.settings.layout = .list; model.settings.progressStyle = .segments
    precondition(Model(preferences: preferences).settings == model.settings && model.settings.scheme == .light)
    var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(model.settings)) as! [String: Any]
    legacy.removeValue(forKey: "backgroundOpacity")
    preferences.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "personalization")
    let migrated = Model(preferences: preferences).settings
    precondition(migrated.background == model.settings.background && migrated.progress == model.settings.progress && migrated.openMode == .double && migrated.backgroundOpacity == 1, "Opacity migration must preserve old colors, layout and click mode")
    model.settings.save(to: preferences)
    model.settings.background = RGBColor(hex: 0x101010)
    precondition(model.settings.scheme == .dark)
    precondition(TaskOpenMode.single.action(clickCount: 1) == .open && TaskOpenMode.single.action(clickCount: 2) == .minimize)
    precondition(TaskOpenMode.double.action(clickCount: 1) == .select && TaskOpenMode.double.action(clickCount: 2) == .open)
    var done = TaskRow(id: "done", title: "完成测试", project: "fixture", path: "", state: "本轮结束")
    done.completionKey = "done:turn1"; done.completedAt = now.addingTimeInterval(1)
    model.rows = [done]
    var opens = 0, minimizes = 0
    var card = ProjectCard(model: model, project: model.card(for: done), onDoubleClick: { minimizes += 1 }, openChatURL: { _ in opens += 1; return true })
    model.settings.openMode = .single
    card.performClick(2)
    precondition(minimizes == 1 && opens == 0 && model.isPendingCompletion(done), "Original double click only minimizes and preserves completion")
    card.performClick(1)
    precondition(opens == 1 && !model.isPendingCompletion(done) && model.visible.count == 1)
    done.completionKey = "done:turn2"; done.completedAt = now.addingTimeInterval(2); model.rows = [done]
    card = ProjectCard(model: model, project: model.card(for: done), onDoubleClick: { minimizes += 1 }, openChatURL: { _ in opens += 1; return true })
    model.settings.openMode = .double
    card.performClick(1)
    precondition(model.selectedTaskID == done.id && opens == 1 && minimizes == 1 && model.isPendingCompletion(done), "Selection must not open, minimize or acknowledge")
    card.performClick(2)
    precondition(opens == 2 && minimizes == 1 && !model.isPendingCompletion(done) && model.isPinned(done.id))
    model.settings = PersonalizationSettings()
    precondition(Model(preferences: preferences).settings == PersonalizationSettings() && model.isPinned(done.id))
    preferences.set(Data("invalid-json".utf8), forKey: "personalization")
    precondition(Model(preferences: preferences).settings == PersonalizationSettings())
    let invalid = PersonalizationSettings()
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(invalid)) as! [String: Any]
    json["progress"] = ["red": 2, "green": 0, "blue": 0]
    preferences.set(try JSONSerialization.data(withJSONObject: json), forKey: "personalization")
    precondition(Model(preferences: preferences).settings == PersonalizationSettings(), "Invalid color data must fall back safely")
    print("PASS: settings persistence, preset combinations, color contrast, independent click mode, single/double actions, completion retention, pin preservation, reset and invalid-data recovery")
    exit(0)
}
if CommandLine.arguments.contains("--selfcheck-permissions") {
    var notice = PermissionNoticeState()
    var presentations = 0
    for _ in 0..<100 { if notice.shouldPresent(authorized: false) { presentations += 1 } }
    precondition(presentations == 1, "Repeated denied double clicks must not keep presenting permission UI")
    precondition(notice.shouldPresent(authorized: false, explicitlyRequested: true), "The repair entry must stay available after dismissing the first notice")
    precondition(!notice.shouldPresent(authorized: false))
    var granted = false
    let status = AccessibilityPermissionStatus(applicationPath: "/fixture/ai工作台.app", check: { granted })
    precondition(!status.authorized)
    granted = true; status.refresh(); notice.observe(authorized: status.authorized)
    precondition(status.authorized && !notice.shouldPresent(authorized: true), "Grant detection must enable the next operation without another prompt")
    granted = false; status.refresh(); notice.observe(authorized: status.authorized)
    precondition(!status.authorized && notice.shouldPresent(authorized: status.authorized), "A later revocation can show one new notice")
    precondition(!notice.shouldPresent(authorized: false))
    print("PASS: coalesced denial notice, explicit repair, grant refresh, later revocation")
    exit(0)
}
if CommandLine.arguments.contains("--selfcheck-window-actions") {
    var inspected = false
    var minimized: [String] = []
    let denied = WindowMinimizeOperation<String>(authorized: { false }, windows: {
        inspected = true; return ("focused", "main", ["other"])
    }, available: { _ in true }, minimize: { minimized.append($0); return true })
    precondition(denied.run() == .needsPermission && !inspected && minimized.isEmpty, "Permission denial must not inspect or change windows")
    func check(focused: String?, main: String?, all: [String], eligible: Set<String>, succeeds: Bool = true, expected: WindowMinimizeResult, target: String?) {
        minimized = []
        let operation = WindowMinimizeOperation<String>(authorized: { true }, windows: { (focused, main, all) }, available: { eligible.contains($0) }, minimize: { minimized.append($0); return succeeds })
        precondition(operation.run() == expected)
        precondition(minimized == target.map { [$0] } ?? [], "Only the first eligible window should be minimized")
    }
    check(focused: "focused", main: "main", all: ["other"], eligible: ["focused", "main", "other"], expected: .minimized, target: "focused")
    check(focused: "minimized", main: "main", all: ["other"], eligible: ["main", "other"], expected: .minimized, target: "main")
    check(focused: "dialog", main: nil, all: ["minimized", "other"], eligible: ["other"], expected: .minimized, target: "other")
    check(focused: nil, main: nil, all: ["minimized"], eligible: [], expected: .noWindow, target: nil)
    check(focused: "focused", main: "main", all: [], eligible: ["focused", "main"], succeeds: false, expected: .failed, target: "focused")
    print("PASS: permission guard, focused/main window priority, normal-window fallback, already-minimized exclusion, failure result")
    exit(0)
}
if CommandLine.arguments.contains("--selfcheck-pinning") {
    let suite = "local.codex.progress.test." + UUID().uuidString
    let preferences = UserDefaults(suiteName: suite)!
    let now = Date()
    let model = Model(preferences: preferences, now: now)
    var waiting = TaskRow(id: "waiting", title: "待开始任务", project: "甲", path: "/fixture", projectKey: "p1")
    var running = TaskRow(id: "running", title: "进行中任务", project: "甲", path: "/fixture", projectKey: "p1", state: "运行中")
    running.progress.stage = .verify
    var done = TaskRow(id: "done", title: "完成任务", project: "甲", path: "/fixture", projectKey: "p1", state: "本轮结束")
    done.completionKey = "done:turn1"; done.completedAt = now.addingTimeInterval(1)
    model.rows = [waiting, running, done]
    precondition(!model.visible.contains { $0.id == waiting.id })
    model.togglePin(waiting.id)
    precondition(model.visible.first?.id == waiting.id && model.card(for: waiting).pinned)
    precondition(model.card(for: waiting).progressLabel == "等待中" && model.card(for: waiting).percent == 0)
    precondition(Model(preferences: preferences).isPinned(waiting.id), "Pins must survive restart")
    model.togglePin(running.id)
    precondition(model.visible.prefix(2).map(\.id) == [waiting.id, running.id], "Pins must keep their order before automatic tasks")
    model.togglePin(done.id)
    model.acknowledge(model.card(for: done))
    precondition(model.visible.contains { $0.id == done.id }, "Viewed pinned completion must remain on the taskbar")
    precondition(model.card(for: done).waiting && model.visible.first { $0.id == done.id }?.state == "等待中", "Viewed pinned completion must reset its displayed progress to waiting")
    let restarted = Model(preferences: preferences, now: now); restarted.rows = [done]
    precondition(restarted.visible.first?.state == "等待中" && restarted.card(for: done).percent == 0, "The waiting state must survive refresh and restart")
    var orb = TaskOrbSummary(rows: model.visible, pendingCompletionIDs: model.pendingCompletionIDs)
    precondition(!orb.hasCompletion && orb.reference?.id == running.id, "Viewed pinned completion must stop highlighting and not replace active progress")
    model.togglePin(done.id)
    precondition(!model.visible.contains { $0.id == done.id }, "Unpinning viewed completion must hide it")
    model.togglePin(running.id)
    precondition(model.visible.contains { $0.id == running.id }, "Unpinning must not hide a running task")
    model.rows = [waiting]
    orb = TaskOrbSummary(rows: model.visible, pendingCompletionIDs: model.pendingCompletionIDs)
    precondition(orb.taskCount == 1 && orb.waitingCount == 1 && orb.percent == 0 && orb.reference == nil)
    waiting.state = "运行中"; waiting.progress.stage = .implement; model.rows = [waiting]
    precondition(model.card(for: waiting).percent == 45 && model.card(for: waiting).progressLabel == "≈45%", "Starting a pinned waiting task must update progress")
    waiting.state = "本轮结束"; waiting.completionKey = "waiting:turn1"; waiting.completedAt = now.addingTimeInterval(2); model.rows = [waiting]
    orb = TaskOrbSummary(rows: model.visible, pendingCompletionIDs: model.pendingCompletionIDs)
    precondition(orb.hasCompletion && orb.percent == 100)
    model.acknowledge(model.card(for: waiting))
    precondition(model.visible.count == 1 && !TaskOrbSummary(rows: model.visible, pendingCompletionIDs: model.pendingCompletionIDs).hasCompletion)
    precondition(model.card(for: waiting).waiting && TaskOrbSummary(rows: model.visible, pendingCompletionIDs: model.pendingCompletionIDs).waitingCount == 1)
    waiting.state = "运行中"; waiting.steps = []; waiting.progress.stage = .prepare; model.rows = [waiting]
    precondition(model.card(for: waiting).running && model.card(for: waiting).percent == 10, "A new turn must leave waiting and use its fresh progress")
    waiting.state = "本轮结束"; waiting.completionKey = "waiting:turn2"; waiting.completedAt = now.addingTimeInterval(3); model.rows = [waiting]
    precondition(model.card(for: waiting).completed && model.isPendingCompletion(waiting), "A new completion must show 100% and highlight again")
    model.acknowledge(model.card(for: waiting))
    model.togglePin(waiting.id)
    precondition(model.visible.isEmpty && !Model(preferences: preferences).isPinned(waiting.id))
    var unreadable = TaskRow(id: "unreadable", title: "记录异常", project: "甲", path: "/fixture", projectKey: "p1", state: "记录不可读")
    model.rows = [unreadable]; model.togglePin(unreadable.id)
    precondition(!model.card(for: unreadable).waiting && model.card(for: unreadable).progressLabel == "读取异常")
    unreadable.state = "已中断"; model.rows = [unreadable]
    precondition(model.card(for: unreadable).progressLabel == "已中断")
    model.selected = "p2"
    precondition(model.visible.isEmpty, "Pins must respect project selection")

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("task-progress-pins-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var db: OpaquePointer?
    precondition(sqlite3_open(folder.appendingPathComponent("state_5.sqlite").path, &db) == SQLITE_OK)
    func sql(_ value: String) { precondition(sqlite3_exec(db, value, nil, nil, nil) == SQLITE_OK) }
    sql("CREATE TABLE threads(id,title,name,cwd,rollout_path,project_id,archived,agent_role,source,updated_at)")
    for index in 0..<81 { sql("INSERT INTO threads VALUES('recent\(index)','recent',NULL,'/fixture','',NULL,0,NULL,'desktop',\(index + 1))") }
    sql("INSERT INTO threads VALUES('old''pinned','old',NULL,'/fixture','',NULL,0,NULL,'desktop',0)")
    sql("INSERT INTO threads VALUES('archived','old',NULL,'/fixture','',NULL,1,NULL,'desktop',0)")
    let reader = Reader(root: folder.path)
    precondition(reader.read().rows.count == 80)
    let included = reader.read(including: ["old'pinned", "archived"])
    precondition(included.rows.count == 81 && included.rows.contains { $0.id == "old'pinned" }, "Older pinned tasks must remain available beyond the recent-task limit")
    precondition(!included.rows.contains { $0.id == "archived" })
    precondition(ProjectRow(id: "old'pinned", tasks: [included.rows.first { $0.id == "old'pinned" }!]).progressLabel == "等待中", "Draft without rollout must show waiting")
    sqlite3_close(db)
    try FileManager.default.removeItem(at: folder)
    preferences.removePersistentDomain(forName: suite)
    print("PASS: pin/unpin persistence, stable pin order, waiting lifecycle, pinned completion acknowledgement, orb notifications, older pinned tasks, missing draft rollout, project filtering")
    exit(0)
}
if CommandLine.arguments.contains("--selfcheck-orb") {
    let suite = "local.codex.progress.test." + UUID().uuidString
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let now = Date()
    let model = Model(preferences: preferences, now: now)
    var slow = TaskRow(id: "slow", title: "实现任务", project: "乙", path: "/fixture", projectKey: "p2", state: "运行中")
    slow.progress.stage = .implement
    var fast = TaskRow(id: "fast", title: "验证任务", project: "甲", path: "/fixture", projectKey: "p1", state: "运行中")
    fast.progress.stage = .verify
    var planned = TaskRow(id: "planned", title: "计划任务", project: "乙", path: "/fixture", projectKey: "p2", state: "运行中")
    planned.steps = [("实现", "completed"), ("验证", "in_progress")]
    var done = TaskRow(id: "done", title: "完成任务", project: "甲", path: "/fixture", projectKey: "p1", state: "本轮结束")
    done.completionKey = "done:turn1"; done.completedAt = now.addingTimeInterval(1)
    model.rows = [slow, fast, planned, done]
    var summary = TaskOrbSummary(rows: model.visible)
    precondition(summary.taskCount == 4 && summary.runningCount == 3 && summary.completedCount == 1)
    precondition(summary.reference?.id == "fast" && summary.percent == 75, "A retained completion must not replace the most advanced active task")
    precondition(summary.hasCompletion && summary.description.contains("≈75%"), "Completion highlight and estimate label must coexist")
    model.rows = [slow, planned, done]
    summary = TaskOrbSummary(rows: model.visible)
    precondition(summary.reference?.id == "planned" && summary.percent == 50)
    model.selected = "p1"
    summary = TaskOrbSummary(rows: model.visible)
    precondition(summary.taskCount == 1 && summary.percent == 100 && summary.hasCompletion, "Orb must respect project selection and show completed-only state")
    model.acknowledge(ProjectRow(id: done.id, tasks: [done]))
    summary = TaskOrbSummary(rows: model.visible)
    precondition(summary.taskCount == 0 && summary.percent == 0 && !summary.hasCompletion, "Viewed completion must stop highlighting")
    done.completionKey = "done:turn2"; done.completedAt = now.addingTimeInterval(2)
    model.rows = [done]
    precondition(TaskOrbSummary(rows: model.visible).hasCompletion, "A later completion must highlight again")

    let screen = NSRect(x: -1280, y: -200, width: 1280, height: 900)
    for (frame, expected) in [
        (NSRect(x: -1278, y: 0, width: 240, height: 268), PanelDockEdge.left),
        (NSRect(x: -242, y: 0, width: 240, height: 268), PanelDockEdge.right),
        (NSRect(x: -800, y: 430, width: 240, height: 268), PanelDockEdge.top),
        (NSRect(x: -800, y: -198, width: 240, height: 268), PanelDockEdge.bottom),
        (NSRect(x: -1300, y: 450, width: 240, height: 268), PanelDockEdge([.left, .top]))
    ] {
        let edge = PanelDockEdge.touching(frame, screen: screen)
        precondition(edge == expected)
        let orb = edge.orbFrame(frame, screen: screen)
        precondition(screen.contains(orb) && orb.size == NSSize(width: 64, height: 64), "Edge docking must keep the orb visible on any display")
        if edge.contains(.left) { precondition(orb.minX == screen.minX + 4) }
        if edge.contains(.right) { precondition(orb.maxX == screen.maxX - 4) }
        if edge.contains(.top) { precondition(orb.maxY == screen.maxY - 4) }
        if edge.contains(.bottom) { precondition(orb.minY == screen.minY + 4) }
    }
    precondition(PanelDockEdge.touching(NSRect(x: -258, y: 414, width: 240, height: 268), screen: screen).isEmpty, "The normal upper-right placement must not auto-collapse")

    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let check = AppDelegate(model: model)
    AppDelegate.shared = check
    check.panel = NSPanel(contentRect: NSRect(x: 200, y: 200, width: 310, height: 317), styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
    check.panel.delegate = check
    let hosting = NSHostingView(rootView: Dashboard(model: model)); hosting.sizingOptions = []
    check.panel.contentView = hosting
    check.setOrbMode(true)
    precondition(check.panel.frame.size == check.orbSize && !check.panel.styleMask.contains(.resizable))
    precondition(Model(preferences: preferences).collapsed, "Orb mode must survive restart")
    let saved = check.savedSize("progress", fallback: .zero, minimum: check.minimumProgressSize)
    precondition(saved == NSSize(width: 310, height: 317), "Orb dimensions must not overwrite the expanded size")
    check.setOrbMode(false)
    precondition(check.panel.frame.size == saved && check.panel.styleMask.contains(.resizable), "Expanding must restore both dimensions and resizing")
    precondition(!Model(preferences: preferences).collapsed)
    print("PASS: orb task count, fastest active progress, completion highlight lifecycle, project filtering, empty state, compact mode persistence, native size restoration")
    exit(0)
}
if CommandLine.arguments.contains("--selfcheck-names") {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("task-progress-names-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let log = folder.appendingPathComponent("turn.jsonl")
    try "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n".write(to: log, atomically: true, encoding: .utf8)
    let otherLog = folder.appendingPathComponent("other-turn.jsonl")
    try FileManager.default.copyItem(at: log, to: otherLog)
    var database: OpaquePointer?
    precondition(sqlite3_open(folder.appendingPathComponent("state_5.sqlite").path, &database) == SQLITE_OK)
    defer { sqlite3_close(database) }
    func sql(_ text: String) { precondition(sqlite3_exec(database, text, nil, nil, nil) == SQLITE_OK) }
    sql("CREATE TABLE threads(id,title,name,cwd,rollout_path,project_id,archived,agent_role,source,updated_at)")
    sql("INSERT INTO threads VALUES('one','原始提示','自定义任务名','/shared','\(log.path)',NULL,0,NULL,'desktop',2)")
    sql("INSERT INTO threads VALUES('two','原始提示2',NULL,'/shared','\(otherLog.path)',NULL,0,NULL,'desktop',1)")
    var state: [String: Any] = [
        "local-projects": ["p1": ["name": "项目甲", "rootPaths": ["/shared"]], "p2": ["name": "项目乙", "rootPaths": ["/shared"]]],
        "project-order": ["p1", "p2"],
        "thread-project-assignments": ["one": ["projectKind": "local", "projectId": "p1"], "two": ["projectKind": "local", "projectId": "p2"]]
    ]
    func saveState() throws { try JSONSerialization.data(withJSONObject: state).write(to: folder.appendingPathComponent(".codex-global-state.json"), options: .atomic) }
    try saveState()
    let reader = Reader(root: folder.path)
    let first = reader.read()
    precondition(first.rows.first { $0.id == "one" }?.title == "自定义任务名")
    precondition(first.rows.first { $0.id == "two" }?.title == "原始提示2")
    precondition(first.rows.first { $0.id == "one" }?.project == "项目甲")
    precondition(first.rows.first { $0.id == "two" }?.project == "项目乙")
    sql("UPDATE threads SET name='再次改名' WHERE id='one'")
    state["local-projects"] = ["p1": ["name": "改名项目", "rootPaths": ["/shared"]], "p2": ["name": "项目乙", "rootPaths": ["/shared"]]]
    try saveState()
    let second = reader.read()
    precondition(second.rows.first { $0.id == "one" }?.title == "再次改名", "Rename must update even without new log records")
    precondition(second.rows.first { $0.id == "one" }?.project == "改名项目")
    precondition(second.projects.count == 2)
    let suite = "local.codex.progress.test." + UUID().uuidString
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let model = Model(reader: reader, preferences: preferences)
    model.rows = second.rows; model.sidebarProjects = second.projects; model.selected = "p2"
    precondition(model.visible.map(\.id) == ["two"], "Same directory must not merge different sidebar projects")
    print("PASS: sidebar task names, project names, rename refresh, shared-folder project identity")
    exit(0)
}
if CommandLine.arguments.contains("--selfcheck-links") {
    let text = "中文任务 A+B & # ? %\n第二行"
    let folder = FileManager.default.temporaryDirectory.path
    let link = ChatLink.newTask(prompt: text, path: folder)!
    let decoded = URLComponents(url: link, resolvingAgainstBaseURL: false)!.queryItems!
    precondition(decoded.first { $0.name == "prompt" }?.value == text)
    precondition(decoded.first { $0.name == "path" }?.value == folder)
    precondition(link.absoluteString.contains("%2B"), "Plus must survive URLSearchParams decoding")
    precondition(ChatLink.newTask(prompt: "", path: nil)?.absoluteString == "codex://threads/new")
    precondition(ChatLink.newTask(prompt: text, path: "relative/path") == nil)
    precondition(ChatLink.newTask(prompt: text, path: "/path/that/does/not/exist") == nil)
    print("PASS: new-chat link, prompt encoding, directory validation, empty draft")
    exit(0)
}
if CommandLine.arguments.contains("--selfcheck-lifecycle") {
    let suite = "local.codex.progress.test." + UUID().uuidString
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let now = Date()
    let model = Model(preferences: preferences, now: now)
    let active = TaskRow(id: "active", title: "active", project: "fixture", path: "/fixture", state: "运行中")
    var done = TaskRow(id: "done", title: "done", project: "fixture", path: "/fixture", state: "本轮结束")
    done.completionKey = "done:turn1"; done.completedAt = now.addingTimeInterval(1)
    var old = done; old.id = "old"; old.completionKey = "old:turn1"; old.completedAt = now.addingTimeInterval(-1)
    model.rows = [done, old, active]
    precondition(model.visible.map(\.id) == ["active", "done"], "Active tasks first; completion retained; historical tasks excluded")
    precondition(ProjectRow(id: done.id, tasks: [done]).percent == 100)
    model.acknowledge(ProjectRow(id: done.id, tasks: [done]))
    precondition(model.visible.map(\.id) == ["active"], "Clicked completion removed")
    let relaunched = Model(preferences: preferences, now: now.addingTimeInterval(2))
    relaunched.rows = [done]
    precondition(relaunched.visible.isEmpty, "Dismissal persists after relaunch")
    done.completionKey = "done:turn2"; done.completedAt = now.addingTimeInterval(3)
    relaunched.rows = [done]
    precondition(relaunched.visible.count == 1, "A new completion of the same chat reappears")
    print("PASS: retained completion, 100%, click dismissal, persistence, next turn")
    exit(0)
}
if CommandLine.arguments.contains("--diagnose") || CommandLine.arguments.contains("--diagnose-stages") {
    let snapshot = Reader(root: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex").read()
    if CommandLine.arguments.contains("--diagnose-stages") {
        let rows: [[String: Any]] = snapshot.rows.map { row in
            let project = ProjectRow(id: row.id, tasks: [row])
            return ["id": row.id, "state": row.state, "stage": row.progress.stage.title, "percent": project.percent, "planned": project.hasPlan, "remaining": project.remaining]
        }
        if let data = try? JSONSerialization.data(withJSONObject: rows, options: .sortedKeys), let string = String(data: data, encoding: .utf8) { print(string) }
    } else { print("threads=\(snapshot.rows.count), running=\(snapshot.rows.filter { $0.state == "运行中" }.count), error=\(snapshot.error ?? "none")") }
    exit(snapshot.error == nil ? 0 : 1)
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

import Cocoa
import SwiftUI

struct ChatPromptView: View {
    @ObservedObject var session: ChatSession
    let service: ChatService
    let prompt: ChatPrompt
    @State private var answers: [String: String] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(prompt.title, systemImage: "questionmark.bubble").font(.headline)
            if prompt.isQuestion {
                ForEach(Array(prompt.questions.enumerated()), id: \.offset) { _, question in
                    let id = question["id"] as? String ?? "question"
                    Text(question["question"] as? String ?? "").fixedSize(horizontal: false, vertical: true)
                    ForEach(Array((question["options"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, option in
                        Button { answers[id] = option["label"] as? String ?? "" } label: {
                            HStack(alignment: .top) {
                                Image(systemName: answers[id] == option["label"] as? String ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading) {
                                    Text(option["label"] as? String ?? "").fontWeight(.medium)
                                    Text(option["description"] as? String ?? "").font(.caption).foregroundColor(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                    if question["isSecret"] as? Bool == true {
                        SecureField("输入回答", text: Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 }))
                    } else { TextField("也可以输入自己的回答", text: Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 })).textFieldStyle(.roundedBorder) }
                }
                HStack {
                    Spacer()
                    Button("提交回答") {
                        var values: [String: Any] = [:]
                        for (key, value) in answers { values[key] = ["answers": [value]] }
                        service.answer(session, prompt: prompt, result: ["answers": values])
                    }.buttonStyle(.borderedProminent).disabled(prompt.questions.contains { (answers[$0["id"] as? String ?? "question"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                }
            } else {
                if !prompt.detail.isEmpty { Text(prompt.detail).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                if prompt.method.contains("fileChange"), let item = prompt.params["itemId"] as? String,
                   let message = session.messages.first(where: { $0.id == item }), !message.detail.isEmpty { Text(message.detail).font(.caption).textSelection(.enabled) }
                Text("只确认当前这一次操作。").font(.caption).foregroundColor(.secondary)
                HStack {
                    Button("拒绝") { service.answer(session, prompt: prompt, result: ["decision": "decline"]) }
                    Spacer()
                    Button("允许本次") { service.answer(session, prompt: prompt, result: ["decision": "accept"]) }.buttonStyle(.borderedProminent)
                }
            }
        }.padding(12).background(Color.orange.opacity(0.10)).cornerRadius(10)
    }
}
struct ChatMessageView: View {
    let message: ChatMessage
    let settings: PersonalizationSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(message.title).font(.caption).foregroundColor(.secondary)
                Spacer()
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text + (message.detail.isEmpty ? "" : "\n" + message.detail), forType: .string) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain).help("复制消息").accessibilityLabel("复制消息")
            }
            if message.role == "activity" {
                if message.detail.isEmpty { Text(message.text).font(.caption).foregroundColor(.secondary) }
                else { DisclosureGroup(message.text) { Text(message.detail).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.font(.caption) }
            } else {
                Text(message.text.isEmpty ? "正在回复…" : message.text).font(.system(size: 14)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(message.role == "user" ? settings.progress.color.opacity(0.12) : settings.cardBackground).cornerRadius(10)
    }
}
struct BuiltInChatView: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var service: ChatService
    @ObservedObject var model: Model
    let openCodex: () -> Void
    let titleChanged: () -> Void
    @State private var followLatest = true
    var recent: [ChatMessage] { session.recentMessages(model.recentChatCount) }
    func chooseWorkspace() {
        let picker = NSOpenPanel(); picker.canChooseFiles = false; picker.canChooseDirectories = true; picker.allowsMultipleSelection = false
        if picker.runModal() == .OK, let path = picker.url?.path { session.workspace = path }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title).font(.headline).lineLimit(2).textSelection(.enabled)
                    Text(session.workspace.isEmpty ? "无项目" : session.workspace).font(.caption).foregroundColor(.secondary).lineLimit(1).help(session.workspace)
                    Text(session.status + " · 最近 \(model.recentChatCount) 条消息").font(.caption).foregroundColor(session.running ? model.settings.progress.color : .secondary)
                }
                Spacer(minLength: 0)
                if session.threadID == nil { Button("选择项目", action: chooseWorkspace).disabled(session.sending) }
                Button("在 Codex 中打开", action: openCodex).help("使用 Codex 的完整任务界面")
            }.padding(14)
            Divider()
            if let error = service.connectionError {
                HStack { Text(error).font(.caption).fixedSize(horizontal: false, vertical: true); Spacer(); Button("重新连接") { service.connect { ready in if ready { service.load(session) } } } }.padding(12).background(Color.orange.opacity(0.10))
            } else if service.connecting { HStack { ProgressView().controlSize(.small); Text("正在连接本机 Codex…").font(.caption); Spacer() }.padding(12) }
            else if service.connected && !service.signedIn {
                HStack { Text("使用本机 Codex 登录后即可发送消息。").font(.caption); Spacer(); Button("登录 ChatGPT") { service.login() }; Button("重新检测") { service.checkAccount() } }.padding(12)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if session.messages.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 28)).foregroundColor(model.settings.progress.color)
                                Text(session.loading ? "正在读取对话…" : "在这里继续任务对话").font(.headline)
                                Text("输入要求后点击发送。任务在本机 Codex 执行，进度继续显示在浮窗。").font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                            }.frame(maxWidth: .infinity).padding(.vertical, 40)
                        }
                        ForEach(recent) { message in ChatMessageView(message: message, settings: model.settings).id(message.id) }
                        Color.clear.frame(height: 1).id("latest")
                    }.padding(14)
                }.onChange(of: recent) { _ in if followLatest { proxy.scrollTo("latest", anchor: .bottom) } }
                    .onChange(of: followLatest) { value in if value { proxy.scrollTo("latest", anchor: .bottom) } }
            }
            if !session.prompts.isEmpty {
                ScrollView { VStack(spacing: 8) { ForEach(session.prompts) { prompt in ChatPromptView(session: session, service: service, prompt: prompt) } }.padding(12) }.frame(maxHeight: 220)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if session.externalBusy { Text("此任务正在 Codex 中执行，完成后可在这里继续发送。").font(.caption).foregroundColor(.orange) }
                if let error = session.error { Text(error).font(.caption).foregroundColor(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                TextEditor(text: $session.draft).font(.system(size: 14)).frame(height: 82).padding(4).background(model.settings.cardBackground).cornerRadius(8).accessibilityLabel("消息内容")
                HStack {
                    Toggle("跟随最新回复", isOn: $followLatest).toggleStyle(.checkbox).font(.caption)
                    Button("刷新") { service.load(session, resolveDelivery: true) }.disabled(session.loading || session.running || session.sending || session.threadID == nil)
                    Spacer()
                    if session.running { Button("停止") { service.stop(session) }.tint(.orange) }
                    else { Button(session.sending ? "发送中…" : "发送") { service.send(session) }.buttonStyle(.borderedProminent).tint(model.settings.progress.color).disabled(!session.canSend || !service.connected || !service.signedIn).keyboardShortcut(.return, modifiers: .command) }
                }
                Text("⌘ Enter 发送 · 关闭聊天窗口后，任务继续在后台执行。").font(.caption2).foregroundColor(.secondary)
            }.padding(12)
        }.background(model.settings.background.color).preferredColorScheme(model.settings.scheme)
            .onChange(of: session.draft) { _ in service.saveDraft(session) }
            .onChange(of: session.title) { _ in titleChanged() }
    }
}
final class BuiltInChatController: NSObject, NSWindowDelegate {
    let model: Model
    let service: ChatService
    private var windows: [String: NSWindow] = [:]
    private var refreshTimer: Timer?
    init(model: Model, service: ChatService? = nil) {
        self.model = model; self.service = service ?? ChatService(model: model); super.init()
        self.service.needsAttention = { [weak self] session in self?.show(session, activate: false) }
    }
    func open(_ row: TaskRow) { let session = service.session(for: row); show(session); service.load(session) }
    func newTask(prompt: String, workspace: String) { let session = service.newSession(workspace: workspace, prompt: prompt); show(session); service.connect() }
    func show(_ session: ChatSession, activate: Bool = true) {
        if let window = windows[session.id] {
            if window.isMiniaturized { window.deminiaturize(nil) }
            if activate { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
            else { window.orderFrontRegardless() }
            return
        }
        let size = AppDelegate.shared.savedSize("chat", fallback: NSSize(width: 420, height: 520), minimum: NSSize(width: 360, height: 380))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "ai工作台 · " + session.title; window.isReleasedWhenClosed = false; window.delegate = self
        let host = NSHostingView(rootView: BuiltInChatView(session: session, service: service, model: model, openCodex: { [weak self, weak session] in
            guard let self = self, let session = session else { return }; self.openCodex(session)
        }, titleChanged: { [weak window, weak session] in if let title = session?.title { window?.title = "ai工作台 · " + title } }))
        host.sizingOptions = []; window.contentView = host; window.contentMinSize = NSSize(width: 360, height: 380)
        window.center(); windows[session.id] = window
        if activate { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) } else { window.orderFrontRegardless() }
        if refreshTimer == nil { refreshTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            for session in self.service.uniqueSessions where self.windows[session.id]?.isVisible == true && !session.running && !session.sending { self.service.load(session) }
        } }
    }
    func openCodex(_ session: ChatSession) {
        let url = session.threadID.flatMap { URL(string: "codex://threads/" + $0) } ?? ChatLink.newTask(prompt: session.draft, path: session.workspace.isEmpty ? nil : session.workspace)
        if let url = url { if !AppDelegate.shared.externalChatOpener(url) { session.error = "无法打开 Codex，请确认应用已安装。" } }
    }
    func taskWindow(_ taskID: String) -> NSWindow? {
        if let window = windows[taskID] { return window }
        guard let session = service.uniqueSessions.first(where: { $0.threadID == taskID }) else { return nil }
        return windows[session.id]
    }
    func isOpen(taskID: String) -> Bool {
        guard let window = taskWindow(taskID) else { return false }
        return window.isVisible && !window.isMiniaturized
    }
    func minimize(taskID: String) {
        guard isOpen(taskID: taskID) else { return }
        taskWindow(taskID)?.miniaturize(nil)
    }
    func windowDidResize(_ notification: Notification) {
        if let window = notification.object as? NSWindow, let size = window.contentView?.bounds.size { model.preferences.set(size.width, forKey: "chatWidth"); model.preferences.set(size.height, forKey: "chatHeight") }
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        for session in service.uniqueSessions where windows[session.id] === window { service.saveDraft(session) }
    }
    func shutdown() { refreshTimer?.invalidate(); service.rpc.stop() }
}

import Cocoa
import SwiftUI

enum TaskChatDestination: String, CaseIterable, Identifiable {
    case builtIn, codex
    var id: String { rawValue }
    var title: String { self == .builtIn ? "在 ai工作台内对话" : "在 Codex 中打开" }
}
struct ChatMessage: Identifiable, Equatable {
    let id: String
    var role: String
    var text: String
    var detail = ""
    var title: String { role == "user" ? "你" : role == "assistant" ? "Codex" : "执行记录" }
    static func item(_ item: [String: Any]) -> Self? {
        guard let id = item["id"] as? String, let type = item["type"] as? String else { return nil }
        switch type {
        case "userMessage":
            let content = item["content"] as? [[String: Any]] ?? []
            let text = content.map { value -> String in
                if value["type"] as? String == "text" { return value["text"] as? String ?? "" }
                return value["type"] as? String == "localImage" || value["type"] as? String == "image" ? "[图片]" : "[附件]"
            }.joined(separator: "\n")
            return Self(id: id, role: "user", text: text)
        case "agentMessage": return Self(id: id, role: "assistant", text: item["text"] as? String ?? "")
        case "plan": return Self(id: id, role: "activity", text: "任务计划", detail: item["text"] as? String ?? "")
        case "commandExecution": return Self(id: id, role: "activity", text: "执行命令 · " + (item["status"] as? String ?? ""), detail: (item["command"] as? String ?? "") + "\n" + (item["aggregatedOutput"] as? String ?? ""))
        case "fileChange":
            let changes = (item["changes"] as? [[String: Any]] ?? []).map { ($0["path"] as? String ?? "") + "\n" + ($0["diff"] as? String ?? "") }
            return Self(id: id, role: "activity", text: "修改文件 · " + (item["status"] as? String ?? ""), detail: changes.joined(separator: "\n"))
        case "mcpToolCall": return Self(id: id, role: "activity", text: "使用工具：" + (item["tool"] as? String ?? "") + " · " + (item["status"] as? String ?? ""))
        default: return nil // Internal instructions and raw reasoning are not chat messages.
        }
    }
}
struct ChatPrompt: Identifiable {
    let id: String
    let wireID: Any
    let method: String
    let params: [String: Any]
    var questions: [[String: Any]] { params["questions"] as? [[String: Any]] ?? [] }
    var isQuestion: Bool { method == "item/tool/requestUserInput" }
    var title: String { isQuestion ? "需要你的回答" : method.contains("fileChange") ? "确认文件修改" : "确认执行命令" }
    var detail: String {
        var values = [params["reason"] as? String, params["command"] as? String, params["cwd"] as? String].compactMap { $0 }
        for key in ["additionalPermissions", "networkApprovalContext"] {
            if let value = params[key], !(value is NSNull), JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { values.append(text) }
        }
        return values.joined(separator: "\n")
    }
}
final class ChatSession: ObservableObject, Identifiable {
    let id: String
    let initialDraftKey: String
    @Published var threadID: String?
    @Published var title: String
    @Published var workspace: String
    @Published var draft: String
    @Published var messages: [ChatMessage] = []
    @Published var loading = false
    @Published var sending = false
    @Published var ownedTurnID: String?
    @Published var externalBusy = false
    @Published var error: String?
    @Published var prompts: [ChatPrompt] = []
    @Published var uncertainDelivery = false
    var resumed = false
    var finishedTurns = Set<String>()
    var ownedExecutor = false
    init(id: String, threadID: String?, title: String, workspace: String, draft: String = "") {
        self.id = id; self.initialDraftKey = threadID ?? "draft:" + workspace
        self.threadID = threadID; self.title = title; self.workspace = workspace; self.draft = draft
    }
    var running: Bool { ownedTurnID != nil }
    var canSend: Bool { !loading && !sending && !running && !externalBusy && !uncertainDelivery && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var status: String { !prompts.isEmpty ? "等待确认" : running ? "正在执行" : externalBusy ? "正在 Codex 中执行" : loading ? "读取对话中" : "可以继续对话" }
    func recentMessages(_ limit: Int) -> [ChatMessage] { Array(messages.filter { $0.role == "user" || $0.role == "assistant" }.suffix(max(1, min(20, limit)))) }
    func upsert(_ message: ChatMessage) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) { messages[index] = message }
        else { messages.append(message) }
    }
    func appendDelta(id: String, text: String) {
        if let index = messages.firstIndex(where: { $0.id == id }) { messages[index].text += text }
        else { messages.append(ChatMessage(id: id, role: "assistant", text: text)) }
    }
}
final class ChatService: ObservableObject {
    @Published var connected = false
    @Published var connecting = false
    @Published var signedIn = false
    @Published var connectionError: String?
    let rpc: CodexRPC
    let model: Model
    var sessions: [String: ChatSession] = [:]
    var needsAttention: ((ChatSession) -> Void)?
    private let launchURL: URL?
    private let launchArguments: [String]
    private var waiting: [(Bool) -> Void] = []
    init(model: Model, rpc: CodexRPC = CodexRPC(), executable: URL? = nil, arguments: [String] = ["app-server", "--stdio"]) {
        self.model = model; self.rpc = rpc; launchURL = executable; launchArguments = arguments
        rpc.event = { [weak self] in self?.receive($0, $1) }
        rpc.serverRequest = { [weak self] in self?.request($0, $1, $2) }
        rpc.disconnected = { [weak self] message in
            guard let self = self else { return }
            self.connected = false; self.connecting = false; self.connectionError = message
            for session in self.uniqueSessions {
                session.resumed = false; session.loading = false
                if session.running || session.sending { session.uncertainDelivery = true; session.error = message }
                session.sending = false; session.ownedTurnID = nil; session.prompts = []
            }
            self.finishConnection(false)
        }
    }
    var uniqueSessions: [ChatSession] { var seen = Set<String>(); return sessions.values.filter { seen.insert($0.id).inserted } }
    var activeCount: Int { uniqueSessions.filter { $0.running || $0.sending }.count }
    func connect(_ completion: @escaping (Bool) -> Void = { _ in }) {
        if connected { completion(true); return }
        waiting.append(completion)
        guard !connecting else { return }; connecting = true; connectionError = nil
        guard let executable = launchURL ?? CodexRPC.executable() else {
            connecting = false; connectionError = "未找到 Codex CLI。请安装或更新 Codex CLI 后点击重新连接；仍可在 Codex 中打开任务。"
            finishConnection(false); return
        }
        rpc.launch(executable: executable, arguments: launchArguments, root: model.reader.root) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error): self.connecting = false; self.connectionError = error.localizedDescription; self.finishConnection(false)
            case .success:
                self.rpc.request("initialize", ["clientInfo": ["name": "ai_workbench", "title": "ai工作台", "version": "1.9.1"], "capabilities": ["experimentalApi": true]]) { [weak self] result in
                    guard let self = self else { return }
                    switch result {
                    case .failure(let error): self.rpc.stop(); self.connecting = false; self.connectionError = error.localizedDescription; self.finishConnection(false)
                    case .success: self.rpc.notify("initialized"); self.connected = true; self.connecting = false; self.checkAccount(); self.finishConnection(true)
                    }
                }
            }
        }
    }
    private func finishConnection(_ success: Bool) { let callbacks = waiting; waiting = []; callbacks.forEach { $0(success) } }
    func checkAccount() {
        rpc.request("account/read", ["refreshToken": false]) { [weak self] result in
            guard let self = self else { return }
            if case .success(let data) = result { self.signedIn = data["account"] is [String: Any] || data["requiresOpenaiAuth"] as? Bool == false }
            else { self.signedIn = false }
        }
    }
    func login() {
        connect { [weak self] ready in
            guard let self = self, ready else { return }
            self.rpc.request("account/login/start", ["type": "chatgpt"]) { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let data):
                    guard let value = data["authUrl"] as? String, let url = URL(string: value), url.scheme == "https", let host = url.host,
                          host == "openai.com" || host.hasSuffix(".openai.com") || host == "chatgpt.com" || host.hasSuffix(".chatgpt.com") else { self.connectionError = "未取得有效登录地址，请在 Codex CLI 中登录后重新连接。"; return }
                    NSWorkspace.shared.open(url)
                case .failure(let error): self.connectionError = error.localizedDescription
                }
            }
        }
    }
    func session(for row: TaskRow) -> ChatSession {
        if let saved = sessions[row.id] { saved.title = row.title; return saved }
        let session = ChatSession(id: row.id, threadID: row.id, title: row.title.isEmpty ? "未命名任务" : row.title, workspace: row.path, draft: model.preferences.dictionary(forKey: "chatDrafts")?[row.id] as? String ?? "")
        session.externalBusy = row.state == "运行中"; sessions[row.id] = session; return session
    }
    func newSession(workspace: String, prompt: String) -> ChatSession {
        let key = "draft:" + workspace
        if let saved = sessions[key], saved.threadID == nil { if !prompt.isEmpty { saved.draft = prompt }; return saved }
        let session = ChatSession(id: UUID().uuidString, threadID: nil, title: "新建任务", workspace: workspace, draft: prompt.isEmpty ? model.preferences.dictionary(forKey: "chatDrafts")?[key] as? String ?? "" : prompt)
        sessions[key] = session; return session
    }
    func saveDraft(_ session: ChatSession) {
        var drafts = model.preferences.dictionary(forKey: "chatDrafts") as? [String: String] ?? [:]
        drafts[session.threadID ?? session.initialDraftKey] = session.draft.isEmpty ? nil : session.draft
        model.preferences.set(drafts, forKey: "chatDrafts")
    }
    func load(_ session: ChatSession, resolveDelivery: Bool = false) {
        guard let id = session.threadID, !session.loading, !session.sending, !session.running else { return }
        session.loading = true
        connect { [weak self, weak session] ready in
            guard let self = self, let session = session else { return }
            guard ready else { session.loading = false; return }
            self.rpc.request("thread/read", ["threadId": id, "includeTurns": true]) { [weak self, weak session] result in
                guard let self = self, let session = session else { return }
                session.loading = false
                switch result {
                case .failure(let error): session.error = "无法读取此任务：" + error.localizedDescription + "。可在 Codex 中继续。"
                case .success(let data):
                    if let thread = data["thread"] as? [String: Any] {
                        self.hydrate(session, thread: thread)
                        if resolveDelivery { session.uncertainDelivery = false; session.error = nil }
                        else if session.error?.hasPrefix("无法读取此任务") == true { session.error = nil }
                    }
                }
            }
        }
    }
    private func hydrate(_ session: ChatSession, thread: [String: Any], replaceMessages: Bool = true) {
        if let name = thread["name"] as? String, !name.isEmpty { session.title = name }
        if let cwd = thread["cwd"] as? String { session.workspace = cwd }
        let turns = thread["turns"] as? [[String: Any]] ?? []
        if replaceMessages { session.messages = turns.flatMap { ($0["items"] as? [[String: Any]] ?? []).compactMap { item in
            guard ["userMessage", "agentMessage"].contains(item["type"] as? String ?? "") else { return nil }
            return ChatMessage.item(item)
        } } }
        let busyInHistory = turns.last?["status"] as? String == "inProgress"
        let busyInReader = session.threadID.flatMap { id in model.rows.first { $0.id == id } }?.state == "运行中"
        session.externalBusy = busyInHistory || busyInReader
    }
    func send(_ session: ChatSession) {
        guard session.canSend, connected, signedIn else { return }
        // Check the latest snapshot again before loading a second executor for a desktop turn.
        if let id = session.threadID, model.rows.first(where: { $0.id == id })?.state == "运行中" { session.externalBusy = true; return }
        if !session.workspace.isEmpty {
            var directory: ObjCBool = false
            guard session.workspace.hasPrefix("/"), FileManager.default.fileExists(atPath: session.workspace, isDirectory: &directory), directory.boolValue else { session.error = "项目目录不存在，请选择有效目录。"; return }
        }
        session.sending = true; session.error = nil
        let text = session.draft
        let isNew = session.threadID == nil
        if isNew && session.workspace.isEmpty {
            let folder = URL(fileURLWithPath: model.reader.root).appendingPathComponent("ai-workbench-tasks")
            do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); session.workspace = folder.path }
            catch { session.sending = false; session.error = "无法创建任务目录：" + error.localizedDescription; return }
        }
        func startTurn() {
            guard let id = session.threadID else { session.sending = false; return }
            rpc.request("turn/start", ["threadId": id, "input": [["type": "text", "text": text]], "approvalPolicy": "on-request"]) { [weak self, weak session] result in
                guard let self = self, let session = session else { return }
                session.sending = false
                switch result {
                case .failure(let error): session.error = error.localizedDescription; session.uncertainDelivery = true
                case .success(let data):
                    if session.draft == text { session.draft = ""; self.saveDraft(session) }
                    if let turn = data["turn"] as? [String: Any] { self.applyTurn(session, turn: turn, completed: false) }
                    self.model.refresh()
                }
            }
        }
        if session.resumed { startTurn(); return }
        var params: [String: Any] = ["approvalPolicy": "on-request", "sandbox": "workspace-write"]
        if !session.workspace.isEmpty { params["cwd"] = session.workspace }
        if let id = session.threadID { params["threadId"] = id; params["excludeTurns"] = true }
        else { params["serviceName"] = "ai_workbench" }
        rpc.request(isNew ? "thread/start" : "thread/resume", params) { [weak self, weak session] result in
            guard let self = self, let session = session else { return }
            switch result {
            case .failure(let error): session.sending = false; session.error = "此任务暂时不能在工作台续聊：" + error.localizedDescription + "。未发送内容已保留，可在 Codex 中继续。"
            case .success(let data):
                guard let thread = data["thread"] as? [String: Any], let id = thread["id"] as? String else { session.sending = false; session.error = "Codex 返回的任务格式不兼容。"; return }
                self.hydrate(session, thread: thread, replaceMessages: false)
                if session.externalBusy { session.sending = false; session.error = "此任务正在执行，请结束后再发送。"; return }
                session.threadID = id; self.sessions[id] = session; session.resumed = true
                session.ownedExecutor = true
                if isNew {
                    session.title = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
                    self.rpc.request("thread/name/set", ["threadId": id, "name": session.title]) { _ in }
                    var drafts = self.model.preferences.dictionary(forKey: "chatDrafts") as? [String: String] ?? [:]
                    drafts[session.initialDraftKey] = nil; self.model.preferences.set(drafts, forKey: "chatDrafts"); self.saveDraft(session)
                }
                startTurn()
            }
        }
    }
    func stop(_ session: ChatSession) {
        guard let id = session.threadID, let turn = session.ownedTurnID else { return }
        rpc.request("turn/interrupt", ["threadId": id, "turnId": turn]) { [weak session] result in if case .failure(let error) = result { session?.error = error.localizedDescription } }
    }
    func answer(_ session: ChatSession, prompt: ChatPrompt, result: [String: Any]) {
        guard session.prompts.contains(where: { $0.id == prompt.id }) else { return }
        rpc.respond(prompt.wireID, result: result); session.prompts.removeAll { $0.id == prompt.id }
    }
    private func applyTurn(_ session: ChatSession, turn: [String: Any], completed: Bool) {
        for item in turn["items"] as? [[String: Any]] ?? [] { if let message = ChatMessage.item(item) { session.upsert(message) } }
        let state = turn["status"] as? String ?? "inProgress"
        let turnID = turn["id"] as? String ?? ""
        if completed { session.finishedTurns.insert(turnID) }
        if !session.finishedTurns.contains(turnID) { session.ownedTurnID = state == "inProgress" ? turnID : nil }
        else if session.ownedTurnID == turnID { session.ownedTurnID = nil }
        if let error = turn["error"] as? [String: Any] { session.error = error["message"] as? String }
        if completed { session.prompts = []; session.externalBusy = false; model.refresh() }
    }
    func receive(_ method: String, _ params: [String: Any]) {
        if method == "account/login/completed" || method == "account/updated" { checkAccount(); return }
        guard let id = params["threadId"] as? String, let session = sessions[id] else { return }
        switch method {
        case "item/agentMessage/delta": session.appendDelta(id: params["itemId"] as? String ?? "live", text: params["delta"] as? String ?? "")
        case "item/started", "item/completed":
            if let item = params["item"] as? [String: Any], let message = ChatMessage.item(item) { session.upsert(message) }
        case "turn/started", "turn/completed":
            if session.ownedExecutor, let turn = params["turn"] as? [String: Any] { applyTurn(session, turn: turn, completed: method == "turn/completed") }
        case "error": session.error = (params["error"] as? [String: Any])?["message"] as? String
        case "thread/name/updated": if let name = params["name"] as? String { session.title = name }
        case "serverRequest/resolved":
            if let value = params["requestId"] { session.prompts.removeAll { $0.id == String(describing: value) } }
        default: break
        }
    }
    func request(_ id: Any, _ method: String, _ params: [String: Any]) {
        guard let thread = params["threadId"] as? String, let session = sessions[thread],
              ["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/tool/requestUserInput"].contains(method) else {
            rpc.reject(id, message: "ai工作台暂不支持此交互。请在 Codex 中继续；不会自动授权或执行此请求。")
            if let thread = params["threadId"] as? String { sessions[thread]?.error = "此任务需要 Codex 专属交互，请在 Codex 中继续。" }
            return
        }
        let prompt = ChatPrompt(id: String(describing: id), wireID: id, method: method, params: params)
        session.prompts.append(prompt); needsAttention?(session)
    }
}

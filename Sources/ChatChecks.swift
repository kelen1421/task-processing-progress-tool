import Foundation

enum ChatChecks {
    static func run(python: String, fixture: String, root: String) {
        let suite = "local.codex.progress.chat-test." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = Model(reader: Reader(root: root), preferences: preferences)
        precondition(model.chatDestination == .builtIn && model.recentChatCount == 10)
        model.chatDestination = .codex; model.recentChatCount = 5; model.settings.openMode = .double
        let restored = Model(reader: Reader(root: root), preferences: preferences)
        precondition(restored.chatDestination == .codex && restored.recentChatCount == 5 && restored.settings.openMode == .double)
        for destination in TaskChatDestination.allCases {
            model.chatDestination = destination
            precondition(model.settings.openMode.action(clickCount: 2) == .open)
            precondition(model.taskClickHelp.contains(destination == .builtIn ? "内置对话" : "Codex 对话"))
        }
        let service = ChatService(model: model, executable: URL(fileURLWithPath: python), arguments: [fixture])
        defer { service.rpc.stop() }
        func wait(_ condition: () -> Bool) {
            let end = Date().addingTimeInterval(15)
            while !condition() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            precondition(condition(), "Chat protocol check timed out")
        }
        service.connect(); wait { service.connected && service.signedIn }
        let session = service.session(for: TaskRow(id: "fixture", title: "示例", project: "测试", path: root))
        service.load(session); wait { !session.loading && session.messages.count == 24 }
        precondition(session.recentMessages(5).map(\.id) == (19..<24).map { "old-\($0)" })
        session.upsert(ChatMessage(id: "tool", role: "activity", text: "运行工具"))
        precondition(session.recentMessages(10).count == 10 && session.recentMessages(10).last?.id == "old-23")
        session.draft = "未发送草稿"; service.saveDraft(session)
        precondition(preferences.dictionary(forKey: "chatDrafts")?["fixture"] as? String == session.draft)
        func send(_ text: String) { session.draft = text; service.send(session) }
        send("完整发送"); wait { !session.sending && !session.running && session.draft.isEmpty }
        precondition(session.messages.contains { $0.text == "你好，回复正在同步。" })
        precondition(session.messages.contains { $0.id == "old-23" }, "Resume must preserve displayed recent history")
        send("等待停止"); wait { session.running && !session.sending }
        service.stop(session); wait { !session.running }
        send("早结束"); wait { !session.sending }; precondition(!session.running, "A late start acknowledgement must not reactivate a completed turn")
        send("审批测试"); wait { !session.prompts.isEmpty }
        precondition(session.running)
        service.answer(session, prompt: session.prompts[0], result: ["decision": "decline"]); wait { !session.running }
        send("问题测试"); wait { !session.prompts.isEmpty }
        service.answer(session, prompt: session.prompts[0], result: ["answers": ["choice": ["answers": ["选项一"]]]]); wait { !session.running }
        send("不支持的交互"); wait { !session.running && !session.sending }
        precondition(session.error?.contains("专属交互") == true)
        let busy = service.session(for: TaskRow(id: "busy", title: "忙碌任务", project: "测试", path: root))
        service.load(busy); wait { !busy.loading }; busy.draft = "不会发送"; service.send(busy)
        precondition(busy.externalBusy && !busy.sending)
        let unavailable = service.session(for: TaskRow(id: "unsupported-history", title: "不兼容", project: "测试", path: root))
        unavailable.draft = "保留内容"; service.send(unavailable); wait { !unavailable.sending }
        precondition(unavailable.draft == "保留内容" && unavailable.error != nil)
        let fresh = service.newSession(workspace: "", prompt: "新建测试")
        service.saveDraft(fresh); service.send(fresh); wait { fresh.threadID != nil && !fresh.running && !fresh.sending }
        precondition(fresh.workspace.hasPrefix(root + "/") && preferences.dictionary(forKey: "chatDrafts")?[fresh.initialDraftKey] == nil)
        send("连接中断"); wait { !service.connected }
        precondition(session.uncertainDelivery && !session.canSend)
        service.connect(); wait { service.connected && service.signedIn }
        service.load(session); wait { !session.loading }; precondition(session.uncertainDelivery, "Polling must not clear an uncertain delivery")
        service.load(session, resolveDelivery: true); wait { !session.loading }; precondition(!session.uncertainDelivery)
        print("PASS: exclusive chat destination, recent messages, preferences, drafts, fragmented UTF-8 RPC, streamed replies, stopping, early completion, approvals, questions, unsupported interactions, busy tasks, resume errors, new workspace and disconnect/reconnect")
    }
}

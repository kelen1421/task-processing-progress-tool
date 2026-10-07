import Cocoa

enum ChatWindowChecks {
    static func run(python: String, fixture: String, root: String) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let suite = "local.codex.progress.window-check." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = Model(preferences: preferences)
        let service = ChatService(model: model, executable: URL(fileURLWithPath: python), arguments: [fixture])
        let delegate = AppDelegate(model: model, chatService: service, permissionRenewal: AccessibilityPermissionRenewal(reset: { true }, request: {}))
        AppDelegate.shared = delegate
        let controller = delegate.chatController
        defer { controller.shutdown() }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(3)
            while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        let first = service.session(for: TaskRow(id: "window-first", title: "First test window", project: "fixture", path: root))
        let second = service.session(for: TaskRow(id: "window-second", title: "Second test window", project: "fixture", path: root))
        controller.show(first, activate: false); controller.show(second, activate: false)
        defer { controller.taskWindow(first.id)?.close(); controller.taskWindow(second.id)?.close() }
        precondition(controller.isOpen(taskID: first.id) && controller.isOpen(taskID: second.id))
        controller.minimize(taskID: first.id)
        wait { !controller.isOpen(taskID: first.id) }
        precondition(!controller.isOpen(taskID: first.id) && controller.isOpen(taskID: second.id), "Minimize the clicked task, not the last opened task")
        controller.minimize(taskID: "missing")
        precondition(controller.isOpen(taskID: second.id), "A missing task must not minimize another window")
        controller.show(first, activate: false)
        wait { controller.isOpen(taskID: first.id) }
        precondition(controller.isOpen(taskID: first.id), "Reopen restores the same minimized window")
        let original = controller.taskWindow(first.id)
        controller.taskWindow(first.id)?.close()
        precondition(!controller.isOpen(taskID: first.id), "Closed windows count as closed")
        controller.show(first, activate: false)
        precondition(controller.taskWindow(first.id) === original && controller.isOpen(taskID: first.id))
        let fresh = service.newSession(workspace: root, prompt: "")
        controller.show(fresh, activate: false)
        defer { controller.taskWindow(fresh.id)?.close() }
        fresh.threadID = "assigned-thread"
        precondition(controller.taskWindow("assigned-thread") === controller.taskWindow(fresh.id), "A new task's assigned ID keeps the original window")
        controller.minimize(taskID: "assigned-thread")
        wait { !controller.isOpen(taskID: "assigned-thread") }
        precondition(!controller.isOpen(taskID: "assigned-thread") && controller.isOpen(taskID: first.id))
        print("PASS: per-task native window minimize, restore, close, missing task, assigned thread ID; no messages sent")
    }
}

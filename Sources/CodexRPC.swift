import Foundation

struct ChatFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A private stdio connection. It never exposes a network listener or logs credentials.
final class CodexRPC {
    typealias Reply = (Result<[String: Any], Error>) -> Void
    var event: ((String, [String: Any]) -> Void)?
    var serverRequest: ((Any, String, [String: Any]) -> Void)?
    var disconnected: ((String) -> Void)?
    private let queue = DispatchQueue(label: "ai.workbench.chat.rpc")
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var stderr: FileHandle?
    private var buffer = Data()
    private var pending: [Int: Reply] = [:]
    private var sequence = 0
    private var generation = 0

    static func executable() -> URL? {
        let home = NSHomeDirectory()
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/codex" }
        let candidates = paths + ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", home + "/.local/bin/codex", home + "/.npm-global/bin/codex", "/Applications/Codex.app/Contents/Resources/codex", "/Applications/ChatGPT.app/Contents/Resources/codex"]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
    func launch(executable: URL, arguments: [String] = ["app-server", "--stdio"], root: String, completion: @escaping Reply) {
        queue.async { [self] in
            guard process == nil else { deliver(completion, .failure(ChatFailure(message: "对话服务已连接。"))); return }
            signal(SIGPIPE, SIG_IGN)
            generation += 1; let token = generation
            let child = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe(), errorPipe = Pipe()
            child.executableURL = executable; child.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = root
            environment["PATH"] = executable.deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin") + ":/opt/homebrew/bin:/usr/local/bin"
            child.environment = environment; child.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
            child.standardInput = stdinPipe; child.standardOutput = stdoutPipe; child.standardError = errorPipe
            input = stdinPipe.fileHandleForWriting; output = stdoutPipe.fileHandleForReading; stderr = errorPipe.fileHandleForReading
            output?.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                self?.queue.async { [weak self] in
                    guard let self = self, self.generation == token else { return }
                    if data.isEmpty { handle.readabilityHandler = nil; return }
                    self.consume(data)
                }
            }
            // Drain diagnostics without copying tokens, conversation text or paths to logs.
            stderr?.readabilityHandler = { handle in if handle.availableData.isEmpty { handle.readabilityHandler = nil } }
            child.terminationHandler = { [weak self] _ in
                self?.queue.async { [weak self] in
                    guard let self = self, self.generation == token else { return }
                    self.fail("对话连接已断开。可重新连接后检查聊天记录；未发送的内容会保留。")
                }
            }
            do { try child.run(); process = child; deliver(completion, .success([:])) }
            catch { fail("无法启动 Codex 对话服务：" + error.localizedDescription); deliver(completion, .failure(error)) }
        }
    }
    func request(_ method: String, _ params: [String: Any], timeout: Double = 45, completion: @escaping Reply) {
        queue.async { [self] in
            guard process?.isRunning == true else { deliver(completion, .failure(ChatFailure(message: "对话服务未连接。"))); return }
            sequence += 1; let id = sequence
            pending[id] = completion
            do { try write(["id": id, "method": method, "params": params]) }
            catch { fail("发送失败，对话连接已断开。"); return }
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self = self, let reply = self.pending.removeValue(forKey: id) else { return }
                // A timeout may have reached the server. Never replay a turn automatically.
                self.deliver(reply, .failure(ChatFailure(message: "对话请求超时。请刷新记录确认是否已发送，再决定是否重试。")))
            }
        }
    }
    func notify(_ method: String, _ params: [String: Any] = [:]) {
        queue.async { [self] in do { try write(["method": method, "params": params]) } catch { fail("对话连接已断开。") } }
    }
    func respond(_ id: Any, result: [String: Any]) {
        queue.async { [self] in do { try write(["id": id, "result": result]) } catch { fail("无法提交确认结果。") } }
    }
    func reject(_ id: Any, message: String) {
        queue.async { [self] in do { try write(["id": id, "error": ["code": -32601, "message": message]]) } catch { fail("对话连接已断开。") } }
    }
    func stop() {
        // Send termination before NSApplication finishes quitting.
        queue.sync {
            generation += 1; process?.terminationHandler = nil
            fail("对话服务已停止。", inform: false)
        }
    }
    private func write(_ object: [String: Any]) throws {
        guard let input = input else { throw ChatFailure(message: "连接已关闭。") }
        var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
        try input.write(contentsOf: data)
    }
    private func consume(_ data: Data) {
        buffer.append(data)
        guard buffer.count <= 32 * 1024 * 1024 else { process?.terminate(); fail("聊天记录过大，请在 Codex 中查看。" ); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let method = object["method"] as? String {
                let params = object["params"] as? [String: Any] ?? [:]
                if let id = object["id"] { DispatchQueue.main.async { [weak self] in self?.serverRequest?(id, method, params) } }
                else { DispatchQueue.main.async { [weak self] in self?.event?(method, params) } }
            } else if let id = object["id"] as? Int, let reply = pending.removeValue(forKey: id) {
                if let error = object["error"] as? [String: Any] { deliver(reply, .failure(ChatFailure(message: error["message"] as? String ?? "Codex 请求失败。"))) }
                else { deliver(reply, .success(object["result"] as? [String: Any] ?? [:])) }
            }
        }
    }
    private func deliver(_ reply: @escaping Reply, _ result: Result<[String: Any], Error>) { DispatchQueue.main.async { reply(result) } }
    private func fail(_ message: String, inform: Bool = true) {
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        output?.readabilityHandler = nil; stderr?.readabilityHandler = nil
        try? input?.close(); try? output?.close(); try? stderr?.close()
        input = nil; output = nil; stderr = nil; process = nil; buffer = Data()
        let replies = Array(pending.values); pending.removeAll()
        for reply in replies { deliver(reply, .failure(ChatFailure(message: message))) }
        if inform { DispatchQueue.main.async { [weak self] in self?.disconnected?(message) } }
    }
}

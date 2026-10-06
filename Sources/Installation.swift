import Cocoa
import Darwin

enum AppInstallationError: LocalizedError {
    case invalidApplication, busy, stopFailed, signatureFailed, unrelatedDestination
    var errorDescription: String? {
        switch self {
        case .invalidApplication: return "未找到有效的 ai工作台应用。"
        case .busy: return "另一个安装正在进行，请稍后再试。"
        case .stopFailed: return "请退出正在运行的旧版，再重新安装。"
        case .signatureFailed: return "应用文件校验未通过，请重新下载完整安装包。"
        case .unrelatedDestination: return "安装位置存在其他应用，请先移走同名文件。"
        }
    }
}
enum AppInstallation {
    static let identifier = "local.codex.progress"
    static let currentName = "ai工作台.app"
    static let legacyName = "任务处理进度.app"
    static let binary = "Contents/MacOS/CodexProgress"
    static func info(_ application: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: application.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
    static func owns(_ application: URL) -> Bool {
        info(application)?["CFBundleIdentifier"] as? String == identifier && FileManager.default.isExecutableFile(atPath: application.appendingPathComponent(binary).path)
    }
    static func version(_ application: URL) -> [Int] {
        let string = info(application)?["CFBundleShortVersionString"] as? String ?? "0"
        return string.split(separator: ".").map { Int($0) ?? 0 }
    }
    static func newer(_ left: URL, than right: URL) -> Bool {
        let a = version(left), b = version(right)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
    static func run(_ executable: String, _ arguments: [String]) -> Bool {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 } catch { return false }
    }
    static func verified(_ application: URL) -> Bool { owns(application) && run("/usr/bin/codesign", ["--verify", "--deep", "--strict", application.path]) }
    static func same(_ left: URL, _ right: URL) -> Bool {
        if left.standardizedFileURL.path == right.standardizedFileURL.path { return true }
        let seal = "Contents/_CodeSignature/CodeResources"
        return FileManager.default.contentsEqual(atPath: left.appendingPathComponent(binary).path, andPath: right.appendingPathComponent(binary).path)
            && FileManager.default.contentsEqual(atPath: left.appendingPathComponent("Contents/Info.plist").path, andPath: right.appendingPathComponent("Contents/Info.plist").path)
            && FileManager.default.contentsEqual(atPath: left.appendingPathComponent(seal).path, andPath: right.appendingPathComponent(seal).path)
    }
    static func stopOldInstances(keeping application: URL?) throws {
        let processes = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == identifier && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                && (application == nil || $0.bundleURL?.standardizedFileURL.path != application?.standardizedFileURL.path)
        }
        for process in processes { _ = process.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while processes.contains(where: { Darwin.kill($0.processIdentifier, 0) == 0 }) {
            guard Date() < deadline else { throw AppInstallationError.stopFailed }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
    static func install(source: URL, userApplications: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications"), systemApplications: URL = URL(fileURLWithPath: "/Applications"), stop: (URL?) throws -> Void = stopOldInstances) throws -> URL {
        let manager = FileManager.default
        guard verified(source) else { throw AppInstallationError.signatureFailed }
        try manager.createDirectory(at: userApplications, withIntermediateDirectories: true)
        let lockURL = userApplications.appendingPathComponent(".ai-workbench-install.lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw AppInstallationError.busy }
        defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0); Darwin.close(descriptor) }
        guard Darwin.lockf(descriptor, F_TLOCK, 0) == 0 else { throw AppInstallationError.busy }
        let candidates = [userApplications, systemApplications].flatMap { [$0.appendingPathComponent(currentName), $0.appendingPathComponent(legacyName)] }
            .filter { owns($0) }
        let valid = candidates.filter(verified)
        // Keep an existing installation location when writable, and never downgrade a newer app.
        let preferred = candidates.first { $0.lastPathComponent == currentName && manager.isWritableFile(atPath: $0.deletingLastPathComponent().path) }
            ?? candidates.first { manager.isWritableFile(atPath: $0.deletingLastPathComponent().path) }
        let target = (preferred?.deletingLastPathComponent() ?? userApplications).appendingPathComponent(currentName)
        if manager.fileExists(atPath: target.path) {
            let isLink = try target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
            guard owns(target) && !isLink else { throw AppInstallationError.unrelatedDestination }
        }
        let newest = valid.reduce(source) { newest, candidate in newer(candidate, than: newest) ? candidate : newest }
        if !verified(target) || !same(newest, target) {
            let temporary = target.deletingLastPathComponent().appendingPathComponent(".ai-workbench-update-" + UUID().uuidString)
            try manager.createDirectory(at: temporary, withIntermediateDirectories: false)
            defer { try? manager.removeItem(at: temporary) }
            let staged = temporary.appendingPathComponent(currentName), backup = temporary.appendingPathComponent("previous.app")
            guard run("/usr/bin/ditto", [newest.path, staged.path]), verified(staged) else { throw AppInstallationError.signatureFailed }
            try stop(nil)
            if manager.fileExists(atPath: target.path) { try manager.moveItem(at: target, to: backup) }
            do { try manager.moveItem(at: staged, to: target) }
            catch { if manager.fileExists(atPath: backup.path) { try? manager.moveItem(at: backup, to: target) }; throw error }
        }
        try stop(target)
        // Settings stay in the same bundle-ID preference domain; never reset or copy a stale plist.
        for previous in candidates where previous.standardizedFileURL.path != target.standardizedFileURL.path {
            if manager.isWritableFile(atPath: previous.deletingLastPathComponent().path) { try manager.removeItem(at: previous) }
            else { FileHandle.standardError.write(Data("另一个旧版需要手动移除：\(previous.path)\n".utf8)) }
        }
        return target
    }
}

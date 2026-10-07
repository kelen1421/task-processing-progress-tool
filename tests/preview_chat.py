"""Native chat fixture: isolated preferences, fake RPC, no real Codex chat actions."""
import datetime
import json
import os
import platform
import plistlib
import shutil
import sqlite3
import subprocess
import tempfile
import uuid
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
app = Path('/private/tmp/ai-workbench-chat-preview.app')
subprocess.run(['pkill', '-x', 'ChatPreview'], capture_output=True)
if app.exists():
    shutil.rmtree(app)
binary = app / 'Contents/MacOS/ChatPreview'
binary.parent.mkdir(parents=True)
fixtures = app / 'Contents/Resources/fixtures'
fixtures.mkdir(parents=True)
stamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
database = sqlite3.connect(fixtures / 'state_5.sqlite')
database.execute('CREATE TABLE threads(id,title,cwd,rollout_path,archived,agent_role,source,updated_at,name,project_id)')
for index, name, title in [(1, 'fixture', '内置对话测试任务'), (2, 'second', '另一个测试任务')]:
    rollout = fixtures / (name + '.jsonl')
    rollout.write_text('')
    database.execute('INSERT INTO threads VALUES(?,?,?,?,0,NULL,?,?,NULL,NULL)', (name, title, str(fixtures), str(rollout), 'desktop', index))
database.commit()
database.close()
suite = 'local.codex.progress.preview.' + str(uuid.uuid4())
shutil.copy(root / 'tests/chat_fixture.py', fixtures / 'chat_fixture.py')
runner = r'''
final class PreviewCounts {
    var opens = 0, minimizes = 0
    var changed: (() -> Void)?
}
final class PreviewDelegate: NSObject, NSApplicationDelegate {
    let production: AppDelegate
    let counts = PreviewCounts()
    override init() {
        let preferences = UserDefaults(suiteName: PREVIEW_SUITE)!
        let model = Model(reader: Reader(root: FIXTURE_PATH), preferences: preferences, now: Date(timeIntervalSince1970: 0))
        model.togglePin("fixture"); model.togglePin("second")
        model.settings.backgroundOpacity = 0.5
        if COMBINED_CLICKS {
            model.settings.openMode = .both
            model.chatDestination = .codex
        }
        let service = ChatService(model: model, executable: URL(fileURLWithPath: PYTHON_PATH), arguments: [FIXTURE_PATH + "/chat_fixture.py"])
        let counters = counts
        production = AppDelegate(model: model, chatService: service, externalChatOpener: { _ in counters.opens += 1; counters.changed?(); return true }, externalChatMinimizer: { counters.minimizes += 1; counters.changed?() })
        super.init()
        counts.changed = { [weak self] in self?.updateTitle() }
    }
    func updateTitle() { production.panel.title = "测试 · 外部打开 \(counts.opens) · 外部最小化 \(counts.minimizes)" }
    func applicationDidFinishLaunching(_ notification: Notification) {
        production.applicationDidFinishLaunching(notification)
        updateTitle()
        production.showPersonalization()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            _ = self.production.openTaskChatURL(URL(string: "codex://threads/fixture")!)
        }
    }
    func applicationDidBecomeActive(_ notification: Notification) { production.applicationDidBecomeActive(notification) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateNow }
    func applicationWillTerminate(_ notification: Notification) { production.chatController.shutdown() }
}
let app = NSApplication.shared
let delegate = PreviewDelegate()
app.delegate = delegate
app.run()
'''.replace('PREVIEW_SUITE', json.dumps(suite)).replace('FIXTURE_PATH', json.dumps(str(fixtures))).replace('PYTHON_PATH', json.dumps(sys.executable)).replace('COMBINED_CLICKS', 'true' if os.environ.get('TASK_PROGRESS_PREVIEW_BOTH_OPEN') == '1' else 'false')
with tempfile.TemporaryDirectory(prefix='task-progress-preview-build-') as temporary:
    sources = Path(temporary)
    for source in (root / 'Sources').glob('*.swift'):
        text = source.read_text()
        if source.name == 'main.swift':
            text = text.split('let app = NSApplication.shared\nlet delegate = AppDelegate()\n')[0] + runner
        (sources / source.name).write_text(text)
    sdk = os.environ.get('TASK_PROGRESS_SDK') or subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    compatible = '/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk'
    if 'MacOSX27.0.sdk' in sdk and Path(compatible).is_dir():
        sdk = compatible
    subprocess.run(['xcrun', 'swiftc', '-sdk', sdk, '-target', platform.machine() + '-apple-macosx13.0', *map(str, sources.glob('*.swift')), '-o', str(binary), '-framework', 'Cocoa', '-framework', 'SwiftUI', '-framework', 'ApplicationServices', '-lsqlite3', '-module-cache-path', str(sources / 'modules')], check=True)
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'ChatPreview','CFBundleIdentifier':'local.codex.progress.chat-preview','CFBundleName':'内置对话界面预览','LSUIElement':True,'LSMinimumSystemVersion':'13.0'}))
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
subprocess.run(['open', str(app)], check=True)
print(app)

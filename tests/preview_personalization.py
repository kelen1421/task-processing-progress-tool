"""Build a separate native UI fixture. Chat actions only change its window title."""
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
from pathlib import Path

root = Path(__file__).resolve().parents[1]
app = Path('/private/tmp/task-progress-personalization-preview.app')
subprocess.run(['pkill', '-x', 'PersonalPreview'], capture_output=True)
if app.exists():
    shutil.rmtree(app)
binary = app / 'Contents/MacOS/PersonalPreview'
binary.parent.mkdir(parents=True)
fixtures = app / 'Contents/Resources/fixtures'
fixtures.mkdir(parents=True)
stamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
database = sqlite3.connect(fixtures / 'state_5.sqlite')
database.execute('CREATE TABLE threads(id,title,cwd,rollout_path,archived,agent_role,source,updated_at,name,project_id)')
for index, name, title, events in [
    (1, 'preview-active', '正在开发的示例任务', ['task_started']),
    (2, 'preview-done', '已经完成的示例任务', ['task_started', 'task_complete']),
    (3, 'preview-waiting', '等待开始的示例任务', []),
    (4, 'preview-second-active', '第四个运行中的示例任务', ['task_started']),
]:
    rollout = fixtures / (name + '.jsonl')
    entries = [{'timestamp': stamp, 'type': 'event_msg', 'payload': {'type': event}} for event in events]
    if name == 'preview-active':
        entries.append({'timestamp': stamp, 'type': 'response_item', 'payload': {'type': 'custom_tool_call', 'name': 'apply_patch', 'input': 'fixture'}})
    rollout.write_text(''.join(json.dumps(entry, ensure_ascii=False) + '\n' for entry in entries))
    database.execute('INSERT INTO threads VALUES(?,?,?,?,0,NULL,?,?,NULL,NULL)', (name, title, '/fixture', str(rollout), 'desktop', index))
database.commit()
database.close()
suite = 'local.codex.progress.preview.' + str(uuid.uuid4())
runner = r'''
final class PreviewDelegate: NSObject, NSApplicationDelegate {
    let production: AppDelegate
    var opens = 0, minimizes = 0
    override init() {
        let preferences = UserDefaults(suiteName: PREVIEW_SUITE)!
        let model = Model(reader: Reader(root: FIXTURE_PATH), preferences: preferences, now: Date(timeIntervalSince1970: 0))
        if model.pinnedTaskIDs.isEmpty { model.togglePin("preview-done"); model.togglePin("preview-waiting") }
        production = AppDelegate(model: model)
        super.init()
    }
    func updateTitle() { production.panel.title = "预览 · 打开 \(opens) 次 · 最小化 \(minimizes) 次" }
    func applicationDidFinishLaunching(_ notification: Notification) {
        production.applicationDidFinishLaunching(notification)
        let dashboard = Dashboard(model: production.model, onMinimize: { [weak self] in self?.minimizes += 1; self?.updateTitle() }, openChatURL: { [weak self] _ in self?.opens += 1; self?.updateTitle(); return true })
        let host = NSHostingView(rootView: dashboard); host.sizingOptions = []
        production.panel.contentView = host
        updateTitle()
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: production.panel, queue: .main) { [weak self] _ in
            guard let self = self, let screen = self.production.panel.screen?.visibleFrame else { return }
            self.updateTitle()
            self.production.panel.title += " · 距右边缘 \(Int(screen.maxX - self.production.panel.frame.maxX))"
        }
    }
    func applicationDidBecomeActive(_ notification: Notification) { production.applicationDidBecomeActive(notification) }
}
let app = NSApplication.shared
let delegate = PreviewDelegate()
app.delegate = delegate
app.run()
'''.replace('PREVIEW_SUITE', json.dumps(suite)).replace('FIXTURE_PATH', json.dumps(str(fixtures)))
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
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'PersonalPreview','CFBundleIdentifier':'local.codex.progress.personalization-preview','CFBundleName':'个性化界面预览','LSUIElement':True,'LSMinimumSystemVersion':'13.0'}))
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
subprocess.run(['open', str(app)], check=True)
print(app)

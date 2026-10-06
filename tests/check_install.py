import importlib.util
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('install_app', root / 'plugin/scripts/install_app.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
source = root / 'dist/任务处理进度.app'
stops = []

with tempfile.TemporaryDirectory() as temporary:
    target = Path(temporary) / 'Applications/任务处理进度.app'
    stop = lambda: stops.append(True)
    assert module.install(source, target, stop=stop) == target
    assert stops == [True]
    assert module.fingerprint(source) == module.fingerprint(target)
    cached = Path(temporary) / 'cache/1.7.1/assets/任务处理进度.app'
    shutil.copytree(source, cached)
    before = target.stat().st_ino
    module.install(cached, target, stop=stop)
    assert target.stat().st_ino == before and stops == [True]
    newer_info = target / 'Contents/Info.plist'
    metadata = plistlib.loads(newer_info.read_bytes())
    metadata['CFBundleShortVersionString'] = '99.0.0'
    newer_info.write_bytes(plistlib.dumps(metadata))
    subprocess.run(['codesign', '--force', '--sign', '-', str(target)], check=True, capture_output=True)
    before = module.fingerprint(target)
    module.install(source, target, stop=stop)
    assert module.fingerprint(target) == before and stops == [True]
    (target / 'Contents/Info.plist').write_bytes(newer_info.read_bytes() + b'\n')
    module.install(source, target, stop=stop)
    assert len(stops) == 2 and module.fingerprint(source) == module.fingerprint(target)
    metadata['CFBundleIdentifier'] = 'fixture.unrelated'
    newer_info.write_bytes(plistlib.dumps(metadata))
    try:
        module.install(source, target, stop=stop)
    except ValueError:
        pass
    else:
        raise AssertionError('Unrelated application was replaced')
    assert plistlib.loads(newer_info.read_bytes())['CFBundleIdentifier'] == 'fixture.unrelated'

print('PASS: stable path, reused identity, old-cache downgrade protection, corrupt bundle repair, unrelated-app protection')

home = Path('/fixture/task-progress-home')
deleted = home / '.codex/plugins/cache/local-personal/task-processing-progress/1.7.0/assets/任务处理进度.app' / module.BINARY
assert module.own_executable(deleted, home)
assert not module.own_executable(home / 'unrelated.app' / module.BINARY, home)
assert not module.own_executable(home / '.codex/plugins/cache/local-personal/other/1.7.0/assets/任务处理进度.app' / module.BINARY, home)
print('PASS: stale process in removed plugin cache recognized, unrelated processes excluded')

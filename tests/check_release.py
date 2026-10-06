import hashlib
import json
import plistlib
import stat
import subprocess
import tempfile
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
version = (root / 'VERSION').read_text().strip()
app_binary = 'Contents/MacOS/CodexProgress'
expected = []
for kind in ['macos-universal', 'codex-plugin']:
    archive = root / 'release' / f'task-processing-progress-{version}-{kind}.zip'
    expected.append(archive.name)
    with zipfile.ZipFile(archive) as package:
        names = package.namelist()
        assert not any(name.startswith('/') or '..' in Path(name).parts for name in names)
        assert not any(name.endswith(('.jsonl', '.sqlite', '.DS_Store')) for name in names)
        bundle = next(name[:-len('Contents/Info.plist')] for name in names if name.endswith('.app/Contents/Info.plist'))
        info = plistlib.loads(package.read(bundle + 'Contents/Info.plist'))
        assert info['CFBundleShortVersionString'] == version
        assert info['CFBundleIdentifier'] == 'local.codex.progress'
        mode = package.getinfo(bundle + app_binary).external_attr >> 16
        assert mode & stat.S_IXUSR, 'Application executable bit must survive ZIP extraction'
        if kind == 'codex-plugin':
            prefix = names[0].split('/')[0] + '/'
            manifest = json.loads(package.read(prefix + 'plugin.json'))
            assert manifest['version'] == version
            assert prefix + '安装个人插件.command' in names
            assert prefix + '.codex-plugin/plugin.json' in names
        with tempfile.TemporaryDirectory() as temporary:
            subprocess.run(['ditto', '-x', '-k', str(archive), temporary], check=True)
            app = Path(temporary) / bundle
            subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
            subprocess.run(['xcrun', 'lipo', str(app / app_binary), '-verify_arch', 'arm64', 'x86_64'], check=True)

checksums = {}
for line in (root / 'release/SHA256SUMS.txt').read_text().splitlines():
    digest, filename = line.split(maxsplit=1)
    checksums[filename] = digest
for filename in expected:
    assert hashlib.sha256((root / 'release' / filename).read_bytes()).hexdigest() == checksums[filename]
print('PASS: release versions, universal architectures, clean archive paths, executable permissions, extracted signatures, plugin contents and checksums')

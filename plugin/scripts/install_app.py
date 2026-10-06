"""Keep plugin launches at one application path, without changing privacy settings."""
import fcntl
import hashlib
import os
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

BUNDLE_ID = 'local.codex.progress'
BINARY = Path('Contents/MacOS/CodexProgress')


def info(app):
    with (app / 'Contents/Info.plist').open('rb') as stream:
        result = plistlib.load(stream)
    if result.get('CFBundleIdentifier') != BUNDLE_ID or not (app / BINARY).is_file():
        raise ValueError(f'目标不是任务处理进度应用：{app}')
    return result


def version(app):
    return tuple(int(part) for part in info(app)['CFBundleShortVersionString'].split('.'))


def fingerprint(app):
    # Compare the sealed bundle, not just its marketing version.
    digest = hashlib.sha256()
    for path in sorted(app.rglob('*')):
        digest.update(str(path.relative_to(app)).encode())
        if path.is_file():
            digest.update(path.read_bytes())
    return digest.digest()


def own_executable(executable, home=None):
    if not str(executable).endswith('/' + str(BINARY)):
        return False
    app = executable.parents[2]
    if app.exists():
        try:
            info(app)
            return True
        except (OSError, ValueError):
            return False
    # Codex removes the old cache on an upgrade, while its process can still be alive.
    home = home or Path.home()
    try:
        parts = executable.relative_to(home / '.codex/plugins/cache').parts
    except ValueError:
        return False
    return (len(parts) == 8 and parts[1] == 'task-processing-progress'
            and parts[3:] == ('assets', '任务处理进度.app', 'Contents', 'MacOS', 'CodexProgress'))


def stop_own_instances(keep=None):
    processes = subprocess.check_output(['/bin/ps', '-axo', 'pid=,comm='], text=True)
    stopped = []
    for line in processes.splitlines():
        fields = line.strip().split(maxsplit=1)
        if len(fields) != 2:
            continue
        executable = Path(fields[1])
        if keep is not None and executable == keep:
            continue
        if not own_executable(executable):
            continue
        pid = int(fields[0])
        try:
            os.kill(pid, signal.SIGTERM)
            stopped.append(pid)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 5
    for pid in stopped:
        while True:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            if time.monotonic() >= deadline:
                raise RuntimeError('请退出正在运行的任务处理进度，再重新打开插件。')
            time.sleep(0.1)


def install(source, target, stop=stop_own_instances):
    source, target = source.resolve(), target.expanduser().absolute()
    info(source)
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(source)], check=True)
    target.parent.mkdir(parents=True, exist_ok=True)
    lock = target.parent / '.task-processing-progress-install.lock'
    with lock.open('a') as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        if target.is_symlink():
            raise ValueError('应用安装位置是符号链接，请先移走该链接。')
        if target.exists():
            info(target)  # Never replace an unrelated app with the same display name.
            valid = subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(target)], capture_output=True).returncode == 0
            if valid and (version(target) > version(source) or fingerprint(source) == fingerprint(target)):
                return target  # An older cached plugin must not downgrade the running app.
        with tempfile.TemporaryDirectory(prefix='.task-progress-', dir=target.parent) as temporary:
            staged = Path(temporary) / target.name
            subprocess.run(['/usr/bin/ditto', str(source), str(staged)], check=True)
            subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(staged)], check=True)
            stop()  # Stop before replacing its binary; permission checks must use the new process.
            backup = Path(temporary) / 'previous.app'
            if target.exists():
                target.rename(backup)
            try:
                staged.rename(target)
            except OSError:
                if backup.exists():
                    backup.rename(target)
                raise
    return target


if __name__ == '__main__':
    try:
        source = Path(__file__).resolve().parents[1] / 'assets/任务处理进度.app'
        target = install(source, Path.home() / 'Applications/任务处理进度.app')
        stop_own_instances(keep=target / BINARY)
        print(target)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f'无法安装浮窗：{error}', file=sys.stderr)
        sys.exit(1)

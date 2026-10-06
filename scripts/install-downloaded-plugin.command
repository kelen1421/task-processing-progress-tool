#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
command -v codex >/dev/null || { print -u2 '未找到 Codex 命令。可以直接打开 assets 中的「任务处理进度.app」使用浮窗；安装到个人插件需要 Codex CLI。'; read -r '?按回车退出'; exit 1; }
[[ -x 'assets/任务处理进度.app/Contents/MacOS/CodexProgress' ]] || { print -u2 '未找到插件内的浮窗应用，请重新解压完整插件包。'; exit 1; }
python3 - <<'PY'
from pathlib import Path
import json, shutil
root = Path.cwd()
personal = Path.home()/'.codex/plugins/task-processing-progress'
shutil.copytree(root, personal, dirs_exist_ok=True)
marketplace = Path.home()/'.agents/plugins/marketplace.json'
marketplace.parent.mkdir(parents=True, exist_ok=True)
catalog = json.loads(marketplace.read_text()) if marketplace.exists() else {'name':'local-personal','interface':{'displayName':'个人插件'},'plugins':[]}
entry = {'name':'task-processing-progress','source':{'source':'local','path':'./.codex/plugins/task-processing-progress'},'policy':{'installation':'AVAILABLE','authentication':'ON_INSTALL'},'category':'Productivity'}
entries = catalog.setdefault('plugins', [])
for index, item in enumerate(entries):
    if item.get('name') == entry['name']:
        entries[index] = entry
        break
else:
    entries.append(entry)
marketplace.write_text(json.dumps(catalog, ensure_ascii=False, indent=2)+'\n')
PY
codex plugin marketplace add "$HOME" --json
MARKETPLACE_NAME="$(python3 -c 'import json,pathlib;print(json.loads((pathlib.Path.home()/".agents/plugins/marketplace.json").read_text())["name"])')"
codex plugin add "task-processing-progress@$MARKETPLACE_NAME" --json
"$HOME/.codex/plugins/task-processing-progress/scripts/control.command" show
print '已安装到个人插件并打开浮窗。'
read -r '?按回车退出'

#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
./build.command
python3 - <<'PY'
from pathlib import Path
import json,shutil
root=Path.cwd()
shutil.copytree(root/'dist/任务处理进度.app',root/'plugin/assets/任务处理进度.app',dirs_exist_ok=True)
personal=Path.home()/'.codex/plugins/task-processing-progress'
shutil.copytree(root/'plugin',personal,dirs_exist_ok=True)
marketplace=Path.home()/'.agents/plugins/marketplace.json'
marketplace.parent.mkdir(parents=True,exist_ok=True)
catalog=json.loads(marketplace.read_text()) if marketplace.exists() else {'name':'local-personal','interface':{'displayName':'个人插件'},'plugins':[]}
entry={'name':'task-processing-progress','source':{'source':'local','path':'./.codex/plugins/task-processing-progress'},'policy':{'installation':'AVAILABLE','authentication':'ON_INSTALL'},'category':'Productivity'}
entries=catalog.setdefault('plugins',[])
for index,item in enumerate(entries):
    if item.get('name')==entry['name']: entries[index]=entry;break
else:entries.append(entry)
marketplace.write_text(json.dumps(catalog,ensure_ascii=False,indent=2)+'\n')
PY
codex plugin marketplace add "$HOME" --json
MARKETPLACE_NAME="$(python3 -c 'import json,pathlib;print(json.loads((pathlib.Path.home()/".agents/plugins/marketplace.json").read_text())["name"])')"
codex plugin add "task-processing-progress@$MARKETPLACE_NAME" --json

import json
import os
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
binary = root / 'dist/ai工作台.app/Contents/MacOS/CodexProgress'
with tempfile.TemporaryDirectory(prefix='ai-workbench-chat-check-') as folder:
    db = sqlite3.connect(Path(folder) / 'state_5.sqlite')
    db.execute('CREATE TABLE threads(id,title,cwd,rollout_path,archived,agent_role,source,updated_at,name,project_id)')
    db.commit()
    db.close()
    subprocess.run([str(binary), '--selfcheck-chat', sys.executable, str(root / 'tests/chat_fixture.py'), folder], check=True, timeout=90)
    subprocess.run([str(binary), '--selfcheck-chat-windows', sys.executable, str(root / 'tests/chat_fixture.py'), folder], check=True, timeout=30)

import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
subprocess.run([str(root / 'dist/ai工作台.app/Contents/MacOS/CodexProgress'), '--selfcheck-installation'], check=True)

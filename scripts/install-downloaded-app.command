#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}"
APP="$ROOT/ai工作台.app"
[[ -x "$APP/Contents/MacOS/CodexProgress" ]] || { print -u2 '请先完整解压安装包，再运行安装或更新。'; exit 1; }
INSTALLED_APP="$("$APP/Contents/MacOS/CodexProgress" --install-app)"
open "$INSTALLED_APP"
print 'ai工作台已安装或更新，原有个性化设置、固定任务和窗口大小已保留。'
read -r '?按回车关闭此窗口'

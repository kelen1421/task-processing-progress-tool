#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
APP="$ROOT/assets/ai工作台.app"
case "${1:-show}" in
  show|start)
    [[ -x "$APP/Contents/MacOS/CodexProgress" ]] || { print -u2 '未找到浮窗应用'; exit 1; }
    APP="$("$APP/Contents/MacOS/CodexProgress" --install-app)"
    open "$APP"
    print '已打开ai工作台'
    ;;
  status)
    if pgrep -x CodexProgress >/dev/null; then print 'ai工作台正在运行'; else print 'ai工作台未运行'; fi
    ;;
  stop)
    if pgrep -x CodexProgress >/dev/null; then pkill -x CodexProgress; fi
    print '已关闭ai工作台'
    ;;
  diagnose)
    "$APP/Contents/MacOS/CodexProgress" --diagnose
    ;;
  *) print -u2 '用法：control.command show|status|stop|diagnose'; exit 2 ;;
esac

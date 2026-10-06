#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
APP="$ROOT/assets/任务处理进度.app"
case "${1:-show}" in
  show|start)
    [[ -x "$APP/Contents/MacOS/CodexProgress" ]] || { print -u2 '未找到浮窗应用'; exit 1; }
    open "$APP"
    print '已打开任务处理进度'
    ;;
  status)
    if pgrep -x CodexProgress >/dev/null; then print '任务处理进度正在运行'; else print '任务处理进度未运行'; fi
    ;;
  stop)
    if pgrep -x CodexProgress >/dev/null; then pkill -x CodexProgress; fi
    print '已关闭任务处理进度'
    ;;
  diagnose)
    "$APP/Contents/MacOS/CodexProgress" --diagnose
    ;;
  *) print -u2 '用法：control.command show|status|stop|diagnose'; exit 2 ;;
esac

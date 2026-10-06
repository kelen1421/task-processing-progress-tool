#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
[[ "${1:-}" == --skip-build ]] || ./build.command
RELEASE_VERSION="$(<VERSION)"
APP="$PWD/dist/ai工作台.app"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$APP_VERSION" == "$RELEASE_VERSION" ]] || { print -u2 '应用版本与 VERSION 不一致'; exit 1; }
xcrun lipo "$APP/Contents/MacOS/CodexProgress" -verify_arch arm64 x86_64
codesign --verify --deep --strict "$APP"
RELEASE_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/task-progress-release.XXXXXX")"
trap 'rm -rf "$RELEASE_STAGE"' EXIT
APP_FOLDER="$RELEASE_STAGE/ai工作台-$RELEASE_VERSION"
mkdir -p "$APP_FOLDER" release
ditto --noextattr --norsrc "$APP" "$APP_FOLDER/ai工作台.app"
cp docs/安装与使用.txt "$APP_FOLDER/安装与使用.txt"
cp scripts/install-downloaded-app.command "$APP_FOLDER/安装或更新.command"
[[ ! -f LICENSE ]] || cp LICENSE "$APP_FOLDER/LICENSE"
python3 scripts/zip_release.py "$APP_FOLDER" "release/task-processing-progress-$RELEASE_VERSION-macos-universal.zip"
PLUGIN_FOLDER="$RELEASE_STAGE/ai工作台插件-$RELEASE_VERSION"
ditto --noextattr --norsrc plugin "$PLUGIN_FOLDER"
rm -rf "$PLUGIN_FOLDER/assets/任务处理进度.app"
ditto --noextattr --norsrc "$APP" "$PLUGIN_FOLDER/assets/ai工作台.app"
cp scripts/install-downloaded-plugin.command "$PLUGIN_FOLDER/安装个人插件.command"
cp docs/安装与使用.txt "$PLUGIN_FOLDER/安装与使用.txt"
[[ ! -f LICENSE ]] || cp LICENSE "$PLUGIN_FOLDER/LICENSE"
python3 scripts/zip_release.py "$PLUGIN_FOLDER" "release/task-processing-progress-$RELEASE_VERSION-codex-plugin.zip"
(cd release; shasum -a 256 "task-processing-progress-$RELEASE_VERSION-macos-universal.zip" "task-processing-progress-$RELEASE_VERSION-codex-plugin.zip" > SHA256SUMS.txt)
printf '发布文件已生成：%s/release\n' "$PWD"

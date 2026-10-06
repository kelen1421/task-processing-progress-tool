#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
APP="$PWD/dist/ai工作台.app"
mkdir -p "$APP/Contents/MacOS"
# Use the active developer SDK. This machine also has an older compatible SDK.
SDK_PATH="${TASK_PROGRESS_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
if [[ -z "${TASK_PROGRESS_SDK:-}" && "$SDK_PATH" == *MacOSX27.0.sdk && -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]]; then
  SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
fi
BUILD_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/task-progress-build.XXXXXX")"
trap 'rm -rf "$BUILD_TEMP"' EXIT
mkdir -p "$BUILD_TEMP/sources"
cp Sources/*.swift "$BUILD_TEMP/sources/"
for TARGET_ARCH in arm64 x86_64; do
  xcrun swiftc -sdk "$SDK_PATH" -target "$TARGET_ARCH-apple-macosx13.0" "$BUILD_TEMP/sources/"*.swift -o "$BUILD_TEMP/$TARGET_ARCH" -framework Cocoa -framework SwiftUI -framework ApplicationServices -lsqlite3 -module-cache-path "$BUILD_TEMP/modules-$TARGET_ARCH"
done
xcrun lipo -create "$BUILD_TEMP/arm64" "$BUILD_TEMP/x86_64" -output "$APP/Contents/MacOS/CodexProgress"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CodexProgress</string>
<key>CFBundleIdentifier</key><string>local.codex.progress</string>
<key>CFBundleName</key><string>ai工作台</string>
<key>CFBundleDisplayName</key><string>ai工作台</string>
<key>CFBundleVersion</key><string>12</string>
<key>CFBundleShortVersionString</key><string>1.8.1</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign "${TASK_PROGRESS_SIGNING_IDENTITY:--}" "$APP"
printf '已生成：%s\n' "$APP"

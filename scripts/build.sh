#!/bin/bash
# Build CodeUsage.app (release, ad-hoc signed).
#   scripts/build.sh            → build/CodeUsage.app
#   scripts/build.sh --install  → also copy to ~/Applications/CodeUsage.app (quits a running copy first)
#   scripts/build.sh --run      → open the app (the installed copy with --install, else build/CodeUsage.app)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="CodeUsage"
BUNDLE_ID="com.jhoh.CodeUsage"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"

INSTALL=0
RUN=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --run) RUN=1 ;;
        -h|--help)
            sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "알 수 없는 옵션: $arg (사용법: $0 [--install] [--run])" >&2
            exit 2 ;;
    esac
done

cd "$ROOT"

echo "==> swift build -c release"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
EXECUTABLE="$BIN_DIR/$APP_NAME"
if [[ ! -x "$EXECUTABLE" ]]; then
    echo "실행 파일을 찾을 수 없습니다: $EXECUTABLE" >&2
    exit 1
fi

echo "==> $APP 조립"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$EXECUTABLE" "$APP/Contents/MacOS/$APP_NAME"
ICON_SRC="$ROOT/Resources/AppIcon.icns"
if [[ ! -f "$ICON_SRC" ]]; then
    echo "==> 앱 아이콘 생성"
    (cd "$ROOT" && swift scripts/make-icon.swift)
fi
cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>ko</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>Code Usage</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> 서명 (ad-hoc)"
codesign --force --sign - "$APP"
codesign --verify "$APP"

TARGET_APP="$APP"

if [[ $INSTALL -eq 1 ]]; then
    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        echo "==> 실행 중인 $APP_NAME 종료"
        # Quit through Cocoa first so applicationWillTerminate flushes history; signals only as a fallback.
        osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
        for _ in $(seq 1 30); do
            pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
            sleep 0.1
        done
        if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
            pkill -x "$APP_NAME" || true
            for _ in $(seq 1 50); do
                pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
                sleep 0.1
            done
        fi
        if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
            pkill -9 -x "$APP_NAME" || true
        fi
    fi
    echo "==> $INSTALLED_APP 설치"
    mkdir -p "$INSTALL_DIR"
    rm -rf "$INSTALLED_APP"
    ditto "$APP" "$INSTALLED_APP"
    TARGET_APP="$INSTALLED_APP"
fi

if [[ $RUN -eq 1 ]]; then
    echo "==> $TARGET_APP 실행"
    open "$TARGET_APP"
fi

echo "완료: $APP"

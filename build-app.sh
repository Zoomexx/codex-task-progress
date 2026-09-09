#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
app_dir="${CODEX_TASK_PROGRESS_BUILD_APP_DIR:-$project_dir/CodexTaskProgress.app}"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
module_cache="$(mktemp -d /private/tmp/codex-usage-menu-module-cache.XXXXXX)"
trap 'rm -rf "$module_cache"' EXIT

mkdir -p "$macos_dir"
swiftc \
  "$project_dir/Sources/UsageSnapshot.swift" \
  "$project_dir/Sources/OfficialUsageClient.swift" \
  "$project_dir/Sources/UsageSyncService.swift" \
  "$project_dir/Sources/main.swift" \
  -module-cache-path "$module_cache" \
  -framework Cocoa \
  -o "$macos_dir/CodexTaskProgress"

cat > "$contents_dir/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>Codex 任务进度</string>
    <key>CFBundleExecutable</key>
    <string>CodexTaskProgress</string>
    <key>CFBundleIdentifier</key>
    <string>local.codex.task-progress</string>
    <key>CFBundleName</key>
    <string>Codex Task Progress</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.4.2</string>
    <key>CFBundleVersion</key>
    <string>6</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$app_dir" >/dev/null
fi

echo "Built: $app_dir"

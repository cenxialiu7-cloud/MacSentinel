#!/bin/bash
# MacSentinel — build & package as a drag-to-install DMG.
#
# What it does:
#   1. Builds the Release configuration of MacSentinel.app
#   2. Stages it in a temporary folder alongside a /Applications symlink
#   3. Wraps the folder into a compressed .dmg via hdiutil
#   4. Outputs to dist/MacSentinel-<version>.dmg
#
# Usage:  ./Scripts/build_dmg.sh
# Requires: Xcode 15+, hdiutil (built-in), xcodegen (only if project.yml changed)

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MacSentinel"
VERSION="1.1.1"
DIST_DIR="${PROJECT_ROOT}/dist"
SCHEME="${APP_NAME}"
BUILD_DIR="${PROJECT_ROOT}/build/dmg"
DMG_STAGING="${BUILD_DIR}/staging"
DMG_FINAL="${DIST_DIR}/${APP_NAME}-${VERSION}.dmg"

cd "${PROJECT_ROOT}"

echo "▸ Cleaning previous build artifacts…"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}" "${DIST_DIR}" "${DMG_STAGING}"

# ─── 1. Regenerate Xcode project (idempotent) ─────────────────────────────
if command -v xcodegen >/dev/null 2>&1; then
    echo "▸ Regenerating Xcode project via xcodegen…"
    xcodegen generate >/dev/null
fi

# ─── 2. Build Release ─────────────────────────────────────────────────────
echo "▸ Building ${SCHEME} (Release)…"
xcodebuild \
    -project "${APP_NAME}.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -derivedDataPath "${BUILD_DIR}/DerivedData" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    build 2>&1 | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED|Compiling|Linking" | tail -20 || true

BUILT_APP="${BUILD_DIR}/DerivedData/Build/Products/Release/${APP_NAME}.app"
if [[ ! -d "${BUILT_APP}" ]]; then
    echo "✗ Build failed — ${BUILT_APP} not found"
    exit 1
fi
echo "▸ Built: ${BUILT_APP}"

# ─── 3. Ad-hoc sign so the app can launch (otherwise Gatekeeper blocks) ──
# Note: for distribution outside your machine, replace "-" with your
# Developer ID Application identity.
echo "▸ Ad-hoc signing the bundle…"
codesign --force --deep --sign - \
    --options runtime \
    "${BUILT_APP}" 2>&1 | tail -3 || true

# Verify signature
codesign --verify --verbose "${BUILT_APP}" 2>&1 | head -3 || true

# ─── 4. Stage DMG contents ────────────────────────────────────────────────
echo "▸ Staging DMG contents…"
cp -R "${BUILT_APP}" "${DMG_STAGING}/"
ln -s /Applications "${DMG_STAGING}/Applications"

# Optional README inside the DMG
cat > "${DMG_STAGING}/README.txt" <<EOF
MacSentinel ${VERSION}
========================================

安裝方式：
  1. 把 MacSentinel.app 拖曳到 Applications 資料夾
  2. 在「啟動台」或「應用程式」資料夾中啟動

第一次啟動時，macOS Gatekeeper 可能會顯示警告（因為本版本以本機簽章發佈）：
  → 系統設定 → 隱私權與安全性 → 拉到底找到 MacSentinel → 點「強制打開」

本版本未公證（Notarized），僅供開發測試用。

MCP Server 設定：
  二進制位於 /Applications/MacSentinel.app/Contents/MacOS/macsentinel-mcp
  詳見 App 內「設定 → AI 助理整合 → 顯示連線設定指引」

────────────────────────────────────────
版本：${VERSION}
編譯日期：$(date "+%Y-%m-%d %H:%M:%S")
最低系統：macOS 14.0 Sonoma
EOF

# ─── 5. Build the compressed DMG ──────────────────────────────────────────
echo "▸ Creating compressed DMG…"
rm -f "${DMG_FINAL}"
hdiutil create \
    -volname "${APP_NAME} ${VERSION}" \
    -srcfolder "${DMG_STAGING}" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "${DMG_FINAL}" >/dev/null

# ─── 6. Summary ───────────────────────────────────────────────────────────
SIZE=$(du -h "${DMG_FINAL}" | cut -f1)
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✓ DMG ready"
echo ""
echo "    File:    ${DMG_FINAL}"
echo "    Size:    ${SIZE}"
echo ""
echo "  How to test:"
echo "    1. open '${DMG_FINAL}'"
echo "    2. Drag MacSentinel.app to the Applications shortcut"
echo "    3. Launch from /Applications/MacSentinel.app"
echo ""
echo "  First-run Gatekeeper bypass (if needed):"
echo "    xattr -dr com.apple.quarantine /Applications/MacSentinel.app"
echo "    # OR: System Settings → Privacy & Security → \"Open Anyway\""
echo "════════════════════════════════════════════════════════════════"

#!/bin/bash
# MacSentinel — full release pipeline: build → sign → notarize → DMG.
#
# Pre-requisites (one-time):
#   • Developer ID Application certificate in login keychain
#   • notarytool keychain profile "MacSentinel-Notary" (xcrun notarytool store-credentials)
#
# Usage:  ./Scripts/release.sh
# Output: dist/MacSentinel-<version>.dmg (signed, notarized, stapled)

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MacSentinel"
VERSION="1.1.1"
SCHEME="${APP_NAME}"

TEAM_ID="U58M43YXTJ"
SIGN_IDENTITY="Developer ID Application: Shun Ching YU (${TEAM_ID})"
NOTARY_PROFILE="MacSentinel-Notary"

DIST_DIR="${PROJECT_ROOT}/dist"
BUILD_DIR="${PROJECT_ROOT}/build/release"
DERIVED="${BUILD_DIR}/DerivedData"
DMG_STAGING="${BUILD_DIR}/staging"
DMG_FINAL="${DIST_DIR}/${APP_NAME}-${VERSION}.dmg"

cd "${PROJECT_ROOT}"

step() { printf "\n\033[1;34m▸ %s\033[0m\n" "$*"; }
ok()   { printf "\033[1;32m✓ %s\033[0m\n" "$*"; }
die()  { printf "\033[1;31m✗ %s\033[0m\n" "$*" >&2; exit 1; }

# ─── 0. Pre-flight checks ─────────────────────────────────────────────────
step "Pre-flight checks"
security find-identity -v -p codesigning | grep -q "${SIGN_IDENTITY}" \
  || die "Developer ID Application identity not found in keychain"
xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1 \
  || die "Notary profile '${NOTARY_PROFILE}' not set up. Run: xcrun notarytool store-credentials ${NOTARY_PROFILE} ..."
command -v xcodegen >/dev/null || die "xcodegen not installed (brew install xcodegen)"
ok "Signing identity & notary profile present"

# ─── 1. Regenerate Xcode project ──────────────────────────────────────────
step "Regenerating Xcode project (xcodegen)"
xcodegen generate >/dev/null
ok "project regenerated"

# ─── 2. Clean previous output ─────────────────────────────────────────────
step "Cleaning previous release output"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}" "${DIST_DIR}" "${DMG_STAGING}"

# ─── 3. Build Release with Developer ID signing ───────────────────────────
step "Building ${SCHEME} (Release, signed with Developer ID)"
xcodebuild \
    -project "${APP_NAME}.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -derivedDataPath "${DERIVED}" \
    -destination "generic/platform=macOS" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="${TEAM_ID}" \
    CODE_SIGN_IDENTITY="${SIGN_IDENTITY}" \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
    build 2>&1 | tail -80

BUILT_APP="${DERIVED}/Build/Products/Release/${APP_NAME}.app"
[[ -d "${BUILT_APP}" ]] || die "Build failed — ${BUILT_APP} not found"
ok "Built: ${BUILT_APP}"

# ─── 4. Re-sign nested binaries (defence-in-depth) ────────────────────────
# Sign inner→outer to satisfy hardened-runtime nested-code rules. xcodebuild
# already signs, but a clean codesign --deep ensures everything is consistent.
step "Deep-signing app bundle"

# Sign embedded MCP CLI (no entitlements file — inherits hardened runtime)
MCP_BIN="${BUILT_APP}/Contents/MacOS/macsentinel-mcp"
if [[ -f "${MCP_BIN}" ]]; then
    codesign --force --timestamp --options runtime \
        --sign "${SIGN_IDENTITY}" "${MCP_BIN}"
    ok "signed: macsentinel-mcp"
fi

# Sign main app with its entitlements
codesign --force --timestamp --options runtime \
    --entitlements "${PROJECT_ROOT}/MacSentinel/App/MacSentinel.entitlements" \
    --sign "${SIGN_IDENTITY}" "${BUILT_APP}"

# Verify
codesign --verify --strict --verbose=2 "${BUILT_APP}" 2>&1 | tail -5
ok "Signature verified"

# ─── 5. Notarize the .app ─────────────────────────────────────────────────
step "Submitting .app to Apple notary service"
APP_ZIP="${BUILD_DIR}/${APP_NAME}.zip"
/usr/bin/ditto -c -k --keepParent "${BUILT_APP}" "${APP_ZIP}"

xcrun notarytool submit "${APP_ZIP}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait 2>&1 | tee "${BUILD_DIR}/notary-app.log"

grep -q "status: Accepted" "${BUILD_DIR}/notary-app.log" \
    || die "App notarization failed — check ${BUILD_DIR}/notary-app.log; retrieve detail with: xcrun notarytool log <submission-id> --keychain-profile ${NOTARY_PROFILE}"
ok "App notarized"

# ─── 6. Staple the ticket onto the .app ───────────────────────────────────
step "Stapling notarization ticket to .app"
xcrun stapler staple "${BUILT_APP}"
xcrun stapler validate "${BUILT_APP}"
ok "App stapled"

# ─── 7. Stage and build the DMG ───────────────────────────────────────────
step "Staging DMG contents"
cp -R "${BUILT_APP}" "${DMG_STAGING}/"
ln -s /Applications "${DMG_STAGING}/Applications"
cat > "${DMG_STAGING}/README.txt" <<EOF
MacSentinel ${VERSION}
========================================

安裝方式：
  1. 把 MacSentinel.app 拖曳到 Applications 資料夾
  2. 在「啟動台」或「應用程式」資料夾中啟動

本版本已經 Apple 公證（Notarized），首次啟動不會被 Gatekeeper 阻擋。

────────────────────────────────────────
版本：${VERSION}
編譯日期：$(date "+%Y-%m-%d %H:%M:%S")
最低系統：macOS 14.0 Sonoma
EOF

step "Creating compressed DMG"
rm -f "${DMG_FINAL}"
hdiutil create \
    -volname "${APP_NAME} ${VERSION}" \
    -srcfolder "${DMG_STAGING}" \
    -ov -format UDZO -fs HFS+ \
    "${DMG_FINAL}" >/dev/null
ok "DMG created: ${DMG_FINAL}"

# ─── 8. Sign + notarize + staple the DMG ──────────────────────────────────
step "Signing DMG"
codesign --force --timestamp --sign "${SIGN_IDENTITY}" "${DMG_FINAL}"

step "Submitting DMG to Apple notary service"
xcrun notarytool submit "${DMG_FINAL}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait 2>&1 | tee "${BUILD_DIR}/notary-dmg.log"

grep -q "status: Accepted" "${BUILD_DIR}/notary-dmg.log" \
    || die "DMG notarization failed — check ${BUILD_DIR}/notary-dmg.log"
ok "DMG notarized"

step "Stapling DMG"
xcrun stapler staple "${DMG_FINAL}"
xcrun stapler validate "${DMG_FINAL}"

# ─── 9. Final verification ────────────────────────────────────────────────
step "Final Gatekeeper verification"
spctl --assess --type open --context context:primary-signature -vv "${DMG_FINAL}" 2>&1 | tail -3 || true
spctl --assess --type execute -vv "${BUILT_APP}" 2>&1 | tail -3 || true

SIZE=$(du -h "${DMG_FINAL}" | cut -f1)

# ─── 10. Publish to GitHub Releases ───────────────────────────────────────
# Skips silently if not in a git repo, no `gh` CLI, or no `origin` remote.
GH_RELEASE_URL=""
if command -v gh >/dev/null && git -C "${PROJECT_ROOT}" rev-parse --git-dir >/dev/null 2>&1 \
   && git -C "${PROJECT_ROOT}" remote get-url origin >/dev/null 2>&1; then
    step "Publishing v${VERSION} to GitHub Releases"

    TAG="v${VERSION}"
    cd "${PROJECT_ROOT}"

    # Warn (don't block) on uncommitted changes
    if ! git diff-index --quiet HEAD -- 2>/dev/null; then
        echo "  ⚠ uncommitted changes in working tree — tag will point at last commit"
    fi

    # Create tag if missing
    if git rev-parse "${TAG}" >/dev/null 2>&1; then
        echo "  • tag ${TAG} already exists, reusing"
    else
        git tag "${TAG}"
        git push origin "${TAG}"
        echo "  • tag ${TAG} pushed"
    fi

    # Skip if a release with this tag already exists
    if gh release view "${TAG}" >/dev/null 2>&1; then
        echo "  • release ${TAG} already exists — uploading DMG as additional asset"
        gh release upload "${TAG}" "${DMG_FINAL}" --clobber
    else
        gh release create "${TAG}" "${DMG_FINAL}" \
            --title "MacSentinel ${VERSION}" \
            --notes "Apple notarized release.

## Install
Download \`$(basename "${DMG_FINAL}")\`, open it, drag MacSentinel.app to Applications.

## Signature
- Developer ID Application: Shun Ching YU (${TEAM_ID})
- Notarized & stapled by Apple
- Gatekeeper: \`source=Notarized Developer ID\`

## Requirements
- macOS 14.0 (Sonoma) or later
- Universal Binary (Apple Silicon + Intel)"
    fi
    GH_RELEASE_URL=$(gh release view "${TAG}" --json url --jq .url 2>/dev/null || true)
    ok "GitHub release: ${GH_RELEASE_URL}"
else
    echo "  • Skip GitHub publish (gh CLI / git remote not configured)"
fi

cat <<EOF

════════════════════════════════════════════════════════════════
✓ Release ready

    File:    ${DMG_FINAL}
    Size:    ${SIZE}
    Version: ${VERSION}
    Signed:  ${SIGN_IDENTITY}
    Status:  Notarized & Stapled (Gatekeeper-clean)
    GitHub:  ${GH_RELEASE_URL:-(not published)}

════════════════════════════════════════════════════════════════
EOF

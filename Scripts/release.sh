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
VERSION="1.1.6"
SCHEME="${APP_NAME}"

NOTARY_PROFILE="MacSentinel-Notary"
# Signing identity & Team ID are auto-detected from the login keychain at
# pre-flight time (see step 0) so this script can be committed publicly
# without leaking the developer's real name or Team ID.
SIGN_IDENTITY=""   # populated below: SHA-1 fingerprint of Developer ID Application cert
TEAM_ID=""         # populated below: extracted from the cert's OU

DIST_DIR="${PROJECT_ROOT}/dist"
BUILD_DIR="${PROJECT_ROOT}/build/release"
DERIVED="${BUILD_DIR}/DerivedData"
DMG_STAGING="${BUILD_DIR}/staging"
DMG_FINAL="${DIST_DIR}/${APP_NAME}-${VERSION}.dmg"

cd "${PROJECT_ROOT}"

step() { printf "\n\033[1;34m▸ %s\033[0m\n" "$*"; }
ok()   { printf "\033[1;32m✓ %s\033[0m\n" "$*"; }
die()  { printf "\033[1;31m✗ %s\033[0m\n" "$*" >&2; exit 1; }

SPARKLE_BIN="${PROJECT_ROOT}/Scripts/sparkle-bin"
SPARKLE_VERSION="2.7.2"
APPCAST="${PROJECT_ROOT}/appcast.xml"
DMG_DOWNLOAD_URL="https://github.com/cenxialiu7-cloud/MacSentinel/releases/download/v${VERSION}/${APP_NAME}-${VERSION}.dmg"

# ─── 0. Pre-flight checks ─────────────────────────────────────────────────
step "Pre-flight checks"

# Auto-detect first Developer ID Application identity from login keychain.
# codesign accepts a SHA-1 fingerprint directly, so we never need to hard-code
# the developer's name / Team ID into a publicly-committed script.
IDENTITY_LINE=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1)
[[ -n "${IDENTITY_LINE}" ]] || die "No 'Developer ID Application' identity found in login keychain"
SIGN_IDENTITY=$(echo "${IDENTITY_LINE}" | awk '{print $2}')   # SHA-1 hash, e.g. 88D1...
# Extract 10-char Team ID from the certificate's Subject OU
TEAM_ID=$(security find-certificate -c "Developer ID Application" -p 2>/dev/null \
  | openssl x509 -noout -subject 2>/dev/null \
  | grep -oE "OU *= *[A-Z0-9]{10}" | head -1 | awk -F= '{gsub(/ /,"",$2); print $2}')
[[ -n "${TEAM_ID}" ]] || die "Could not extract Team ID from Developer ID Application certificate"

xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1 \
  || die "Notary profile '${NOTARY_PROFILE}' not set up. Run: xcrun notarytool store-credentials ${NOTARY_PROFILE} ..."
command -v xcodegen >/dev/null || die "xcodegen not installed (brew install xcodegen)"
ok "Signing identity ${SIGN_IDENTITY:0:8}… (Team ${TEAM_ID}) & notary profile present"

# Bootstrap Sparkle CLI tools (sign_update, generate_keys, generate_appcast)
if [[ ! -x "${SPARKLE_BIN}/sign_update" ]]; then
    step "Downloading Sparkle ${SPARKLE_VERSION} CLI tools"
    mkdir -p "${SPARKLE_BIN}"
    TMP_TAR=$(mktemp -t sparkle).tar.xz
    curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz" -o "${TMP_TAR}"
    tar -xJf "${TMP_TAR}" -C "$(dirname "${TMP_TAR}")"
    cp "$(dirname "${TMP_TAR}")/bin/sign_update" \
       "$(dirname "${TMP_TAR}")/bin/generate_keys" \
       "$(dirname "${TMP_TAR}")/bin/generate_appcast" \
       "${SPARKLE_BIN}/"
    rm -f "${TMP_TAR}"
    ok "Sparkle CLI tools ready"
fi
"${SPARKLE_BIN}/generate_keys" -p >/dev/null 2>&1 \
  || die "Sparkle Ed25519 private key not found in keychain. Run: ${SPARKLE_BIN}/generate_keys"

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
# Sign inner→outer to satisfy hardened-runtime + notarization rules.
# Sparkle's nested executables (Updater.app, XPCServices, Autoupdate) ship
# signed by the Sparkle project — Apple notary rejects unless we re-sign with
# our own Developer ID while preserving their entitlements.
step "Deep-signing app bundle"

SPARKLE_FW="${BUILT_APP}/Contents/Frameworks/Sparkle.framework"
SPARKLE_VERS="${SPARKLE_FW}/Versions/B"

sign_with_preserved_entitlements() {
    local target="$1"
    codesign --force --timestamp --options runtime \
        --preserve-metadata=entitlements,identifier,flags \
        --sign "${SIGN_IDENTITY}" "${target}"
}

if [[ -d "${SPARKLE_FW}" ]]; then
    # 1. XPC services (deepest)
    for xpc in "${SPARKLE_VERS}/XPCServices"/*.xpc; do
        [[ -d "${xpc}" ]] || continue
        sign_with_preserved_entitlements "${xpc}"
        echo "  signed: $(basename "${xpc}")"
    done

    # 2. Updater.app (must sign the inner binary first, then the bundle)
    if [[ -d "${SPARKLE_VERS}/Updater.app" ]]; then
        sign_with_preserved_entitlements "${SPARKLE_VERS}/Updater.app/Contents/MacOS/Updater"
        sign_with_preserved_entitlements "${SPARKLE_VERS}/Updater.app"
        echo "  signed: Updater.app"
    fi

    # 3. Autoupdate helper binary
    if [[ -f "${SPARKLE_VERS}/Autoupdate" ]]; then
        sign_with_preserved_entitlements "${SPARKLE_VERS}/Autoupdate"
        echo "  signed: Autoupdate"
    fi

    # 4. Sparkle framework itself (must come after inner items)
    codesign --force --timestamp --options runtime \
        --sign "${SIGN_IDENTITY}" "${SPARKLE_FW}"
    echo "  signed: Sparkle.framework"
fi

# Sign embedded MCP CLI (no entitlements file — inherits hardened runtime)
MCP_BIN="${BUILT_APP}/Contents/MacOS/macsentinel-mcp"
if [[ -f "${MCP_BIN}" ]]; then
    codesign --force --timestamp --options runtime \
        --sign "${SIGN_IDENTITY}" "${MCP_BIN}"
    echo "  signed: macsentinel-mcp"
fi

# Sign main app with its entitlements (outermost)
codesign --force --timestamp --options runtime \
    --entitlements "${PROJECT_ROOT}/MacSentinel/App/MacSentinel.entitlements" \
    --sign "${SIGN_IDENTITY}" "${BUILT_APP}"

# Verify (strict deep check)
codesign --verify --strict --deep --verbose=2 "${BUILT_APP}" 2>&1 | tail -8
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
- Signed with Apple Developer ID
- Notarized & stapled by Apple
- Gatekeeper: \`source=Notarized Developer ID\`
- Verify locally: \`codesign -dvv /Applications/MacSentinel.app\`

## Requirements
- macOS 14.0 (Sonoma) or later
- Universal Binary (Apple Silicon + Intel)"
    fi
    GH_RELEASE_URL=$(gh release view "${TAG}" --json url --jq .url 2>/dev/null || true)
    ok "GitHub release: ${GH_RELEASE_URL}"
else
    echo "  • Skip GitHub publish (gh CLI / git remote not configured)"
fi

# ─── 11. Update appcast.xml (Sparkle in-app updates) ──────────────────────
if [[ -f "${APPCAST}" ]] && git -C "${PROJECT_ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
    step "Updating Sparkle appcast.xml"

    # Sign the DMG with Ed25519 (private key in keychain). Outputs e.g.:
    #   sparkle:edSignature="abc..." length="4548969"
    SIG_LINE=$("${SPARKLE_BIN}/sign_update" "${DMG_FINAL}")
    DMG_LENGTH=$(stat -f%z "${DMG_FINAL}")
    PUB_DATE=$(LC_TIME=C TZ=GMT date "+%a, %d %b %Y %H:%M:%S +0000")

    # Write the new <item> to a file first — passing multi-line content via
    # `awk -v` is not portable on macOS (parse-error on embedded newlines).
    NEW_ITEM_FILE=$(mktemp -t macsentinel-appcast-item).xml

    # Sparkle compares <sparkle:version> against the installed app's
    # CFBundleVersion (build number) — NOT CFBundleShortVersionString.
    # Extract the build number from Info.plist so Sparkle sees a monotonic
    # integer and can decide "update available" correctly.
    BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" \
        "${BUILT_APP}/Contents/Info.plist" 2>/dev/null || echo "1")

    cat > "${NEW_ITEM_FILE}" <<EOF
        <item>
            <title>Version ${VERSION}</title>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:version>${BUILD_NUMBER}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <description><![CDATA[
                <p>See the full changelog on <a href="https://github.com/cenxialiu7-cloud/MacSentinel/releases/tag/${TAG}">GitHub</a>.</p>
            ]]></description>
            <enclosure
                url="${DMG_DOWNLOAD_URL}"
                ${SIG_LINE}
                type="application/octet-stream"/>
        </item>
EOF

    # Insert the item file right after </language> using awk's getline-from-file.
    TMP_CAST=$(mktemp)
    awk -v itemfile="${NEW_ITEM_FILE}" '
        /<\/language>/ && !done {
            print
            while ((getline line < itemfile) > 0) print line
            close(itemfile)
            done=1
            next
        }
        { print }
    ' "${APPCAST}" > "${TMP_CAST}"
    mv "${TMP_CAST}" "${APPCAST}"
    rm -f "${NEW_ITEM_FILE}"

    # Commit & push
    cd "${PROJECT_ROOT}"
    if ! git diff --quiet appcast.xml; then
        git add appcast.xml
        git commit -m "appcast: publish v${VERSION}" >/dev/null
        git push origin HEAD:main >/dev/null 2>&1 || echo "  ⚠ git push failed — appcast committed locally"
        ok "appcast.xml updated and pushed"
    else
        echo "  • appcast already up-to-date"
    fi
else
    echo "  • Skip appcast update (appcast.xml or git repo missing)"
fi

cat <<EOF

════════════════════════════════════════════════════════════════
✓ Release ready

    File:    ${DMG_FINAL}
    Size:    ${SIZE}
    Version: ${VERSION}
    Signed:  Developer ID (Team ${TEAM_ID}, cert ${SIGN_IDENTITY:0:8}…)
    Status:  Notarized & Stapled (Gatekeeper-clean)
    GitHub:  ${GH_RELEASE_URL:-(not published)}

════════════════════════════════════════════════════════════════
EOF

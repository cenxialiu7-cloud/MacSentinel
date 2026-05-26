#!/bin/bash
# MacSentinel — 完整清理腳本（合併 Containers + 系統 LaunchAgents + kexts + Intel App 殘留）
#
# 4 種清理機制：
#   1. osascript Finder       — 處理有 com.apple.macl ACL 的 App / Container
#   2. sudo + chflags + mv    — 處理 /Library/LaunchAgents、/Library/LaunchDaemons
#   3. sudo rm -rf            — 處理 /Library/Extensions/*.kext（需重開機才會卸載）
#   4. 一般 mv                 — 處理普通使用者目錄
#
# 為何 sudo 對 ~/Library/Containers/ 不夠？
#   macOS 11+ 把 ~/Library/Containers/ 列為 TCC 保護路徑。TCC 在 kernel 層攔截，
#   不認 sudo 的 root 權限 — 必須是被使用者明確授權 Full Disk Access 的進程。
#   而 Finder 自帶 TCC 例外，所以走 osascript 是最簡潔的繞道。

set -uo pipefail

# ─── 0. FDA 檢測 ────────────────────────────────────────────────────────
echo "▸ 檢測目前 Terminal 是否擁有 Full Disk Access…"
TEST_FILE="$HOME/Library/Containers/.macsentinel_fda_test"
if touch "$TEST_FILE" 2>/dev/null; then
    rm -f "$TEST_FILE"
    FDA_AVAILABLE=true
    echo "  ✓ Terminal 有 FDA — 可用 sudo 路徑處理 Containers"
else
    FDA_AVAILABLE=false
    echo "  ⚠ Terminal 沒有 FDA — 將改用 osascript Finder 走 ACL 例外"
    echo "    （若 Finder 也失敗，請依結尾說明授予 Terminal FDA）"
fi
echo ""

# ─── 1. 要清的 37 個孤兒 Containers（透過 osascript Finder）─────────────
CONTAINERS=(
    # WeChat
    "com.tencent.xinWeChat"
    "com.tencent.xinWeChat.MiniProgram"
    "5A4RE8SF68.com.tencent.xinWeChat.IPCHelper"

    # Microsoft Office
    "com.microsoft.Powerpoint"
    "com.microsoft.openxml.excel.app"
    "com.microsoft.Outlook"
    "com.microsoft.outlook.profilemanager"
    "com.Microsoft.OsfWebHost"
    "com.microsoft.Microsoft-Mashup-Container"
    "com.microsoft.Office365ServiceV2"
    "com.microsoft.SkyDriveLauncher"
    "com.microsoft.OneDriveLauncher"
    "com.microsoft.errorreporting"
    "com.microsoft.OneDrive.FinderSync"
    "com.microsoft.onenote.mac"
    "com.microsoft.onenote.mac.shareextension"
    "com.microsoft.Outlook.CalendarWidget"
    "com.microsoft.Excel.widgetextension"
    "com.microsoft.Word.widgetextension"
    "com.microsoft.OneDrive.FileProvider"
    "com.microsoft.SharePointLauncher"

    # LINE
    "jp.naver.line.mac.TimelinePreviewService"
    "jp.naver.line.mac.SeekPreviewService"
    "jp.naver.line.mac.FFmpegService"
    "jp.naver.line.mac.MediaService"
    "jp.naver.line.mac.ShareExt"
    "jp.naver.line.mac.YukiService"
    "LINE.TimelinePreviewService"
    "LINE.TimelinePreviewService.0"
    "LINE.TimelinePreviewService.1"
    "LINE.SeekPreviewService"
    "LINE.MediaService"
    "LINE.AudioService"
    "LINE.VideoPreviewService.0"
    "LINE.VideoPreviewService.1"
    "LINE.FFmpegService"
    "LINE.YukiService"
)

echo "▸ 第 1 部分：透過 Finder ACL 例外，清 37 個孤兒 Containers"
# 把存在的路徑組成 AppleScript 陣列
POSIX_LIST=""
for c in "${CONTAINERS[@]}"; do
    if [ -e "$HOME/Library/Containers/$c" ]; then
        if [ -n "$POSIX_LIST" ]; then POSIX_LIST+=", "; fi
        POSIX_LIST+="POSIX file \"$HOME/Library/Containers/$c\""
    fi
done

if [ -n "$POSIX_LIST" ]; then
    # 一次性提交給 Finder（會跳一個 macOS 確認對話框「Finder 想要存取受保護的位置」— 點允許）
    osascript -e "tell application \"Finder\" to delete {$POSIX_LIST}" >/tmp/finder_del.log 2>&1
    EXIT=$?
    if [ $EXIT -eq 0 ]; then
        echo "  ✓ Finder 成功處理批次刪除"
    else
        echo "  ⚠ Finder 拒絕：$(head -1 /tmp/finder_del.log)"
        echo "    → 將嘗試備援路徑（需要 FDA）"
    fi
fi

# 驗證
CONT_OK=0; CONT_FAIL=0
for c in "${CONTAINERS[@]}"; do
    if [ -e "$HOME/Library/Containers/$c" ]; then
        CONT_FAIL=$((CONT_FAIL+1))
    else
        CONT_OK=$((CONT_OK+1))
    fi
done
echo "  → Containers 結果：${CONT_OK} 已清 / ${CONT_FAIL} 仍在"
echo ""

# 如果 Finder 也失敗，嘗試 FDA + sudo + chflags 路徑
if [ "$CONT_FAIL" -gt 0 ] && [ "$FDA_AVAILABLE" = "true" ]; then
    echo "▸ 第 1B 部分：FDA 已授權，用 sudo + chflags 清剩餘 ${CONT_FAIL} 個"
    sudo -v || { echo "✗ sudo 失敗"; exit 1; }
    for c in "${CONTAINERS[@]}"; do
        src="$HOME/Library/Containers/$c"
        [ ! -e "$src" ] && continue
        sudo chflags -R nouchg,noschg "$src" 2>/dev/null
        if sudo rm -rf "$src" 2>/dev/null; then
            echo "  ✓ 已清: $c"
        else
            echo "  ✗ 仍失敗: $c"
        fi
    done
    echo ""
fi

# ─── 2. /Library/ 系統級啟動項（需 sudo，不需 FDA）──────────────────────
SYSTEM_AGENTS=(
    "/Library/LaunchAgents/com.microsoft.SyncReporter.plist"
    "/Library/LaunchAgents/com.microsoft.OneDriveStandaloneUpdater.plist"
    "/Library/LaunchDaemons/com.microsoft.OneDriveStandaloneUpdaterDaemon.plist"
    "/Library/LaunchDaemons/com.microsoft.OneDriveUpdaterDaemon.plist"
)

echo "▸ 第 2 部分：清 4 個 OneDrive 系統啟動項（sudo）"
sudo -v
for plist in "${SYSTEM_AGENTS[@]}"; do
    [ ! -e "$plist" ] && { echo "  ⊘ 已不存在: $(basename $plist)"; continue; }
    # 先 unload 再刪
    sudo launchctl unload "$plist" 2>/dev/null || true
    if sudo rm -f "$plist"; then
        echo "  ✓ 已清: $(basename $plist)"
    else
        echo "  ✗ 失敗: $(basename $plist)"
    fi
done
echo ""

# ─── 3. /Library/Extensions/*.kext（sudo）─────────────────────────────────
KEXTS=(
    "/Library/Extensions/SoftRAID.kext"
    "/Library/Extensions/HighPointIOP.kext"
    "/Library/Extensions/HighPointRR.kext"
    "/Library/Extensions/hp_io_enabler_compound.kext"
)

echo "▸ 第 3 部分：清 4 個 legacy kexts（重開機後才會真的卸載）"
for kext in "${KEXTS[@]}"; do
    [ ! -e "$kext" ] && { echo "  ⊘ 已不存在: $(basename $kext)"; continue; }
    if sudo rm -rf "$kext"; then
        echo "  ✓ 已清: $(basename $kext)"
    else
        echo "  ✗ 失敗: $(basename $kext)"
    fi
done

# 重整 kext cache 讓系統下次開機不再嘗試載入
sudo kextcache -i / 2>/dev/null && echo "  ✓ kext cache 已重整" || echo "  ⚠ kextcache 重整跳過（不影響）"
echo ""

# ─── 4. LadioCast 的 Container 殘留（osascript Finder）─────────────────
echo "▸ 第 4 部分：清 LadioCast 殘留"
LADIO_CONTAINER="$HOME/Library/Containers/com.kawauso.LadioCast"
LADIO_SCRIPTS="$HOME/Library/Application Scripts/com.kawauso.LadioCast"
osascript -e "tell application \"Finder\" to delete {POSIX file \"$LADIO_CONTAINER\", POSIX file \"$LADIO_SCRIPTS\"}" >/dev/null 2>&1
[ ! -e "$LADIO_CONTAINER" ] && echo "  ✓ LadioCast Container 已清" || echo "  ⚠ LadioCast Container 仍在（需 FDA）"
echo ""

# ─── 收尾 ─────────────────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════════════"
echo "清理完成。請開 Finder 看垃圾桶，確認沒有要留的東西後清空。"
echo ""
if [ "$FDA_AVAILABLE" = "false" ] && [ "$CONT_FAIL" -gt 0 ]; then
    echo "⚠  若仍有 Containers 沒清掉，請授予 Terminal Full Disk Access："
    echo "   1. 開啟「系統設定」→「隱私權與安全性」→「完整磁碟取用權」"
    echo "   2. 點 + 加入 Terminal.app（路徑：/System/Applications/Utilities/Terminal.app）"
    echo "   3. 打開右側 toggle"
    echo "   4. 完全結束 Terminal（Cmd+Q）"
    echo "   5. 重開 Terminal 後再跑一次此腳本"
fi
echo "════════════════════════════════════════════════════════════════"

#!/bin/bash
# Cleanup 37 orphaned ~/Library/Containers/ items that macOS TCC blocks
# from regular user deletion.
#
# Usage: ./cleanup_orphan_containers.sh
# Will prompt for sudo password ONCE, then move each item to Trash.
#
# Safety: uses macOS `trash` semantics (via mv to .Trash) so all deletes
# are recoverable. Targets ONLY the 37 paths identified by MacSentinel's
# scan_migration as having no owning application installed.

set -uo pipefail

CONTAINERS=(
    # WeChat residuals
    "com.tencent.xinWeChat"
    "com.tencent.xinWeChat.MiniProgram"
    "5A4RE8SF68.com.tencent.xinWeChat.IPCHelper"

    # Microsoft Office residuals
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

    # LINE residuals (Japanese chat app)
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

TRASH="$HOME/.Trash"
CONTAINER_DIR="$HOME/Library/Containers"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

echo "▸ 共 ${#CONTAINERS[@]} 個 Container 待移到垃圾桶"
echo "▸ 需要 sudo 密碼來繞過 macOS containermanagerd 保護"
echo ""

# Prime sudo once so the loop runs without re-prompting
sudo -v
if [ $? -ne 0 ]; then
    echo "✗ sudo 取得失敗，中止"
    exit 1
fi

DELETED=0
SKIPPED=0
FAILED=0

for name in "${CONTAINERS[@]}"; do
    src="$CONTAINER_DIR/$name"
    if [ ! -e "$src" ]; then
        echo "  ⊘ 已不存在: $name"
        SKIPPED=$((SKIPPED+1))
        continue
    fi
    # Rename within Trash to avoid collisions with same-named items
    dst="$TRASH/${name}.macsentinel-${TIMESTAMP}"
    # chflags removes any user-immutable / system flags that block move
    sudo chflags -R nouchg,noschg "$src" 2>/dev/null
    sudo mv "$src" "$dst" 2>&1 | head -1
    if [ $? -eq 0 ] && [ -e "$dst" ]; then
        # Hand ownership back to the user so they can manage the Trash entry
        sudo chown -R "$USER:staff" "$dst" 2>/dev/null
        echo "  ✓ 已搬: $name  →  ~/.Trash/${name}.macsentinel-${TIMESTAMP}"
        DELETED=$((DELETED+1))
    else
        echo "  ✗ 失敗: $name"
        FAILED=$((FAILED+1))
    fi
done

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  ✓ 已移除:  $DELETED"
echo "  ⊘ 已不存在: $SKIPPED"
echo "  ✗ 失敗:    $FAILED"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "  下一步：清空垃圾桶才會真正釋放磁碟空間"
echo "    open ~/.Trash    # 檢視"
echo "    osascript -e 'tell app \"Finder\" to empty trash'    # 清空"

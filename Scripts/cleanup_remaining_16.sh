#!/bin/bash
# 清除剩 16 個 TCC 卡關的 Containers
# 必須從擁有 Full Disk Access 的 Terminal 執行（你的 Terminal 已經有了）

set -uo pipefail

# 真孤兒 16 個（已排除：Apple 系統 / Google Drive / Oka Unarchiver 子擴充 / VideoFusion / MKPlayer 等仍在使用中的 App）
ORPHANS=(
    "$HOME/Library/Containers/com.hp.SmartMac"
    "$HOME/Library/Containers/com.hp.PSDrMonitor"
    "$HOME/Library/Containers/com.hp.PSDrMonitorHelper"
    "$HOME/Library/Containers/com.etinysoft.Total-Video-Converter"
    "$HOME/Library/Containers/net.xmind.vana.app"
    "$HOME/Library/Containers/com.nordvpn.NordVPN"
    "$HOME/Library/Containers/ru.keepcoder.Telegram"
    "$HOME/Library/Containers/ru.keepcoder.Telegram.TelegramShare"
    "$HOME/Library/Containers/com.adobe.accmac.ACCFinderSync"
    "$HOME/Library/Containers/com.trendmicro.DrUnzip"
    "$HOME/Library/Containers/com.trendmicro.DULoginItemHelper"
    "$HOME/Library/Containers/com.kawauso.LadioCast"
    "$HOME/Library/Containers/com.cisco.webex.Cisco-WebEx-Start.CWSSafariExtension"
    "$HOME/Library/Containers/com.nimbleai.screenDl"
    "$HOME/Library/Containers/com.gwinno.DPF"
    "$HOME/Library/Containers/com.gwinno.DPF-Helper"
)

echo "▸ 準備清除 ${#ORPHANS[@]} 個孤兒 Container"
echo "▸ 透過 Finder ACL 例外執行（你的 Terminal 已具備 FDA）"
echo ""

# 列出存在的目標
POSIX_LIST=""
EXIST=0
for p in "${ORPHANS[@]}"; do
    if [ -e "$p" ]; then
        [ -n "$POSIX_LIST" ] && POSIX_LIST+=", "
        POSIX_LIST+="POSIX file \"$p\""
        EXIST=$((EXIST+1))
    fi
done
echo "  發現 $EXIST 個目標存在"
echo ""

if [ "$EXIST" -gt 0 ]; then
    osascript -e "tell application \"Finder\" to delete {$POSIX_LIST}" >/tmp/cleanup16.log 2>&1
    if [ $? -eq 0 ]; then
        echo "  ✓ Finder 完成"
    else
        echo "  ⚠ Finder 失敗：$(head -1 /tmp/cleanup16.log)"
        echo ""
        echo "  → 如果是 -5000 錯誤，請授予 Terminal FDA："
        echo "     系統設定 → 隱私權與安全性 → 完整磁碟取用權 → + → /System/Applications/Utilities/Terminal.app"
        echo "     開啟 toggle 後完全結束 Terminal (Cmd+Q) 再開重新跑此腳本"
        exit 1
    fi
fi

echo ""
echo "═══ 驗證結果 ═══"
OK=0; FAIL=0
for p in "${ORPHANS[@]}"; do
    if [ -e "$p" ]; then
        FAIL=$((FAIL+1))
        echo "  ✗ 仍在: $(basename "$p")"
    else
        OK=$((OK+1))
    fi
done
echo ""
echo "  ✓ 已清: $OK"
[ "$FAIL" -gt 0 ] && echo "  ✗ 失敗: $FAIL"
echo ""
echo "═══ 完成 ═══"
echo "請開啟「垃圾桶」確認沒有需要保留的，然後清空即可釋放磁碟空間。"

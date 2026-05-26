# 背景任務 SOP（給 Claude / 自動化執行者）

> 寫於 2026-05-27。起因：v1.1.2 release 流程跑完後，Claude Code UI 的 "Background tasks" 面板殘留三個顯示為 Running 但實際 OS process 早已退出的任務，使用者誤以為 pipeline 卡住。

## 失聯三大模式（不要再犯）

| 模式 | 為什麼會失聯 | 替代做法 |
|---|---|---|
| **A. `nohup ./script > log 2>&1 &`** | nohup 把子 process detach 成 daemon，包住它的 Bash 工具呼叫立刻 exit 0；harness 失去 fd 後無法偵測子 process 何時死。 | 改用 `Bash(run_in_background=true)` 直接跑 `./script`，harness fork 並追蹤整個樹。 |
| **B. `gh run watch ... \| tail -N`** 無 `run_in_background` | `gh run watch` 內含 long-poll，網路抖動會讓它 hang 或異常退出；同步阻塞 Bash 工具直到超時，最後的退出狀態可能沒回到 harness。 | 用 `run_in_background=true` + 在指令裡寫 `until` 輪詢 conclusion 欄位（API 比 watch 穩定）。 |
| **C. 長 `\| tee log \| tail -250`** 包住主流程 | 主程序輸出停頓時 `tail` 不退；主程序若 SIGPIPE 就連同 release.sh 一起死掉，造成「跑到一半神隱」。 | 主流程直接 `> log 2>&1`，要看尾巴就另開 Bash `tail -f` 一次性讀。 |

## 標準等待長任務的指令樣板

```bash
# ✅ 正確：用 run_in_background=true 且明確檢查所有終態
Bash(
  command: 'until grep -qE "Release ready|✗ |notarization failed|BUILD FAILED|Invalid" /tmp/release.log; do sleep 10; done; tail -40 /tmp/release.log',
  run_in_background: true,
  timeout: 1800000
)
```

**重點**：
- `until grep` 的 pattern **必須涵蓋成功 + 失敗 + 異常** 三種終態，否則崩潰時會等到 timeout 才退（過程中 UI 顯示 Running）。
- timeout 設遠大於預期完成時間（不過短，因為 timeout 觸發 = 任務被 kill，看不到後續輸出）。
- 主任務本身仍用 `nohup ... &` 啟動是 OK 的，**只要旁邊配一個 `until grep` 等待器**——後者由 harness 直接管，能正常發完成通知。

## 偵測殭屍任務 SOP

如果 UI 顯示某 task 「跑很久」（> 60 分鐘）且懷疑卡住：

```bash
# 1. 看實際 OS process 是否還在
ps aux | grep -E "<關鍵字>" | grep -v grep

# 2. 看 task output 檔的修改時間（mtime 停滯就是死了）
ls -lat /private/tmp/claude-501/*/tasks/<task-id>.output
stat -f "size=%z  mtime=%Sm" <output 路徑>

# 3. 若無 process + mtime 已停滯：用 TaskStop 試（即使回 "No task found" 也代表 harness 已不認它）
TaskStop(task_id: <id>)
```

如果 TaskStop 回 "No task found" 而 UI 仍顯示 Running——這是 **UI 顯示快取 bug**，功能上無害。建議使用者重新整理 Claude Code，或直接忽略。

## v1.1.2 release 復原記錄

| 時間 | 發生什麼 |
|---|---|
| 17:44 | `nohup ./release.sh &` 啟動，Bash 工具瞬間 exit；UI 從此認定該任務 Running |
| ~17:54 | `Monitor` 任務（filter 為 `▸\|✓\|✗\|status:\|id:\|Accepted`）被使用者透過介面 kill；UI 仍未更新 |
| ~19:44 | release.sh 因 SIGPIPE 死亡（被 `tail -250` pipe 連坐），但 Apple notarization 端非同步繼續，最終 Accepted |
| 19:47 | 手動補完 staple → DMG → 第二次 notary → publish |
| 22:22 | `gh run watch` 在後段因網路斷線退出，但 UI 任務狀態保留 |

→ 教訓：**non-trivial pipeline 要拆細階段、各階段獨立 polling、不要靠長 monitor。**

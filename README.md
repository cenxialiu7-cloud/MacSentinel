# MacSentinel

> 原生 macOS 系統優化 + 安全工具。Swift 5.10 / SwiftUI / IOKit / XPC。

[![Latest Release](https://img.shields.io/github/v/release/cenxialiu7-cloud/MacSentinel?style=flat-square)](https://github.com/cenxialiu7-cloud/MacSentinel/releases/latest)
[![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue?style=flat-square)](https://www.apple.com/macos/)
[![Notarized](https://img.shields.io/badge/Notarized-Apple-success?style=flat-square)](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

## 下載

到 **[Releases 頁面](https://github.com/cenxialiu7-cloud/MacSentinel/releases/latest)** 下載最新 `MacSentinel-x.y.z.dmg`，掛載後拖曳到 Applications 即可使用。

DMG 已通過 Apple 公證 (Notarized)，首次啟動不會被 Gatekeeper 阻擋。

## 系統需求

- macOS 14.0 (Sonoma) 以上
- Apple Silicon 或 Intel（Universal Binary）

## 三個編譯目標

| Target | 用途 |
|---|---|
| `MacSentinel` | 主 GUI App |
| `MacSentinelMCP` | CLI binary，提供 14 個 MCP 工具給本機 AI 助理（Claude Code、Cursor 等） |
| `MacSentinelHelper` | Privileged XPC Helper，處理 root 權限路徑 |

## 從原始碼建置

```bash
# 開發版（ad-hoc 簽，本機跑）
./Scripts/build_dmg.sh

# 發佈版（Developer ID + Apple 公證 + DMG）
./Scripts/release.sh
```

`release.sh` 需先設定：
- Developer ID Application 憑證在 login keychain
- `xcrun notarytool store-credentials "MacSentinel-Notary" ...` 已執行

專案使用 [xcodegen](https://github.com/yonaskolb/XcodeGen) 從 `project.yml` 生成 `.xcodeproj`——**修改專案設定一律改 `project.yml`**。

## License

待定 / TBD

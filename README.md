# Nano Panda

Nano Panda 是一款原生 macOS 应用，用于集中管理八款 Agent 工具的全局 MCP 配置。支持 Claude Code、Codex、Antigravity、Claude Desktop、Cursor、Windsurf、Gemini CLI 和 OpenCode。

## 构建与运行

需要 macOS 14 或更新版本，以及支持 Swift 5.9 或更新版本的 Xcode 或 Command Line Tools。项目没有第三方 Swift 包依赖。

```sh
swift build
swift test
./scripts/bundle-app.sh
open dist/NanoPanda.app
```

也可以在 Xcode 中打开 `Package.swift`。打包脚本生成供本机使用的临时签名应用，无需 Mac App Store 沙盒权限。

## 使用

1. 从工具栏扫描并导入现有 MCP，或新建条目、粘贴 JSON。
2. 在编辑器或工具矩阵分配工具。矩阵列标题提供批量启用和停用。
3. 打开同步预览，检查每个工具的文件差异后确认。默认模式仅管理已分配或曾经托管的条目。完全同步会列出各工具中将删除的未分配条目。
4. 在「工具与备份」检查配置路径、外部修改和备份历史，也可预览并恢复原文件。

## 配置导入和导出

在「MCP」菜单或工具栏的更多菜单中选择导入或导出。导出时可挑选条目，并使用密码、32 字节 Base64 密钥或明文。解密需要原密码或密钥。密码模式使用 PBKDF2-HMAC-SHA256（600,000 次）和随机盐，密码模式和密钥模式都使用 AES-256-GCM。

归档保留 MCP 配置、工具分配、备注、标签和工具覆盖字段。导入前可预览和选择条目。同名条目默认保留本地版本，也可确认用归档替换。导入保存到中央配置库，写入 Agent 配置仍需通过同步预览。

中央配置库和备份保存在 `~/Library/Application Support/NanoPanda/`。原始配置文件、预览和备份可能包含配置中的凭据。中央配置库和备份文件仅对当前用户开放。

OpenCode 兼容 V1 的 `mcp` 和 V2 的 `mcp.servers`。新文件使用 V2 结构，已有文件沿用检测到的结构。Codex 适配器操作 `mcp_servers` TOML 表及其子表。同步预览会提示无法保留的传输类型、无法映射的 Bearer Token 环境变量，以及 Claude Desktop 的远程 MCP 兼容性。

# Nano Panda

Nano Panda 管理多款 Agent 工具的本机 MCP 配置。

## 术语

### 中央配置库（Registry）

Nano Panda 托管的 MCP 条目及其工具分配的集合。

### 工具分配（Tool Assignment）

一个 MCP 条目与一款 Agent 工具之间的启用关系。

### 托管条目（Managed Server）

当前分配给某工具，或由 Nano Panda 上次同步到该工具的 MCP 条目。

### 导入冲突（Import Conflict）

同名来源或中央配置库里的 MCP 条目具有不同的配置。

### 外部修改（Drift）

工具配置文件相对于 Nano Panda 上次成功同步时发生的变化。

### 同步预览（Sync Preview）

针对一组原始配置快照计算出的文件差异和移除清单。

### 备份快照（Backup Snapshot）

可以恢复的写入前文件状态，包含文件尚未创建的状态。

### 云端同步（Cloud Sync）

中央配置库中的 MCP 条目与一个加密远端存储目标之间的双向同步。

### 同步基线（Sync Baseline）

本机上次成功云端同步时确认的 MCP 条目状态，用于判断两端各自做了哪些变更。

### 删除墓碑（Deletion Tombstone）

已删除 MCP 名称及其删除修订的记录，用于向其他设备传播删除。

### 远端版本快照（Remote Version Snapshot）

用户主动保存到远端的一份加密 MCP 条目历史状态。快照可独立于当前云端同步状态预览和恢复。

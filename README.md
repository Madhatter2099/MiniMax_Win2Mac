# Windows → Mac mini：MiniMax Code (MCode) 全量迁移指南

> 适用：你已经在 Mac mini 上装好并登录了 MiniMax Code，现在要把 Windows 那台机器上的
> **所有项目、会话、记忆、Agent、Skill、插件、MCP 配置** 全部搬过来。

---

这个包里已经写好了三个脚本，按第 3 节跑一遍基本就够了。

---

## 1. 数据地图：什么会被搬走，什么不会

| 内容 | 位置 | 迁移 | 说明 |
|------|------|------|------|
| 会话列表 + 全部消息历史 | `v2/sessions/` + `v2/sqlite/runtime-state.sqlite` | ✅ | 核心数据都在这个 sqlite 里 |
| 项目 / 工作区绑定 | sqlite `local_runtime_projects`、`local_runtime_sessions.project_workspace_dir` | ✅ | 里面存的是 Windows 绝对路径，导入后会自动改写 |
| 自定义 Agent（人设、系统提示） | `agents/<名字>/agent.md` + sqlite `agents` 表 | ✅ | 见下方「加密字段」注意事项 |
| Agent 记忆 | `agents/<名字>/memory/MEMORY.md`、`memory/topics/*.md` | ✅ | |
| 用户记忆（你的偏好、身份） | `memory/user.md` | ✅ | |
| 项目记忆 | 项目目录里的 `AGENTS.md` | ✅ | 不在 `.minimax` 里，跟着项目文件夹走 |
| 全局技能 | `skills/<名字>/SKILL.md` | ✅ | Agent 私有技能在 `agents/<名字>/skills/` |
| 本地插件 / 本地插件市场 | `plugins/` | ✅ | |
| MCP 服务器配置 | `mcp.json` | ✅ | |
| 模型、Provider、API Key、权限模式 | `config.yaml` | ✅ | 建议单独确认一下 API Key |
| 定时任务（cron） | sqlite `local_runtime_v2_cron_definitions` | ⚠️ | 命令和路径是 Windows 的，导入后要改或先停掉 |
| 飞书 / Telegram 路由 | `channel-bindings.yaml`、`channel-routes.yaml` | ⚠️ | **两台机器不能同时开桥接**，否则一条消息回两遍 |
| 登录凭证 | `auth/` | ❌ 不迁移 | 设备绑定，Mac 上重新登录即可 |
| 内置技能、插件二进制 | `.builtin-skills/`、`v2/plugin-cache/` | ❌ 不迁移 | 平台相关，App 自动重新下载 |
| 设备标识、租约 | `v2/session-handoff/device-id`、`run/`、`v2/runtime-owner-leases/` | ❌ 不迁移 | 每台机器自己生成 |
| 日志、缓存、prewarm 快照 | `v2/observability/`、`cache/`、`v2/workspaces/` | ❌ 不迁移 | 可重新生成 |
| **项目文件本身**（代码、笔记、PDF…） | 不在 `.minimax` 里，在你自己的目录 | ⚠️ 单独搬 | 如果项目在 OneDrive 里，Mac 上多半已经自动同步好了 |

### 两个容易踩的坑

1. **加密字段**：`agents` 表里的 `enc_display_name` / `enc_description` / `enc_avatar` 是加密存储的，
   密钥跟本机登录态绑定。跨机复制后，**自定义 Agent 的显示名/描述可能显示为空或乱码**。
   人设和系统提示在 `agents/<名字>/agent.md` 里是明文，导入后在 Mac 上用
   `mavis agent update` 重新写一遍名称/描述即可修复。
2. **API Key**：`config.yaml` 里的 `apiKey` 字段如果是占位符或别的机器的 key，
   导入后在「设置 → 模型」里重填一次。

---

## 2. 动手前请确认这 5 件事

1. **先把 Windows 上正在跑的 MCode 完全退出**（菜单栏 → 退出，不是关窗口）。它开着的时候
   sqlite 处于写入状态，硬拷贝会坏库。
2. **Windows 端也要是同一个大版本**（桌面版要能跑 local-runtime-v2）。
   脚本导出的 `export-manifest.json` 里会带上 `mcodeAppVersion`，两边对一下。
3. **项目文件夹要单独搬**。`.minimax` 里只有「会话和路径」，代码和笔记本体不在里面。
   如果项目在 OneDrive 里，Mac mini 装了 OneDrive 客户端就自动同步好了，只是盘符路径不同。
4. **重新登录一次**。迁移不包含登录态。
5. **飞书/Telegram 桥接只留一台**。迁移完把 Windows 那台上的桥接关掉（或者反过来），
   否则同一个群里的消息会被两个 Agent 各回一次。

---

## 3. 操作步骤

### 3.1 在 Windows 上导出

把 `windows-export.ps1` 放到 Windows 上任意目录（比如桌面），然后在 **PowerShell** 里：

```powershell
# 右键开始菜单 → 终端(管理员) 或 普通 PowerShell 都可以
cd $HOME\Desktop
powershell -ExecutionPolicy Bypass -File .\windows-export.ps1
```

脚本会：检查 MCode 是否已退出 → checkpoint sqlite WAL → 用 robocopy 拷贝（自动排除
`auth/`、`.builtin-skills/`、`v2/plugin-cache/` 等机器相关目录）→ 生成 `export-manifest.json` →
压缩成 `C:\Users\<你>\Desktop\mcode-migration-windows-<时间戳>.zip`，
并在最后列出检测到的 Windows 工作区路径。

如果 MCode 数据目录改过位置：

```powershell
powershell -ExecutionPolicy Bypass -File .\windows-export.ps1 -DataDir 'D:\mcode-data'
```

### 3.2 把 zip 传到 Mac mini

任选一种方法，无所谓

### 3.3 在 Mac mini 上导入

```bash
cd "/Users/ni0kk/Library/CloudStorage/OneDrive-個人/_AI/Daily/mcode-migration"
chmod +x mac-import.sh

# 先完全退出 MCode（Cmd+Q），然后：
./mac-import.sh --zip ~/Downloads/mcode-migration-windows-20261022-120000.zip
```

脚本会依次：

1. 确认 MCode 没在运行（**在跑就直接拒绝**，避免毁库）
2. 把导出包解到临时目录
3. 把当前 `~/.minimax` **改名备份**到 `~/.minimax.backup-<时间戳>`（不会删）
4. 装入 Windows 的数据，同时保留 Mac 自己的机器相关部分（登录态、内置技能、插件二进制…）
5. 改写 sqlite 里所有 Windows 绝对路径 → Mac 绝对路径，理论上可自动识别，但是你们的工作区文件的位置在两台电脑上不太可能完全一样吧（
6. 打印校验报告


针对工作区文件，可以一步到位手动指定规则：

```bash
# D 盘上的项目也要搬过来
./mac-import.sh --zip <zip> --map 'D:\Projects=/Users/ni0kk/Projects'
```

或者先执行对记忆文件本身的解压迁移，然后
```bash
python3 rewrite_paths.py \
  --db ~/.minimax/v2/sqlite/runtime-state.sqlite \
  --manifest ~/.minimax/export-manifest.json \
  --map 'D:\_AI_Works=/Users/ni0kk/Library/CloudStorage/OneDrive-個人/_AI_works' \
  --apply
```



### 3.4 导入后验证

| 检查项 | 期望结果 | 快速命令 |
|--------|----------|----------|
| 会话历史 | Windows 上的会话都在 | App 里翻历史 |
| 消息内容 | 打开旧会话能正常读 | App 里点开一条 |
| 项目路径 | 显示 `/Users/ni0kk/...` 而不是 `C:\...` | `sqlite3 ~/.minimax/v2/sqlite/runtime-state.sqlite "select workspace_dir from local_runtime_projects;"` |
| 自定义 Agent | 列表里有，名字不乱码 | App 里看 Agents |
| 记忆 | 偏好和 Agent 经验都在 | 直接问它「你记得我什么」 |
| Skill | 用户安装的 skill 可见 | App 里看 Skills |
| MCP | 服务器列表非空且能调用 | App 里看 MCP |
| 定时任务 | 命令/路径已改成 Mac 的 | App 里看 Scheduled Tasks |

---

---

## 5. 出问题了怎么查

| 症状 | 原因 | 处理 |
|------|------|------|
| MCode 启动就报错 / 数据库 locked | 导入时 MCode 还在跑，或 WAL 没 checkpoint | 完全退出 MCode（含后台进程）→ 用脚本的备份目录恢复 → 重来 |
| 会话列表是空的 | sqlite 没换成功 | 确认 `~/.minimax/v2/sqlite/runtime-state.sqlite` 的修改时间是不是刚导入的 |
| 会话能打开但内容空 | 只导入了文件没导入 sqlite，或反之 | 两个来源要一起导 |
| 项目还显示 `C:\...` | 路径规则没覆盖到 | 用 `--map 'C:\Users\<你>=/Users/<你>'` 再跑一次改写 |
| 自定义 Agent 名字空白/乱码 | `enc_*` 字段是设备绑定加密 | 人设在 `agents/<名字>/agent.md`，在 Mac 上 `mavis agent update` 重写名称/描述 |
| MCP server 不见了 | `mcp.json` 没导出 | 在 Windows 上确认 `<数据目录>/mcp.json` 存在，重新导出 |
| 定时任务报错 | cron 里是 Windows 命令/路径 | 在 App 里逐个改成 Mac 路径，或先停用 |
| 飞书消息被回复两次 | 两台机器都在跑桥接 | 关掉其中一台的桥接 |
| 模型用不了 / 401 | API Key 没带过来或是别的机器的 | 重新填 API Key |

---

## 6. 随时可以回滚

导入脚本不会删除任何东西，原数据完整保存在：

```
~/.minimax.backup-<导入时刻>
```

回滚：

```bash
rm -rf ~/.minimax && mv ~/.minimax.backup-<导入时刻> ~/.minimax
```

---

## 7. 文件说明

| 文件 | 在哪台机器上跑 | 作用 |
|------|----------------|------|
| `windows-export.ps1` | Windows (PowerShell) | 打包数据目录为 zip，并生成清单 |
| `mac-import.sh` | Mac (Terminal) | 备份 → 导入 → 改路径 → 校验报告 |
| `rewrite_paths.py` | Mac（由 `mac-import.sh` 自动调用） | 把 sqlite 里的 Windows 绝对路径改写成 Mac 路径 |

---

## 8. 迁移完成后建议做的事

1. Windows 那台机器上**先别删数据**，等 Mac 上确认会话 / 记忆 / Agent 都正常了再删。
2. 如果 Windows 那台还需要用，让它重新登录一次（登录态本来就没迁移），但**不要两台同时开飞书桥接**。
3. 项目文件夹如果不在 OneDrive 里，记得单独搬到 Mac，并对应改一下项目路径。
4. 之后的日常备份可以更简单：
   ```bash
   # macOS 上定时快照（排除缓存和日志）
   cd ~/.minimax && tar czf ~/mcode-backup-$(date +%F).tar.gz \
     --exclude='v2/observability' --exclude='cache' --exclude='v2/plugin-cache' .
   ```

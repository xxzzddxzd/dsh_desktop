# DSH Desktop 维护与升级指南

DSH Desktop 是一个「只读消费」DSH 服务协议的伴侣应用：它不修改 DSH 的任何包或
配置，只通过 HTTP RPC、两条 WebSocket 事件流和 DSH 的 Web UI 工作。DSH 发新版
时，桌面端**大多数时候不需要改动**；本文件说明什么时候需要改、怎么改，以及用户
机器上的 dsh 运行时如何升级。

## 1. 桌面端与 DSH 的耦合面（DSH 升级时逐一复查）

| # | 耦合面 | 位置 | DSH 升级后要复查什么 |
|---|---|---|---|
| 1 | 启动命令 `dsh web --port <port>` | `ServerManager.spawn`、`LaunchAgentService.writePlist`（仅实验托管模式；默认模式应用不启动 dsh） | `web` 别名与 `--port` 参数是否仍存在 |
| 2 | `dsh --version` 输出版本号 | `DshEnvironment.versionSync` | 版本输出格式（用于更新比对） |
| 3 | HTTP RPC：`POST /api/<method>`，`client-request` 信封 `{type, rpcId, method, payload}` | `DshRpc.call` | 信封结构、`result.ok / result.value` 响应形状 |
| 4 | RPC 方法：`session.list`、`host.describe` | `main.poll`、`ServerManager.checkHealthAndUpdate` | 字段改名/删除（`items`、`version`、`provider`、`model`、`attachedSessions`） |
| 5 | 授权应答：`POST /api/respond`，`client-response` 信封 | `DshRpc.respondApproval` | `accepted` 字段、应答 payload 结构 |
| 6 | WebSocket：`/api/events.host`、`/api/events.mux`，`server-request` 信封 | `DshStreams` | 端点路径、信封 `type` |
| 7 | 事件帧 `payload.type` 集合（session.* / turn-events / todo-events / goal-events / approval-request / approval-resolved / jobs-events …） | `AppState.ingestHostFrame / ingestMuxFrame` | type 改名或删除；字段增减（未知字段会被忽略） |
| 8 | Web UI 会话切换器 DOM：`button[class*="crumb"]`、`button[class*="crumbCurrent"]`、`[role="option"]` 等 | `PanelController.crumbClickScript / crumbTextScript` | **最脆弱的一层**：Web UI 重构后会话跳转可能失效 |

复查原则：信封是**可扩展 JSON**，DSH 侧字段只增不减、桌面端对未知字段一律忽略，
所以第 3–7 项大多数升级是透明的；**第 1、8 项**是真正会出问题的地方。

## 2. DSH 发新版时桌面端的升级步骤

1. **升级本机 dsh 并重启服务**：应用菜单「检查 DSH 更新…」一键完成（相当于
   `npm install -g @deepseek-ai/dsh@latest` + 自动重启服务），或手动执行后从菜单
   重启服务。
2. **跑一遍验证清单**（每项 1 分钟）：
   - [ ] 状态栏：空闲鲸鱼 → 发起任务 → 呼吸脉动 / 进度环
   - [ ] 气泡与通知：任务完成、等待输入、授权气泡的「允许 / 拒绝」按钮
   - [ ] 右键菜单：会话按项目分组、状态点、**点击会话条目能跳到对应对话**
   - [ ] 面板：打开/刷新/窗口模式、ESC 与点击外部关闭
   - [ ] 服务管家：启动/停止/重启、系统服务模式（launchd）切换
   - [ ] 日志窗口：`~/Library/Logs/DSHDesktop/server.log` 有 dsh 输出
3. **若全部通过**：无需改代码（桌面端会自动忽略新增字段），并把新验证通过的
   版本族加入 `DshEnvironment.supportedVersionFamilies`（否则每次启动都会提示
   「版本未验证」）。
4. **若某项失败**：
   - 事件/字段类 → 改 `AppState.swift` 的解析；用
     `defaults write dev.mydsh.dsh-desktop debugDump -bool true` 输出状态明细、
     `tools/probe-streams.mjs` 观察原始帧。
   - 会话跳转类 → 用 `defaults write dev.mydsh.dsh-desktop debugProbeId / debugProbeTitle`
     做 DOM 探针，更新 `PanelController.swift` 的选择器。
   - 启动参数类 → 改 `ServerManager.spawn` 与 `LaunchAgentService.writePlist`。
5. **发布**：更新 `Resources/Info.plist` 的 `CFBundleShortVersionString` /
   `CFBundleVersion`，`./scripts/build.sh` 后 `./install.sh`（或应用菜单「安装到
   「应用程序」」）。

## 3. 用户机器上的 dsh 运行时如何升级

- **自动提示**：桌面端启动后每天检查一次 npm 最新版（`registry.npmjs.org`），
  有新版时弹气泡 + 系统通知，右键菜单出现「更新 DSH 到 vX…」，确认后自动执行
  `npm install -g @deepseek-ai/dsh@latest` 并重启服务。
  - 关闭自动检查：`defaults write dev.mydsh.dsh-desktop autoCheckUpdates -bool false`
  - 手动检查：右键菜单「检查 DSH 更新…」
- **手动**：`npm install -g @deepseek-ai/dsh@latest`，然后在菜单重启服务。
- **未安装 dsh**：桌面端启动时检测到会弹出安装引导（见 README「首次启动」）。

## 4. 发布桌面端 checklist

- 默认「仅校验/挂载」：应用不启动、不停止 dsh（实验托管模式在
  `Settings.manageServer` 之后，默认关闭），发布前优先验证挂载路径。
- 构建产物是 **ad-hoc 签名**（`scripts/build.sh`），分发给他人前建议换成
  Developer ID 签名 + 公证（`codesign --sign "Developer ID Application: …"` +
  `xcrun notarytool submit`），否则 Gatekeeper 会拦截。
- 目标 macOS 13+、Apple Silicon（`-target arm64-apple-macos13.0`）；如需 Intel
  机器，在 `scripts/build.sh` 增加 x86_64 构建或改为 universal。
- 首次启动依赖检查：桌面端会先找 dsh 二进制（设置覆盖 → `/opt/homebrew/bin/dsh`、
  `/usr/local/bin/dsh` → 登录 shell `command -v dsh` → npm 全局 lib 回退），找不到
  则弹安装引导；用户机器没有 Node/npm 时引导会提示先装 Node.js ≥ 20。
- 开机自启（SMAppService）要求应用位于 /Applications，用「安装到「应用程序」」。

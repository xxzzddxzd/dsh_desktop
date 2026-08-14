# DSH Desktop · 详细功能与架构

> 本文档是项目的详细说明（原主 README 内容），面向开发者与深度用户；
> 对外简介见仓库根目录 [README.md](../README.md)，升级维护清单见 [UPGRADE.md](../UPGRADE.md)。

DSH（DeepSeek Harness）的 macOS 菜单栏伴侣应用 —— 参考 CodexScope Desktop 的形态，把 DSH 变成一个常驻菜单栏、随时可呼出的桌面应用。

纯 Swift + AppKit + WebKit 实现，**不修改 DSH 核心**：它通过 DSH 服务已有的
HTTP RPC（`/api/*`）与两条 WebSocket 下推流（`/api/events.host`、`/api/events.mux`）
拿到实时进度，无需任何服务端改动。

## 功能

- **菜单栏事件流（Vibe Island 风格）**：状态栏显示最近发生的高价值事件，而不是聚合数字
  - `DSH 完成 <刚完成的待办>` —— 待办完成时闪现 8 秒（多个完成显示 `+N`）
  - `DSH 完成 <会话名>` —— 某会话完成一轮工作后闪现
  - `DSH 目标完成` / `DSH <任务> 失败` / `DSH 目标阻塞` —— 目标与任务事件
  - **目标阻塞时**：状态栏闪现 + **菜单栏下方弹出气泡**（5 秒自动消失，点击直接打开面板）
    + macOS 系统通知三管齐下
  - **任务完成时**：弹出气泡简报 ——「任务完成 · 会话名」+ 步骤数 · 输出 tokens · 耗时，
    并附 agent 收尾回复的摘要预览（点击打开面板）；目标完成时弹「目标完成」+ 目标内容；
    **气泡与通知二选一**（默认气泡），可在设置「完成提醒方式」切换：气泡 / 系统通知 / 两者
  - **需要授权时**：气泡常驻 60 秒并带 **「允许 / 拒绝」按钮**（Claude Island 同款）——
    无需打开面板，直接通过 `/api/respond` 应答，气泡即点即答
  - `DSH 待审批` / `DSH 等你回答` —— **常驻**直到你处理完（最高优先级，蓝色）；
    你处理后立即清除（resolved 帧 + 会话恢复活动双重信号），
    另有 10 分钟兜底过期，杜绝漏帧导致的假停留
  - **鲸鱼图标即状态**（模板图：暗色菜单栏白色、亮色黑色，背景透明）：
    - 空闲 —— 静态鲸鱼，无任何文字
    - 工作中 —— 鲸鱼**左右游动** + 尾迹圆点（掉头时头部朝向翻转，无文字）
    - 工作中有待办 —— 鲸鱼缩小 + 外围**进度环**（透明轨道 + 高亮弧线随完成率增长）
    - 高信号状态才有文字（无 emoji）：`DSH 待审批` / `DSH 等你回答`（蓝色常驻）、`DSH 阻塞`、`DSH 2 任务`、`DSH 离线` / `DSH 启动中…` / `DSH 出错`
  - 事件闪现：`DSH 完成 <待办>`（8 秒）、`DSH 目标完成` 等
  - tooltip 展示服务器与全部会话明细（标题/状态/待办/步骤）
- **点击即开**：左键弹出面板内嵌 DSH Web UI（webview 常驻，二次打开秒出）；
  焦点在网页内时 ESC 全部交给页面（取消输入法组词等），焦点在网页外时 ESC 关闭面板；
  点击外部关闭；右键打开完整菜单
- **可拖拽调大小**：弹层右下角有拖拽手柄，拖动即可改大小（620×440 起步，屏幕内自适应），
  尺寸永久保存；「窗口模式」的独立窗口用系统原生拖拽 + 自动记忆位置
- **按项目归类的会话清单**：右键菜单按工作目录分组，灰色分组标题 + 平铺条目
  （如 `项目A · 3`、`项目B · 2`、`其他会话`，不折叠二级菜单），
  每项显示状态点 + 标题 + 目标/待办进度；**点击会话条目直接跳到对应对话**：
  DSH Web 没有 URL 深链（源码中唯一的 URL 参数是测试用 `?fixture=`），
  应用改为驱动其会话切换器 —— 点击面包屑弹层、按标题选中目标会话、校验切换结果，
  页面未渲染完成时自动重试
- **窗口模式**：一键把面板切换成可调整大小、记住位置的独立窗口（工具栏同名按钮或菜单）
- **服务管家**：
  - **首次启动环境检查**：自动定位 `dsh`（设置覆盖 → Homebrew / npm 全局 →
    登录 shell PATH）；**未安装时弹出安装引导**，一键执行
    `npm install -g @deepseek-ai/dsh@latest`（实时进度、失败可复制命令到终端）；
    菜单可随时「重新检测 DSH 环境…」
  - **版本白名单**：内置已收录的 dsh 版本族，启动时若检测到未收录版本，
    气泡 + 通知提示「可能不完全兼容」（只提示，不拦截）
  - **DSH 更新检查**：每天自动比对 npm 最新版，有新版弹气泡/通知，右键菜单
    「更新 DSH 到 vX…」一键升级（托管模式下自动重启服务，否则终端重启）；
    也可手动「检查 DSH 更新…」
  - **dsh 由谁启动（三种方式）**：
    - *仅校验 / 挂载*（默认）：应用**不启动、不停止 dsh**——你在终端自行运行
      `dsh web`（菜单「在终端中启动 DSH…」帮你开好终端并复制命令），
      应用自动发现端口、实时校验状态并挂载
    - *应用托管（实验）*：应用拉起 `dsh web` 作为子进程，崩溃自动重启（指数退避，最多 5 次），
      退出时回收 —— 适合临时使用
    - *系统服务模式（launchd，实验）*：安装为 `~/Library/LaunchAgents/dev.mydsh.dsh-server.plist`
      用户 LaunchAgent，登录自启（RunAtLoad）、异常退出自动拉起（KeepAlive）、
      **应用退出后服务继续运行**；菜单「系统服务模式（launchd）」或设置里一键切换
  - 自动发现端口上已运行的 DSH 并**挂载**（绝不误杀非自有的服务）
  - 日志实时滚动（菜单「查看服务日志…」，文件在 `~/Library/Logs/DSHDesktop/server.log`，
    launchd 模式的输出也写同一文件）
  - 启动自愈：退出服务模式后自动清理残留的 LaunchAgent
- **舒适体验**：
  - 全局快捷键 `⌃⌥D` 随时唤起面板
  - 系统通知：回合完成 / 等待你输入或授权 / 目标创建·完成·阻塞 / 服务离线·出错
    （均可在设置里分别开关）
  - 开机自启（SMAppService）、深色模式自适应、一键「安装到「应用程序」」
  - 面板工具栏：浏览器打开 / 刷新 / 窗口模式 / 设置 / 退出
  - 内置主菜单，⌘C/⌘V 在网页输入框里可用、⌘R 刷新、⌘Q 退出

## 构建

要求：Xcode Command Line Tools（Swift 5 模式编译，目标 macOS 13+，Apple Silicon）。

```bash
./scripts/build.sh
open "dist/DSH Desktop.app"
```

产物：`dist/DSH Desktop.app`（ad-hoc 签名）。安装到 /Applications：

```bash
./install.sh          # 或应用菜单里的「安装到「应用程序」…」
```

## 使用

首次启动会自动：

1. **检查 dsh 环境**：未安装则弹出安装引导（一键 npm 安装 / 手动指南 / 稍后再说）；
2. 挂载到 `127.0.0.1:3080` 上已运行的 DSH（**默认不代启动**：请自行运行
   `dsh web`，或菜单「在终端中启动 DSH…」）；
3. 请求系统通知授权（拒绝也不影响其他功能，可稍后在「系统设置 › 通知」里开启）。

菜单栏：**左键** = 面板，**右键** = 菜单（会话列表、服务控制、开关、设置、退出）。

## 设置

菜单「设置…」可改：端口、dsh 可执行文件路径、服务工作目录、是否由应用托管
dsh 服务（实验，默认关闭）、自动启动、四类通知开关、快捷键、开机自启。

> 提示：开机自启（SMAppService）要求应用位于 /Applications，先用「安装到「应用程序」」。
> 命令行偏好值也可用 `defaults write dev.mydsh.dsh-desktop <key> -<type> <value>` 修改，
> 例如 `defaults write dev.mydsh.dsh-desktop port -int 3080`。
> 相关键：`manageServer`（bool，应用托管 dsh，默认关）、
> `autoCheckUpdates`（bool，每日自动检查 dsh 更新，默认开）、
> `lastUpdateCheckAt`（double，上次检查时间戳，自动维护）。

## 架构

```
Sources/
  main.swift                 入口：AppDelegate 装配、主菜单、轮询兜底、SIGTERM 优雅退出
  StatusItemController.swift 菜单栏项 + 进度文案渲染（StatusText）
  MenuController.swift       右键菜单（打开时按当前状态重建）
  PanelController.swift      面板：popover/窗口双形态 + WKWebView + 离线重试浮层
  ServerManager.swift        服务发现与状态校验（实验托管模式含拉起/守护/回收）+ PATH 修正 + 日志管道
  DshRpc.swift               /api HTTP RPC 客户端（client-request 信封）
  DshStreams.swift           events.host / events.mux WebSocket 订阅 + 断线重连
  AppState.swift             状态聚合：目标/待办/任务/步骤 + 通知决策
  DshEnvironment.swift       dsh 探测/版本查询 + npm 安装与更新 + 最新版检查
  SetupWindowController.swift 安装引导与更新进度窗口（未安装/升级两种形态）
  Settings.swift / LogStore.swift / Notifier.swift / HotKey.swift /
  BubbleController.swift / LaunchAgentService.swift /
  SettingsWindowController.swift / LogWindowController.swift
tools/
  genicon.swift              应用图标生成（鲸鱼徽标，CoreGraphics）
  svgtest.swift              SVG 加载验证小工具
  probe-streams.mjs          只读调试：观察 DSH 两条事件流（可选）
```

数据流：WebSocket 帧 → `AppState`（串行队列聚合）→ 主线程 `onChange` →
状态栏/菜单/面板统一刷新；15s 轮询 `session.list` + `host.describe` 作为兜底。

## 开发调试

```bash
defaults write dev.mydsh.dsh-desktop debugDump -bool true    # 状态明细写入日志
defaults write dev.mydsh.dsh-desktop debugAutoOpen -bool true # 启动自动弹出面板
```

## 与 DSH 的关系

- 只读消费 DSH 的公开 wire 协议（`session.list`、`host.describe`、两条事件流），
  不注入、不修改 DSH 的任何包或配置；
- DSH 升级后协议字段有增无减（信封为可扩展 JSON），应用对未知字段全部忽略；
- 启动时校验 dsh 版本是否在已收录版本族内（`DshEnvironment.supportedVersionFamilies`），
  未收录只提示可能不兼容，不拦截；
- 挂载模式下永远不向服务端发送管理类 RPC，也不会终止非自有进程。
- dsh 的安装/升级（`npm install -g @deepseek-ai/dsh@latest`）只在用户确认后执行；
  桌面端自身的升级维护清单见 [UPGRADE.md](UPGRADE.md)。

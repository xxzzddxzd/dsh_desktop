# DSH Desktop

[English](README.md) · 简体中文

DSH（DeepSeek Harness）的 macOS 菜单栏伴侣应用：把 DSH 变成一个常驻菜单栏、随时可呼出的桌面应用。纯 Swift + AppKit + WebKit 实现，**不修改 DSH 核心** —— 只通过 DSH 服务已有的 HTTP RPC 与两条 WebSocket 事件流读取实时进度，并把 Web UI 内嵌到弹出面板里。

## 功能一览

- **菜单栏状态机**：鲸鱼图标即状态（空闲 / 呼吸脉动 / 待办进度环 / 高信号文字），事件闪现 + 气泡简报 + 系统通知（目标阻塞、任务完成、等待输入、需要授权三管齐下）
- **点击即开的面板**：内嵌 DSH Web UI（常驻加载），支持拖拽调大小、窗口模式、⌃⌥D 全局快捷键
- **按项目归类的会话清单**：右键菜单直接跳到对应对话
- **服务管家（默认仅校验/挂载）**：自动发现端口上已运行的 DSH 并挂载，实时校验状态；不启动、不停止你的 dsh（实验性托管/launchd 模式可选）
- **dsh 环境自检**：启动时定位 `dsh`，未安装弹出引导一键 `npm install -g @deepseek-ai/dsh@latest`；每日检查更新，一键升级
- **版本白名单**：启动时校验 dsh 版本是否在已收录版本族内，未收录仅提示可能不兼容

详细功能与架构见 [docs/FEATURES.md](docs/FEATURES.md)；与 DSH 的耦合面和升级清单见 [UPGRADE.md](UPGRADE.md)。

## 要求

- macOS 13+（Apple Silicon）
- [DSH](https://github.com/deepseek-ai/deepseek-harness)：`npm install -g @deepseek-ai/dsh`
- 未安装 DSH 时应用会自动引导安装（需要 Node.js ≥ 20）

## 安装

**一键安装**（下载最新 GitHub Release 到 /Applications，自动去除 quarantine）：

```bash
curl -fsSL https://raw.githubusercontent.com/xxzzddxzd/dsh_desktop/main/install.sh | bash
```

**Homebrew**：

```bash
brew tap xxzzddxzd/dsh_desktop
brew install --cask dsh-desktop
```

**从源码构建**（需要 Xcode Command Line Tools）：

```bash
./scripts/build.sh          # 产物：dist/DSH Desktop.app（ad-hoc 签名）
./install.sh                # 安装本地构建到 /Applications
```

> 应用为 ad-hoc 签名、未公证：一键脚本会自动去除 quarantine；手动下载安装后
> 若 Gatekeeper 拦截，右键 → 打开。正式分发建议 Developer ID 签名 + 公证
> （见 [UPGRADE.md](UPGRADE.md)）。
>
> 发布新版本：`./scripts/release.sh`（构建 + 打包 + gh release）。ad-hoc 构建
> 每次产物哈希不同，发布前需同步 `Casks/dsh-desktop.rb` 的 sha256（脚本会校验）。

## 使用

首次启动自动检查 dsh 环境并请求通知授权。启动 dsh 后（终端运行
`dsh web`，或菜单「在终端中启动 DSH…」自动开终端并复制命令），应用自动挂载。

菜单栏：**左键** = 面板，**右键** = 菜单（会话列表、服务状态、dsh 更新、设置、退出）。

## 与 DSH 的兼容性

只读消费 DSH 的公开协议（`session.list`、`host.describe`、两条事件流），未知字段全部忽略。当前已收录版本族：`0.1.0`（含 rc 系列）；检测到未收录版本时启动会提示可能不兼容。DSH 发新版后桌面端的更新步骤见 [UPGRADE.md](UPGRADE.md)。

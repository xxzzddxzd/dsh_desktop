# DSH Desktop

A macOS menu bar companion for [DSH (DeepSeek Harness)](https://github.com/deepseek-ai/deepseek-harness) — turn DSH into an always-on, summon-anytime desktop app. Pure Swift + AppKit + WebKit, **no changes to DSH's core**: it reads real-time progress through DSH's existing HTTP RPC and two WebSocket event streams, and embeds the web UI in a popover panel.

[简体中文](README.zh.md)

## Highlights

- **Menu bar state machine**: the whale icon is the status (idle / breathing pulse / todo progress ring / high-signal text), with event flashes, bubble briefings, and system notifications (goal blocked, task done, waiting for input, approval needed)
- **Click-to-open panel**: embedded DSH Web UI (persistent), resizable, window mode, ⌃⌥D global hotkey
- **Sessions grouped by project**: right-click menu jumps straight to a conversation
- **Server manager (attach-only by default)**: auto-discovers a running DSH on the port and attaches, verifying status in real time; never starts or stops your dsh (experimental managed / launchd modes available)
- **dsh environment self-check**: locates `dsh` at launch; if missing, an onboarding window installs it via `npm install -g @deepseek-ai/dsh@latest`; daily update checks with one-click upgrade
- **Version whitelist**: warns (non-blocking) when the installed dsh version is not in the verified family list

Detailed features & architecture: [docs/FEATURES.md](docs/FEATURES.md)（中文）.
Coupling surface & upgrade checklist: [UPGRADE.md](UPGRADE.md)（中文）.

## Requirements

- macOS 13+ (Apple Silicon)
- [DSH](https://github.com/deepseek-ai/deepseek-harness): `npm install -g @deepseek-ai/dsh`
- The app guides the install automatically when DSH is missing (requires Node.js ≥ 20)

## Install

**One-liner** (downloads the latest GitHub release into /Applications, clears quarantine):

```bash
curl -fsSL https://raw.githubusercontent.com/xxzzddxzd/dsh_desktop/main/install.sh | bash
```

**Homebrew**:

```bash
brew tap xxzzddxzd/dsh_desktop
brew install --cask dsh-desktop
```

**Build from source** (requires Xcode Command Line Tools):

```bash
./scripts/build.sh          # produces dist/DSH Desktop.app (ad-hoc signed)
./install.sh                # installs the local build into /Applications
```

> The app is ad-hoc signed and not notarized: the one-liner clears quarantine
> automatically; for a manual download, right-click → Open if Gatekeeper blocks it.
> For public distribution consider Developer ID signing + notarization
> (see [UPGRADE.md](UPGRADE.md)).
>
> Publishing a new release: `./scripts/release.sh` (build + package + gh release).
> Ad-hoc builds are not reproducible across rebuilds, so sync the
> `Casks/dsh-desktop.rb` sha256 before publishing (the script verifies it).

## Usage

On first launch the app checks the dsh environment and requests notification permission.
Start dsh (run `dsh web` in a terminal, or use the menu item “Launch DSH in Terminal…”
which opens a terminal and copies the command), and the app attaches automatically.

Menu bar: **left-click** = panel, **right-click** = menu (sessions, server status, dsh updates, settings, quit).

## Compatibility with DSH

Read-only consumer of DSH's public protocol (`session.list`, `host.describe`, two event
streams); unknown fields are ignored. Verified version family: `0.1.0` (incl. rc series);
unlisted versions trigger a non-blocking compatibility warning at launch. See
[UPGRADE.md](UPGRADE.md) for the procedure when DSH ships a new release.

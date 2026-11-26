# Claude Cache Keepalive

A tiny macOS menu bar app that keeps Claude Code prompt caches warm.

## Why

Claude Code's prompt cache has a 5-minute TTL. Reading a warm cache costs **0.1x** the input price, while rebuilding it costs **1.25x** (5-minute TTL). One cold rebuild costs as much as ~12 cache reads — so keeping a session warm pays off as long as you come back within about an hour.

## What it does

- Watches transcripts under `~/.claude/projects` and locks under `~/.claude/sessions`. Ordinary transcript changes update only the affected sessions. The list shows sessions that are **still open** or were active in the last 2 minutes.
- Sends a minimal resume request to each **selected** session every **4 m 30 s**
- Keeps a session warm for at most **1 hour after its last real activity** — past that, keepalive costs more than a cold rebuild, so it stops and waits for your next message
- Skips pinging when the cache is already known to be expired (e.g. after system sleep), avoiding a paid full rebuild
- Auto-pauses a session after two consecutive cache misses
- Prevents system sleep while at least one keepalive task is active, and releases the assertion when none is left (display sleep is never blocked)
- Never writes to your transcripts (`--no-session-persistence`)

## How it works

Each keepalive ping is just a normal (tiny) `claude -p --resume` call:

```bash
CLAUDE_CODE_MAX_OUTPUT_TOKENS=1 claude -p --resume <session-id> \
  --no-session-persistence --permission-prompts none \
  --permission-mode dontAsk --max-turns 1 \
  --model <session-model> --output-format json \
  "Do not use any tools. Reply with just: ok"
```

- `--permission-mode dontAsk` skips the auto-mode classifier request (one less model call)
- `--max-turns 1` keeps it to a single model turn
- `--model <session-model>` reuses the session's own model, so the cache prefix matches
- `CLAUDE_CODE_MAX_OUTPUT_TOKENS=1` caps the reply at ~1 token. Output is typically 2–3 tokens; some third-party relays ignore this field (see caveats)

It does **not** patch Claude Code, inject anything, or modify any configuration.

## UI

The app opens in the menu bar. Choose **管理会话…** to open the management window. The icon adapts to light/dark and shows a badge when sessions need restoring.

- Status line: `N 个会话保活中 · M 个待恢复` / `尚未选择会话`
- 管理会话…
- 立即保活 `⌘P` (disabled when there is nothing to keep warm)
- 退出缓存保活 `⌘Q`

Management window:

- One row per session: checkbox, title, `project · model · last active`, status on the right
- Click anywhere in a row to toggle keepalive (the checkbox and restore button still work on their own)
- Status values: `距下次保活 mm:ss` / `排队中` / `未启用` / `已暂停 · 连续未命中` / `已停止 · 超过 60 分钟未活动` / `缓存已过期 · 等待新消息`
- Footer: 打开日志, 刷新 (manual rescan), 立即保活; the window is resizable

## Build

Requires macOS 13+ and the Swift toolchain (Xcode Command Line Tools). No dependencies.

```bash
swiftc -O -swift-version 5 -framework Cocoa -framework IOKit main.swift -o ClaudeKeepalive
cp ClaudeKeepalive "Claude保活工具.app/Contents/MacOS/ClaudeKeepalive"
codesign --force --deep --sign - "Claude保活工具.app"
open "Claude保活工具.app"
```

The app runs as a menu bar item (`LSUIElement`), so it has no Dock icon. To regenerate the icon, run `swift gen_icon.swift`, then build the `.icns` with `iconutil`.

## Configuration

Knobs via environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `CACHEKEEPER_IDLE` | 270 | seconds of inactivity before a session becomes eligible (4 m 30 s) |
| `CACHEKEEPER_INTERVAL` | 270 | minimum seconds between pings per session |
| `CACHEKEEPER_KEEPWINDOW` | 3600 | stop keeping a session warm this long after its last real activity |
| `CACHEKEEPER_TTL` | 300 | cache TTL; a session older than this is treated as expired and not pinged |
| `CACHEKEEPER_WINDOW` | 1800 | listed-session window for sessions without a live lock |
| `CACHEKEEPER_MAX` | 4 | max sessions kept warm at once |
| `CACHEKEEPER_TICK` | unset | optional periodic scheduler check interval in seconds (defaults to deadline-based scheduling) |
| `CACHEKEEPER_TIMEOUT` | 150 | per-ping timeout |
| `CACHEKEEPER_NO_WINDOW` | 1 | set to `0` to open the management window at launch |

If `~/.claude/settings.json` contains `"promptCacheTtl": "1h"`, the ping interval automatically becomes 50 minutes and the TTL check 60 minutes.

Logs: `~/Library/Logs/ClaudeKeepalive.log` — rotates at 1 MB (current + one previous file).

## Caveats

- Only sessions that are still open (Claude Code running) stay listed; closed conversations drop out within 2 minutes
- The upstream must support prompt caching for hits to happen; a relay that rewrites requests may break prefix matching
- Some third-party relays ignore `CLAUDE_CODE_MAX_OUTPUT_TOKENS`, in which case a ping can still generate a few hundred output tokens
- Keepalive economics: warm read = 0.1x input, cold rebuild = 1.25x (5m TTL) — worth it for pauses up to ~1 hour; with 1h TTL (2x write) the break-even is ~20 pings (~9 hours)
- macOS only (AppKit); the UI is in Chinese

## License

MIT — anyone is free to use, modify, and distribute this software. See [LICENSE](LICENSE).

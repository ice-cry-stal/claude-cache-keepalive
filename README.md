# Claude Cache Keepalive

A tiny macOS menu bar app that keeps Claude Code prompt caches warm.

## Why

Claude Code's prompt cache has a 5-minute TTL. Reading a warm cache costs **0.1x** the input price, while rebuilding it costs **1.25x** (5-minute TTL). One cold rebuild costs as much as ~12 cache reads — so keeping a session warm pays off as long as you come back within about an hour.

## What it does

- Scans `~/.claude/projects/*/*.jsonl` every 10 seconds for sessions active in the last 30 minutes
- For each **selected** session idle for 4 m 20 s, sends a minimal resume request every 4 m 20 s
- Never writes to your transcripts (`--no-session-persistence`)
- Auto-pauses a session after two consecutive cache misses, so a broken prefix never burns money silently
- Shows a countdown to the next ping and the last result; the per-session counter resets when you send a new message

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

Menu bar (icon adapts to light/dark; shows a badge when sessions need restoring):

- Status line: `N 个会话保活中 · M 个待恢复` / `尚未选择会话`
- 管理会话…
- 立即保活 `⌘P` (disabled when there is nothing to keep warm)
- 退出缓存保活 `⌘Q`

Management window:

- One row per session: checkbox, title, `project · last active`, and a status on the right (`保活中` / `排队中` / `未启用` / `已暂停`)
- Kept-warm rows show `上次命中 · …`; auto-paused rows show `连续未命中` plus an inline 恢复 button
- Footer: 打开日志 on the left, 立即保活 on the right; the window is resizable

## Build

Requires macOS 13+ and the Swift toolchain (Xcode Command Line Tools). No dependencies.

```bash
swiftc -O -swift-version 5 -framework Cocoa main.swift -o CacheKeeper
cp CacheKeeper CacheKeeper.app/Contents/MacOS/CacheKeeper
codesign --force --deep --sign - CacheKeeper.app
open CacheKeeper.app
```

The app runs as a menu bar item (`LSUIElement`), so it has no Dock icon. To regenerate the icon, run `swift gen_icon.swift`, then build the `.icns` with `iconutil`.

## Configuration

Debug/build knobs via environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `CACHEKEEPER_IDLE` | 260 | seconds of inactivity before a session becomes eligible |
| `CACHEKEEPER_INTERVAL` | 260 | minimum seconds between pings per session |
| `CACHEKEEPER_WINDOW` | 1800 | only sessions active within this window are listed |
| `CACHEKEEPER_MAX` | 4 | max sessions kept warm at once |
| `CACHEKEEPER_TICK` | 10 | scan/check interval |
| `CACHEKEEPER_TIMEOUT` | 150 | per-ping timeout |

If `~/.claude/settings.json` contains `"promptCacheTtl": "1h"`, the ping interval automatically becomes 50 minutes.

Logs: `~/Library/Logs/CacheKeeper.log`

## Caveats

- Only sessions active within the last 30 minutes are considered (up to 10 listed, up to 4 kept warm)
- The upstream must support prompt caching for hits to happen; a relay that rewrites requests may break prefix matching
- Some third-party relays ignore `CLAUDE_CODE_MAX_OUTPUT_TOKENS`, in which case a ping can still generate a few hundred output tokens
- Keepalive economics: warm read = 0.1x input, cold rebuild = 1.25x (5m TTL) — worth it for pauses up to ~1 hour; with 1h TTL (2x write) the break-even is ~20 pings (~9 hours)
- macOS only (AppKit); the UI is in Chinese

## License

MIT — anyone is free to use, modify, and distribute this software. See [LICENSE](LICENSE).

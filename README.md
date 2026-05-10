# claude-statusline-deepseek

DeepSeek-aware statusline for Claude Code. Drop-in replacement for `claude-hud` when you route Claude Code through cc-switch to DeepSeek.

Shows live DeepSeek balance and session spend on the bottom statusbar — claude-hud only knows Anthropic prices, so its cost numbers are wrong on cc-switch + DeepSeek.

## What it shows

```
[Opus] 📁 myproject  🌿 main +2 ~5
████▏░░░░░ 42% (88k/1.0M)  5h ▊░░░░░░░░░ 8%↻3h31m  7d ███████▊░░ 78%↻4d23h  $0.12  ⏱ 1m25s
✓5/8 ⏳1 Build feature X  |  🤖 Explore
```

| Segment | Source | When |
|--------|--------|------|
| `[Model] 📁 dir 🌿 branch +s ~m` | stdin + `git` | always |
| `bar % (used/total)` | stdin `context_window` | always |
| `5h … 7d …` | stdin `rate_limits` | real Anthropic Pro/Max only |
| `$0.12` | stdin `cost.total_cost_usd` | real Anthropic |
| `≈$0.46  💳 1.85 USD (▼0.05)` | DeepSeek `/user/balance` + transcript token sums | cc-switch DeepSeek mode |
| `⏱ 1m25s` | stdin `cost.total_duration_ms` | always |
| `✓done/total ⏳active` | transcript replay (TaskCreate/Update or TodoWrite) | when tasks exist |
| `🤖 N agents: …` | transcript pending Agent tool_uses | when subagents in flight |
| `⚒ Tool` | last-known tool name | when no other activity |

## Provider auto-detection

The script reads `ANTHROPIC_BASE_URL`. If it contains `deepseek.com`, it switches into DeepSeek mode:
- Pulls live balance from `https://api.deepseek.com/user/balance` (cached 60s)
- Estimates session spend from cumulative transcript tokens × DeepSeek pricing
- Tracks balance baseline for "real spend so far" delta

Otherwise it falls back to Anthropic native cost + Pro/Max rate limits. Same script, both modes.

## Install

```bash
git clone <this-repo-url> claude-statusline-deepseek
cd claude-statusline-deepseek
./install.sh
```

Send any message in Claude Code to refresh the statusline.

### What install.sh does

1. Verifies `bash`, `jq`, `curl`, `awk`, `stat`, `git` are installed.
2. Copies `statusline.sh` → `~/.claude/statusline-deepseek.sh` (executable).
3. Backs up `~/.claude/settings.json` to `settings.json.bak-<timestamp>`.
4. Patches `statusLine.command` to point at the new script.
5. Runs a smoke test.

## Uninstall

```bash
./uninstall.sh
```

Restores the most recent settings.json backup, removes the script, clears caches.

## Pricing per model

The script ships with V4 pricing for both currently-active DeepSeek models, picked automatically based on which model cc-switch routes to.

| Model | Cache miss in | Cache hit in | Output |
|-------|--------------|-------------|--------|
| `deepseek-v4-flash` (default; aliases: `deepseek-chat`, `deepseek-reasoner`) | $0.14/M | $0.0028/M | $0.28/M |
| `deepseek-v4-pro` (75%-off promo until 2026-05-31) | $0.435/M | $0.003625/M | $0.87/M |

The cost block in DeepSeek mode shows which pricing is in effect: `≈$0.46 v4-pro`.

### Detection logic

When `ANTHROPIC_BASE_URL` points to DeepSeek, the script reads `ANTHROPIC_DEFAULT_OPUS_MODEL` / `ANTHROPIC_DEFAULT_SONNET_MODEL` / `ANTHROPIC_DEFAULT_HAIKU_MODEL` (the env vars cc-switch sets) and matches against the current `model.id` from stdin. If no mapping is set, falls back to `v4-flash` pricing.

### Manual override

Create `~/.claude/statusline-deepseek.env` to force specific prices:

```bash
DS_PRICE_INPUT_MISS=0.435
DS_PRICE_INPUT_HIT=0.003625
DS_PRICE_OUTPUT=0.87
DS_MODEL_LABEL=v4-pro-custom
```

Sourced after auto-detection — your values always win.

Source for current prices: <https://api-docs.deepseek.com/quick_start/pricing>

## How DeepSeek balance and spend are computed

- **Balance** (`💳 1.85 USD`): GET `/user/balance`, cached for 60s in `${TMPDIR}/dsbal-<session>.json`. Network failures fall back to last cached value.
- **Real session spend** (`▼0.05`): difference between the balance recorded on the first refresh of this session and the current balance. Becomes accurate after the first balance refresh in the new session.
- **Estimate** (`≈$0.46`): cumulative input/output/cache tokens summed from the entire transcript JSONL × DeepSeek pricing. Updates within 3s of new API calls.

## Performance

Statusline is invoked every ~300ms when the session is active. Measured on a 680KB transcript:

| Path | Time |
|------|------|
| Cold (full transcript scan) | ~90ms |
| Warm (3s cache hit) | ~75ms |

For very large transcripts, increase `TX_TTL` in the script.

## Files placed

| Path | Purpose |
|------|---------|
| `~/.claude/statusline-deepseek.sh` | the script |
| `~/.claude/settings.json` | edited: `statusLine.command` |
| `~/.claude/settings.json.bak-<timestamp>` | pre-install backup |
| `~/.claude/statusline-deepseek.env` | optional pricing overrides |
| `${TMPDIR}/dsbal-<session>.json` | balance cache (60s TTL) |
| `${TMPDIR}/dsbase-<session>.txt` | session-start balance baseline |
| `${TMPDIR}/dstx-<session>.json` | transcript scan cache (3s TTL) |

## Caveats

- DeepSeek does not expose Pro/Max-style rate limit metadata, so the `5h`/`7d` bars only appear when on real Anthropic.
- DeepSeek does not provide a documented "today's spend" or per-call cost endpoint — the `platform.deepseek.com/usage` page uses a session-cookie internal API. This statusline avoids it.
- The "real spend" delta only reflects this session's drawdown from when the script first observed the balance. If you share the API key with another client, deltas will mix.
- macOS / Linux / WSL / Git Bash on Windows are supported. Pure CMD / PowerShell are not (Claude Code itself prefers Git Bash on Windows).

## License

MIT

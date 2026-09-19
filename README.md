# claude-statusline-deepseek

DeepSeek-aware statusline for Claude Code. Drop-in replacement for `claude-hud` when you route Claude Code through cc-switch to DeepSeek.

Shows live DeepSeek balance and session spend on the bottom statusbar — claude-hud only knows Anthropic prices, so its cost numbers are wrong on cc-switch + DeepSeek.

Spend is displayed in **CNY (元)** by default and accounts for DeepSeek's peak/idle
pricing (peak = 2× idle). Set `DS_CURRENCY=USD` for the English-page USD prices.

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
| `≈¥3.26  💳 10.51 CNY (▼0.05)` | DeepSeek `/user/balance` + transcript token sums | cc-switch DeepSeek mode |
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
curl -fsSL https://raw.githubusercontent.com/JayYuuuuu/claude-statusline-deepseek/main/install.sh | bash
```

Send any message in Claude Code to refresh the statusline.

### With opt-in claude-hud cleanup

If you previously installed claude-hud, you can disable it and free its plugin cache (~37MB) in the same step:

```bash
curl -fsSL https://raw.githubusercontent.com/JayYuuuuu/claude-statusline-deepseek/main/install.sh | bash -s -- --remove-claude-hud
```

Idempotent — safe to run when claude-hud isn't installed.

### Update

Just re-run the same curl command. `install.sh` overwrites `~/.claude/statusline-deepseek.sh` and re-patches `settings.json`, backing up the old one each time.

> ⚠️ **`--force` and stacked status lines.** If `settings.json` already has a
> `statusLine.command` that isn't this script, the installer **refuses** rather than
> overwrite it — because that command may be a wrapper that calls this script *and*
> does something else with the same input (feeding an external display, a status
> panel, a logger…). Replacing it silently kills whatever the outer layer did, with
> no error anywhere. If you really do want to point `statusLine` straight at this
> script, run `./install.sh --force`.
>
> To *keep* the wrapper, install with `--force` first (updates the script body only
> is not a thing — the installer always touches `statusLine`), then put the wrapper
> path back into `settings.json` by hand. The wrapper's contract is unchanged: it
> reads stdin and passes it through to `~/.claude/statusline-deepseek.sh`.

### Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/JayYuuuuu/claude-statusline-deepseek/main/uninstall.sh | bash
```

Restores the most recent `settings.json` backup, deletes `~/.claude/statusline-deepseek.sh`, and clears the per-session caches.

### What `install.sh` does

1. Verifies `bash`, `jq`, `curl`, `awk`, `stat` are installed.
2. Downloads `statusline.sh` (or copies it from a cloned repo) to `~/.claude/statusline-deepseek.sh`.
3. Backs up `~/.claude/settings.json` to `settings.json.bak-<timestamp>`.
4. Patches `statusLine.command` to point at the new script — unless it already points
   somewhere else, in which case it **aborts** and leaves `settings.json` alone
   (see the `--force` note above).
5. Runs a smoke test.

### Cloned-repo install (for hacking)

If you want to read or modify the source locally:

```bash
git clone https://github.com/JayYuuuuu/claude-statusline-deepseek.git
cd claude-statusline-deepseek
./install.sh                       # uses local statusline.sh
git pull && ./install.sh           # update later
./uninstall.sh                     # remove
```

## Pricing per model

Spend is shown in **CNY (元)** by default, because that is DeepSeek's *native* price:
the Chinese docs page lists only 元 — there is no official USD price and no published
FX rate, so converting from a USD table would just be a guess.

Prices are per 1M tokens, and **peak hours cost 2× idle**:

| Model | 缓存未命中（空闲 / 高峰） | 缓存命中（空闲 / 高峰） | 输出（空闲 / 高峰） |
|-------|--------------------------|------------------------|---------------------|
| `deepseek-v4-flash` (default; aliases: `deepseek-chat`, `deepseek-reasoner`) | ¥1 / ¥2 | ¥0.02 / ¥0.04 | ¥4 / ¥8 |
| `deepseek-v4-pro` | ¥4.5 / ¥9 | ¥0.15 / ¥0.30 | ¥13.5 / ¥27 |

**Peak** = 北京时间 周一~周五 `09:00-12:00` 与 `14:00-18:00`. Everything else —
including all weekend — is idle. Official policy also treats 法定节假日 as idle;
the script does not check the holiday calendar, so a handful of days a year get
priced at peak. That errs high, never low.

The cost block shows which model *and which rate* is in effect: `≈¥0.46 v4-flash·谷`
(`·谷` = 空闲, `·峰` = 高峰).

### Display currency

Set `DS_CURRENCY=USD` to use the English-page USD list prices instead (symbol flips
to `$`, and peak/idle collapses to a single rate since the USD page does not tier).
Note that the balance line (`💳 10.51 CNY`) always shows whatever currency the
DeepSeek account itself reports — that comes straight from `/user/balance`.

### Detection logic

When `ANTHROPIC_BASE_URL` points to DeepSeek, the script reads `ANTHROPIC_DEFAULT_OPUS_MODEL` / `ANTHROPIC_DEFAULT_SONNET_MODEL` / `ANTHROPIC_DEFAULT_HAIKU_MODEL` (the env vars cc-switch sets) and matches against the current `model.id` from stdin. If no mapping is set, falls back to `v4-flash` pricing.

### Manual override

Create `~/.claude/statusline-deepseek.env` to force specific prices
(values in the same unit as `DS_CURRENCY` — CNY by default):

```bash
DS_CURRENCY=CNY
DS_PRICE_INPUT_MISS=4.5
DS_PRICE_INPUT_HIT=0.15
DS_PRICE_OUTPUT=13.5
DS_MODEL_LABEL=v4-pro-custom
```

Sourced after auto-detection — your values always win.

Source for current prices: <https://api-docs.deepseek.com/zh-cn/quick_start/pricing>

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

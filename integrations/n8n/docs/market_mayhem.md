# Replicating Market Mayhem in n8n (episode mode)

**Goal:** run [`show/MarketMayhem`](../../../show/MarketMayhem/) — the day's real
crypto/market numbers, dramatized by a recurring cast of personified assets — on an
n8n instance, using the [`workflow.yakyak-engine.json`](../workflow.yakyak-engine.json)
engine in **`episode` mode**: one campaign, one new episode per day.

The importable front-end is [`workflow.marketmayhem-daily.json`](../workflow.marketmayhem-daily.json).
The architecture (two workflows, engine as sub-workflow, all config on the canvas, no
environment variables) is identical to the BBN replica — read
[`breaking_bricks_news.md`](./breaking_bricks_news.md) §2 and §5 once; this doc covers
only what Market Mayhem does differently.

---

## 1. Showrunner → n8n mapping

Market Mayhem is a **prompt / WebFetch** show like BBN: `prompt.md` drives `claude -p`
to fetch live data and write the story. The mapping is the BBN table with one row
changed — the *sources*:

| Showrunner step | n8n equivalent |
| --- | --- |
| Cron (`CADENCE=daily`) | **Every evening** Schedule trigger, `0 21 * * *` — the "daily close" read (crypto trades 24/7; pick any hour) |
| Token-balance guard | **Fetch user** + **Balance guard** (same as BBN) |
| `prompt.md` WebFetches Binance 24h tickers + Fear & Greed | **5 HTTP fetch nodes**: BTC / ETH / DOGE (Binance), Fear & Greed (alternative.me), and the **CoinGecko fallback** (§3) |
| Story → plot (`storyToDescription()`, `CAST_ALIASES`) | **Build story payload** — same parser as BBN, Max Mayhem cast map |
| Slot picking / generate / render | ✅ the engine, `mode: "episode"` |
| Soundtrack pin (`VOLUME="45"`) | `changes.movie.soundtrackAudioPath` / `soundtrackVolume` in **Build engine payload** |
| Social title + caption, announce | **Set social fields** + **Announce** (same as BBN) |

## 2. The front-end, node by node

```
Every evening (cron 0 21 * * *)
 └► Show config            Set — campaignId, userId, minTokenBalance, apiBase,
 │                          soundtrack pin, chatWebhookUrl (§4)
 └► Fetch user             HTTP — GET /users/{userId}, 'YakYak API' credential
 └► Balance guard          Code — abort below minTokenBalance (an episode is 8 scenes 💸)
 └► Fetch BTC / ETH / DOGE 3× HTTP — Binance 24h ticker, free no-key JSON,
 │                          continue-on-error (Binance geo-blocks some hosts, HTTP 451)
 └► Fetch Fear & Greed     HTTP — alternative.me index, the episode's emotional weather
 └► Fetch CoinGecko        HTTP — no-key fallback for all three prices (§3)
 └► Build prompt           Code — the adapted prompt.md with the numbers inlined;
 │                          aborts only if Binance AND CoinGecko both failed
 └► Write story (Claude)   HTTP — api.anthropic.com/v1/messages, claude-opus-4-8,
 │                          'Anthropic API key' Header Auth credential
 └► Build story payload    Code — storyToDescription() port; Max Mayhem / The Fed /
 │                          Bitcoin / Ethereum / Doge / Gold cast map
 └► Build engine payload   Code — mode: episode + plot + optional soundtrack pin
 └► Call engine            Execute Workflow — the yakyak-engine sub-workflow
 └► Set social fields      HTTP — title from the story call, caption from the headlines
 └► Announce               HTTP — 📈 + title + movie URL to chatWebhookUrl
```

## 3. The sourcing adaptation

The showrunner's `claude -p` fetches Binance itself and falls back to CoinGecko *when
it sees* an HTTP 451. An API call can't fetch, so the fallback moves onto the canvas:

- The three **Binance** nodes and the **CoinGecko** node all run continue-on-error,
  every run. **Build prompt** prefers the Binance ticker per coin (last price, 24h %,
  high/low) and falls back to CoinGecko's price + 24h change per coin — so a
  geo-blocked Binance (common on US servers) degrades gracefully instead of failing.
- The run aborts (before spending anything on the model or the render) only when **no
  coin has data from either source** — "never invent numbers" is enforced by code, not
  just by the prompt.
- Fear & Greed is optional either way: a failed fetch becomes an "unavailable this
  run" line, exactly like the showrunner prompt's instruction.

Everything else in [`prompt.md`](../../../show/MarketMayhem/prompt.md) — the cast, the
biggest-mover spotlight rule, 8 scenes, the no-financial-advice rule, no trailing
period on dialog — carries over verbatim, with the same two BBN-style edits: source
material is inlined below the prompt, and the file-write becomes "reply with only the
markdown" plus a `## Social title:` line (one model call covers story *and* title).

## 4. Assembly & configuration

Prerequisites as for BBN ([`breaking_bricks_news.md`](./breaking_bricks_news.md) §5):
the engine imported with its two credentials, plus the `Anthropic API key` Header Auth
credential. Then import
[`workflow.marketmayhem-daily.json`](../workflow.marketmayhem-daily.json), point **Call
engine** at the engine workflow, fill **Show config**, and **Publish**:

| Field | Required | Value |
| --- | --- | --- |
| `campaignId` | ✅ | The Market Mayhem campaign id — `show.env` `CAMPAIGN_ID` (`42ebdc7c-3d88-496b-9bce-bf6e4e888256` for the cookbook campaign). Must be owned by the `YakYak API` credential's account (fork it first if not — see [`../../../docs/forking.md`](../../../docs/forking.md)). |
| `userId` | ✅ | The YakYak user id the credential's PAT belongs to. |
| `minTokenBalance` | — | Default `2000` (`show.env` `MIN_TOKEN_BALANCE`). |
| `apiBase` | — | Default `https://api.yakyak.ai`; set beta here for test runs. |
| `soundtrackAudioPath` | — | The show's track content address — `show.env` `SOUNDTRACK_AUDIO_PATH`. Empty = skip the pin. |
| `soundtrackVolume` | — | `45` (`show.env` `VOLUME`). |
| `chatWebhookUrl` | — | Slack/Discord/Teams incoming webhook. Empty = no announcement. |

## 5. Ops notes

- **Cost per episode:** 8 scenes rendered per day (💸) — the Balance guard is what
  keeps a drained account from producing half an episode.
- **Binance 451s** are expected on US-hosted n8n instances; watch the first few runs'
  Build prompt output to confirm which source each coin actually used.
- **Weekends read flat** for the macro voices (The Fed, Gold): crypto still moves, but
  if the episodes feel samey, narrow the cron to weekdays (`0 21 * * 1-5`).
- Re-runs, season rollover, stalls, beta-first testing: identical to BBN — see
  [`breaking_bricks_news.md`](./breaking_bricks_news.md) §6.

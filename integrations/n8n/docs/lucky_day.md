# Replicating Lucky Day in n8n (episode mode)

**Goal:** run [`show/LuckyDay`](../../../show/LuckyDay/) — the daily Chinese
feng-shui almanac, the cookbook's first **non-English** show (Mandarin dialog,
brush-calligraphy subtitles), with a story **fully computed** from the date — on an
n8n instance, using the [`workflow.yakyak-engine.json`](../workflow.yakyak-engine.json)
engine in **`episode` mode**.

The importable front-end is [`workflow.luckyday-daily.json`](../workflow.luckyday-daily.json).
The shared architecture is documented once in
[`breaking_bricks_news.md`](./breaking_bricks_news.md) (§2, §5), and the Computed
archetype's n8n shape in [`horoscopes.md`](./horoscopes.md) — Lucky Day is the same
ten-node pipeline on a daily cron; this doc covers the localization specifics.

---

## 1. Showrunner → n8n mapping

| Showrunner step | n8n equivalent |
| --- | --- |
| Cron (`CADENCE=daily`) | **Every morning** Schedule trigger, `0 6 * * *` |
| Token-balance guard | **Fetch user** + **Balance guard** (same as BBN) |
| `compute.py` — deterministic 14-scene almanac from the date | **Compute story** Code node — a JS port of compute.py (§3). No model, no network, **no Anthropic credential** |
| Story → plot (`CAST_ALIASES`: Master + 12 animals) | **Build story payload** — same parser, 13 identity aliases; also strips a trailing full-width `。` defensively |
| Social title / caption | computed: `今日运势 Lucky Day — <date>`; caption = the almanac headline bullet compute.py already crafts for socials |
| Everything from slot picking onward | ✅ the engine + the standard finalization nodes |

## 2. The front-end, node by node

```
Every morning (cron 0 6 * * *)
 └► Show config            Set — campaignId, userId, minTokenBalance, apiBase,
 │                          soundtrack pin, chatWebhookUrl (§4)
 └► Fetch user             HTTP — GET /users/{userId}, 'YakYak API' credential
 └► Balance guard          Code — abort below minTokenBalance (14 scenes 💸 DAILY — §5)
 └► Compute story          Code — the whole story stage, deterministic and offline
 └► Build story payload    Code — storyToDescription() port; Master + 12 animal aliases
 └► Build engine payload   Code — mode: episode + plot + optional soundtrack pin
 └► Call engine            Execute Workflow — the yakyak-engine sub-workflow
 └► Set social fields      HTTP — computed title + caption
 └► Announce               HTTP — 🧧 + title + movie URL to chatWebhookUrl
```

## 3. The compute port — what localization means here

**Compute story** ports [`compute.py`](../../../show/LuckyDay/compute.py) with its
split-language contract intact:

- **Dialog lines are Simplified Chinese** (the campaign voices them with the native
  Mandarin voice and renders them as gold Ma Shan Zheng brush-calligraphy couplets);
  **prose stays English**, because it feeds the image-generation prompts. Keep that
  split if you edit the node.
- **The almanac math matches the showrunner exactly**: the day's stem/branch/element
  (干支/五行), the ruling animal and its 冲 clash animal all derive from the same
  proleptic-Gregorian ordinal as the Python code — same date, same 干支 day in both
  implementations. Only the word-bank *picks* (宜/忌 lines, directions, settings,
  blessings) use a different hash (FNV-1a instead of sha256), so their wording
  differs from a showrunner run while staying fully deterministic per date.
- **Same almanac caveat as the original:** the 10/12/60 cycles are structurally
  correct but the absolute phase is *not* anchored to a verified 通書 (Tong Shu)
  epoch — it's a stylized daily-luck show, self-consistent and reproducible, not a
  true almanac.
- House rules carry over: no trailing period on spoken lines (full-width `，、；`
  inside are fine), and each dialog stays short enough to fit one subtitle screen,
  since Chinese renders as one unbroken calligraphic line.

## 4. Assembly & configuration

Import the engine with its credentials
([`yakyak_engine.md`](./yakyak_engine.md) §5) — **no Anthropic credential needed**.
Import [`workflow.luckyday-daily.json`](../workflow.luckyday-daily.json), point
**Call engine** at the engine, fill **Show config**, **Publish**:

| Field | Required | Value |
| --- | --- | --- |
| `campaignId` | ✅ | `show.env` `CAMPAIGN_ID` (`ab996804-a523-4cae-a551-e14aa6e4b14f` for the cookbook campaign — Feng Shui Master + 12 animals, Mandarin voice, ink-wash style); must be owned by the credential's account — fork it first if not ([`../../../docs/forking.md`](../../../docs/forking.md)). |
| `userId` | ✅ | The YakYak user id the PAT belongs to. |
| `minTokenBalance` | — | Default `2000`. |
| `apiBase` | — | Default `https://api.yakyak.ai`; beta for test runs. |
| `soundtrackAudioPath` | — | `show.env` `SOUNDTRACK_AUDIO_PATH` (guzheng/erhu track). Empty = skip. |
| `soundtrackVolume` | — | `30` (`show.env` `VOLUME`). |
| `chatWebhookUrl` | — | Incoming webhook for the announcement. Empty = none. |

## 5. Ops notes

- **This is the most expensive cadence in the gallery**: 14 scenes *every day*. The
  `show.env` comment applies verbatim here — if the token cost is too high, either
  slow the cron (weekly: `0 6 * * 0`) or trim the animal loop in **Compute story**
  (e.g. only the ruling + clash animals plus the Master, for a 4-scene daily).
- **Re-running the same date regenerates the same story** — with the engine's
  diff-aware apply, a duplicate run is close to a no-op.
- **Check the subtitles on the first render**: if you fork the campaign rather than
  use the cookbook one, confirm the Ma Shan Zheng font and the Mandarin voice
  survived the fork before letting the cron run.
- Re-runs, season rollover, stalls, beta-first testing: identical to BBN — see
  [`breaking_bricks_news.md`](./breaking_bricks_news.md) §6.

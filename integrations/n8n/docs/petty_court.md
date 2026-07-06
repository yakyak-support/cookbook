# Replicating Petty Court in n8n (episode mode)

**Goal:** run [`show/PettyCourt`](../../../show/PettyCourt/) — the day's top Reddit
drama thread, *paraphrased* and staged as a small-claims courtroom sitcom — on an n8n
instance, using the [`workflow.yakyak-engine.json`](../workflow.yakyak-engine.json)
engine in **`episode` mode**.

The importable front-end is [`workflow.pettycourt-daily.json`](../workflow.pettycourt-daily.json).
The shared architecture is documented once in
[`breaking_bricks_news.md`](./breaking_bricks_news.md) (§2, §5); this doc covers what
Petty Court does differently — chiefly the Reddit fallback ladder and the SFW screen.

---

## 1. Showrunner → n8n mapping

Petty Court is a **prompt / WebFetch** show: `prompt.md` drives `claude -p` to fetch
Reddit's public JSON and write the story. Deltas from the BBN table:

| Showrunner step | n8n equivalent |
| --- | --- |
| Cron (`CADENCE=daily`) | **Every morning** Schedule trigger, `0 6 * * *` — `top.json?t=day` catches yesterday's winners |
| `prompt.md` WebFetches 4 drama subreddits, retries old.reddit, falls back to pullpush | **6 HTTP fetch nodes** — the same ladder, on the canvas (§3) |
| Claude screens for SFW + picks the highest-upvote case | **split**: the mechanical screen (over_18, body length, score sort) runs in **Build prompt**; Claude picks from the top 8 candidates (§3) |
| Story → plot (`CAST_ALIASES` = six full-name identity aliases) | **Build story payload** — full names map to themselves, so "Judge Justine Payne" stays intact instead of collapsing to "Judge" |
| Everything from slot picking onward | ✅ the engine + the standard finalization nodes, as BBN |

## 2. The front-end, node by node

```
Every morning (cron 0 6 * * *)
 └► Show config              Set — campaignId, userId, minTokenBalance, apiBase,
 │                            soundtrack pin, chatWebhookUrl (§4)
 └► Fetch user               HTTP — GET /users/{userId}, 'YakYak API' credential
 └► Balance guard            Code — abort below minTokenBalance (8 scenes 💸)
 └► Fetch r/AmItheAsshole    4× HTTP — www.reddit.com top.json?t=day&limit=15,
 │  / r/AITAH / r/pettyrevenge / r/EntitledPeople    continue-on-error
 └► Fetch old.reddit fallback  HTTP — the more lenient host, same listing
 └► Fetch pullpush fallback  HTTP — free no-key Reddit archive mirror
 └► Build prompt             Code — pools all listings, SFW screen, score sort,
 │                            top 8 candidates inlined; aborts if ALL sources failed
 └► Write story (Claude)     HTTP — claude-opus-4-8, 'Anthropic API key' credential
 └► Build story payload      Code — storyToDescription() port, six identity aliases
 └► Build engine payload     Code — mode: episode + plot + optional soundtrack pin
 └► Call engine              Execute Workflow — the yakyak-engine sub-workflow
 └► Set social fields        HTTP — title from the story call, caption from headlines
 └► Announce                 HTTP — ⚖️ + title + movie URL to chatWebhookUrl
```

## 3. The sourcing adaptation

The showrunner's prompt walks a fetch ladder itself ("try these in order, use the
first that returns usable posts"). On n8n the whole ladder fetches up-front,
continue-on-error, and **Build prompt** merges the results:

- **All four `www.reddit.com` listings + the `old.reddit.com` retry** are pooled and
  de-duplicated — more variety than the showrunner's first-hit-wins, same sources.
  Each node sends a descriptive **User-Agent** header; Reddit blanket-429s default
  HTTP clients, and this is the documented fix.
- **pullpush.io** (the archive mirror, different JSON shape: `data[]` instead of
  `data.children[].data`) is only consulted when every live listing came back empty.
- **The SFW/quality screen is code, not vibes:** `over_18` posts are dropped, bodies
  under 200 chars are dropped (nothing to paraphrase), the rest sort by upvotes — the
  virality pre-screen — and the top 8 go to Claude, which picks the best two-party
  conflict and **paraphrases** it. The transform-don't-copy rule, the archetype cast,
  the verdict-from-flair beat and the 8-scene structure carry over verbatim from
  [`prompt.md`](../../../show/PettyCourt/prompt.md).
- The run aborts before any spend if **all seven sources** produced nothing usable —
  "never invent a Reddit story" is enforced by code.

## 4. Assembly & configuration

Prerequisites as for BBN ([`breaking_bricks_news.md`](./breaking_bricks_news.md) §5):
engine + two credentials + `Anthropic API key`. Import
[`workflow.pettycourt-daily.json`](../workflow.pettycourt-daily.json), point **Call
engine** at the engine, fill **Show config**, **Publish**:

| Field | Required | Value |
| --- | --- | --- |
| `campaignId` | ✅ | `show.env` `CAMPAIGN_ID` (`e98010e1-6fc0-4c1c-b0a0-770fc60e3339` for the cookbook campaign); must be owned by the credential's account — fork it first if not ([`../../../docs/forking.md`](../../../docs/forking.md)). |
| `userId` | ✅ | The YakYak user id the PAT belongs to. |
| `minTokenBalance` | — | Default `2000`. |
| `apiBase` | — | Default `https://api.yakyak.ai`; beta for test runs. |
| `soundtrackAudioPath` | — | `show.env` `SOUNDTRACK_AUDIO_PATH` (the courtroom-sitcom theme). Empty = skip. |
| `soundtrackVolume` | — | `45` (`show.env` `VOLUME`). |
| `chatWebhookUrl` | — | Incoming webhook for the announcement. Empty = none. |

## 5. Ops notes

- **Reddit rate limits move around.** If the four live listings 429 consistently from
  your host, the old.reddit and pullpush fallbacks keep the show alive; check Build
  prompt's `candidates` output field to see how deep the ladder went.
- **The paraphrase rule is the legal/SFW backstop** — it lives in the prompt, and the
  code-side screen (over_18, no invented stories) backs it up. Don't remove either.
- **Cost per episode:** 8 scenes daily (💸); the source is effectively infinite, so
  the only reason to slow the cron is spend.
- Re-runs, season rollover, stalls, beta-first testing: identical to BBN — see
  [`breaking_bricks_news.md`](./breaking_bricks_news.md) §6.

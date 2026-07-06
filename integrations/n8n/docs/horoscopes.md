# Replicating Cosmic Brief (Horoscopes) in n8n (episode mode)

**Goal:** run [`show/Horoscopes`](../../../show/Horoscopes/) — "Cosmic Brief", the
weekly horoscope show whose story is **fully computed** from the ISO week (no model,
no API key, offline and reproducible) — on an n8n instance, using the
[`workflow.yakyak-engine.json`](../workflow.yakyak-engine.json) engine in **`episode`
mode**, one episode per week.

The importable front-end is [`workflow.horoscopes-weekly.json`](../workflow.horoscopes-weekly.json).
The shared architecture is documented once in
[`breaking_bricks_news.md`](./breaking_bricks_news.md) (§2, §5); this doc covers what
the **Computed** archetype changes — mostly what *disappears*.

---

## 1. Showrunner → n8n mapping

Cosmic Brief exists to prove the engine is show-agnostic: the entire story stage is a
deterministic function of the week. In n8n that collapses BBN's three fetch nodes +
Claude call into **one Code node**:

| Showrunner step | n8n equivalent |
| --- | --- |
| Cron (`CADENCE=weekly`, Sundays) | **Every Sunday** Schedule trigger, `0 6 * * 0` |
| Token-balance guard | **Fetch user** + **Balance guard** (same as BBN) |
| `compute.py` — deterministic 14-scene story from the ISO week | **Compute story** Code node — a JS port of compute.py (§3). No model, no network, **no Anthropic credential** |
| Story → plot (`CAST_ALIASES`: Guru + 12 signs) | **Build story payload** — same parser as BBN, 13 identity aliases |
| Social title (BBN used a model call) | computed: `Cosmic Brief — Week <W>, <Y>`; caption from the Guru's outlook + sign bullets |
| Everything from slot picking onward | ✅ the engine + the standard finalization nodes |

## 2. The front-end, node by node

```
Every Sunday (cron 0 6 * * 0)
 └► Show config            Set — campaignId, userId, minTokenBalance, apiBase,
 │                          soundtrack pin, chatWebhookUrl (§4)
 └► Fetch user             HTTP — GET /users/{userId}, 'YakYak API' credential
 └► Balance guard          Code — abort below minTokenBalance (14 scenes 💸)
 └► Compute story          Code — the whole story stage, deterministic and offline
 └► Build story payload    Code — storyToDescription() port; Guru + 12 sign aliases
 └► Build engine payload   Code — mode: episode + plot + optional soundtrack pin
 └► Call engine            Execute Workflow — the yakyak-engine sub-workflow
 └► Set social fields      HTTP — computed title + caption
 └► Announce               HTTP — ✨ + title + movie URL to chatWebhookUrl
```

Ten nodes, two credentials on the instance but only **one** used here (`YakYak API`) —
this is the cheapest front-end to stand up and the right one to prove the engine
import with.

## 3. The compute port

**Compute story** is a line-for-line port of
[`compute.py`](../../../show/Horoscopes/compute.py): same 14-scene shape (Guru opens,
12 signs, Guru closes), same word banks, and the same house rules —

- every sign's spoken line starts `"This Week's Advice for <Sign>;"` (with the same
  rotating openers),
- advice is dealt **without replacement**, so no two signs share advice in a week,
- no trailing period on any spoken line.

One deliberate difference: Python's `hashlib.sha256` pick-hash becomes FNV-1a +
mulberry32 in JS, so for the same ISO week the *word choices* differ from a
showrunner run — but the output is equally deterministic: **same week in → same story
out**, re-runs included. (The two implementations never share a campaign week in
practice; if you need bit-identical parity, port the sha256 hash into the Code node.)

## 4. Assembly & configuration

Import the engine with its credentials
([`yakyak_engine.md`](./yakyak_engine.md) §5) — **skip the Anthropic credential**,
this show doesn't use it. Import
[`workflow.horoscopes-weekly.json`](../workflow.horoscopes-weekly.json), point **Call
engine** at the engine, fill **Show config**, **Publish**:

| Field | Required | Value |
| --- | --- | --- |
| `campaignId` | ✅ | `show.env` `CAMPAIGN_ID` (`96491ebf-585b-4451-befa-73bdbd47cfb9` for the cookbook campaign — 13 pre-rendered portraits: The Cosmic Guru + 12 signs); must be owned by the credential's account — fork it first if not ([`../../../docs/forking.md`](../../../docs/forking.md)). |
| `userId` | ✅ | The YakYak user id the PAT belongs to. |
| `minTokenBalance` | — | Default `2000`. |
| `apiBase` | — | Default `https://api.yakyak.ai`; beta for test runs. |
| `soundtrackAudioPath` | — | `show.env` `SOUNDTRACK_AUDIO_PATH` (the celestial ambient track). Empty = skip. |
| `soundtrackVolume` | — | `30` (`show.env` `VOLUME`). |
| `chatWebhookUrl` | — | Incoming webhook for the announcement. Empty = none. |

## 5. Ops notes

- **14 scenes per episode** is the biggest render in the gallery next to Lucky Day —
  the weekly cadence is what keeps the spend predictable. The Balance guard fires
  *before* any scene is generated.
- **Re-running inside the same ISO week regenerates the same story** — combined with
  the engine's diff-aware apply, a duplicate Sunday run is close to a no-op.
- **This is the recommended first show** to bring up on a fresh n8n instance: no
  model credential, deterministic story, and any failure is by definition in the
  engine wiring, not the sourcing.
- Re-runs, season rollover, stalls, beta-first testing: identical to BBN — see
  [`breaking_bricks_news.md`](./breaking_bricks_news.md) §6.

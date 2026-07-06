# Replicating Sun Tzu, Today in n8n (episode mode)

**Goal:** run [`show/SunTzuToday`](../../../show/SunTzuToday/) — one *verbatim* Art of
War maxim per episode, staged as a modern micro-drama — on an n8n instance, using the
[`workflow.yakyak-engine.json`](../workflow.yakyak-engine.json) engine in **`episode`
mode**, three episodes a week.

The importable front-end is [`workflow.suntzu-mwf.json`](../workflow.suntzu-mwf.json).
The shared architecture is documented once in
[`breaking_bricks_news.md`](./breaking_bricks_news.md) (§2, §5); this doc covers what
the **Extracted** archetype needs that BBN didn't: a corpus and a **cursor**.

---

## 1. Showrunner → n8n mapping

Sun Tzu is the cookbook's first **Extracted** show: `compute.js` walks a public-domain
corpus one maxim per episode, then calls `claude -p` to dramatize. Deltas from BBN:

| Showrunner step | n8n equivalent |
| --- | --- |
| Cron (`CADENCE=mwf`) | **Mon Wed Fri** Schedule trigger, `0 6 * * 1,3,5` |
| `compute.js` reads `corpus/art_of_war.md` from the checkout | **Fetch corpus** HTTP node — the same file from the cookbook repo's raw GitHub URL (configurable `corpusUrl`) |
| Cursor = number of files in `stories/` (committed back each run) | **workflow static data** — read in **Pick maxim**, advanced in **Advance cursor** *after* the render succeeds (§3) |
| `claude -p` dramatizes the maxim | **Build prompt** + **Write story (Claude)** — the compute.js prompt with the file-write turned into "reply with only the markdown" + a `## Social title:` line |
| Story → plot (`CAST_ALIASES`: Strategist/Student/Rival) | **Build story payload** — same parser, three identity aliases |
| Everything from slot picking onward | ✅ the engine + the standard finalization nodes |

## 2. The front-end, node by node

```
Mon Wed Fri (cron 0 6 * * 1,3,5)
 └► Show config            Set — campaignId, userId, minTokenBalance, apiBase,
 │                          corpusUrl, soundtrack pin, chatWebhookUrl (§4)
 └► Fetch user             HTTP — GET /users/{userId}, 'YakYak API' credential
 └► Balance guard          Code — abort below minTokenBalance (7 scenes 💸)
 └► Fetch corpus           HTTP — GET corpusUrl (text). No corpus = no episode: fails hard
 └► Pick maxim             Code — cursor % 370 maxims; loops when exhausted, like compute.js
 └► Build prompt           Code — verbatim-maxim rule, 7-scene structure, chiaroscuro look
 └► Write story (Claude)   HTTP — claude-opus-4-8, 'Anthropic API key' credential
 └► Build story payload    Code — storyToDescription() port; Strategist/Student/Rival
 └► Build engine payload   Code — mode: episode + plot + optional soundtrack pin
 └► Call engine            Execute Workflow — the yakyak-engine sub-workflow
 └► Advance cursor         Code — cursor+1 into static data, ONLY after a rendered episode
 └► Set social fields      HTTP — title from the story call, caption = the maxim itself
 └► Announce               HTTP — ⚔️ + title + movie URL to chatWebhookUrl
```

## 3. The cursor (the one piece of real state)

The showrunner's cursor is elegant: *the number of story files already committed* —
success advances it, failure doesn't, no state file needed. n8n has no repo to commit
to, so the replica uses the platform's equivalent, **workflow static data**:

- **Pick maxim** reads `sunTzuCursor` (default 0 → Maxim 1) and picks
  `cursor % total`; when the 370-maxim corpus is exhausted it loops, exactly like
  `compute.js`.
- **Advance cursor** writes `cursor + 1` — and it sits **after Call engine**, so a run
  that dies anywhere (story, generation, render) leaves the cursor untouched and the
  next run re-runs the *same* maxim. That's the same failure semantics as the
  showrunner.
- **Two caveats to know about:** n8n only persists static data on **active**
  (scheduled) executions — a manual *Test workflow* run picks the right maxim but
  won't advance the cursor — and re-importing the workflow JSON resets it. To
  fast-forward or rewind, edit `sunTzuCursor` with a one-off Code node, or just accept
  a repeat: episodes are self-contained.

The corpus itself is fetched per run from the repo's raw GitHub URL (default in Show
config), so a stock n8n container needs no files. Point `corpusUrl` at your fork to
curate the maxim list.

## 4. Assembly & configuration

Prerequisites as for BBN ([`breaking_bricks_news.md`](./breaking_bricks_news.md) §5):
engine + two credentials + `Anthropic API key`. Import
[`workflow.suntzu-mwf.json`](../workflow.suntzu-mwf.json), point **Call engine** at
the engine, fill **Show config**, **Publish**:

| Field | Required | Value |
| --- | --- | --- |
| `campaignId` | ✅ | `show.env` `CAMPAIGN_ID` (`4ce7705d-a183-4e7d-b325-d686b65e1baa` for the cookbook campaign); must be owned by the credential's account — fork it first if not ([`../../../docs/forking.md`](../../../docs/forking.md)). |
| `userId` | ✅ | The YakYak user id the PAT belongs to. |
| `minTokenBalance` | — | Default `2000`. |
| `apiBase` | — | Default `https://api.yakyak.ai`; beta for test runs. |
| `corpusUrl` | — | Defaults to the cookbook's `corpus/art_of_war.md` on GitHub (Lionel Giles 1910, Project Gutenberg #132, public domain). |
| `soundtrackAudioPath` | — | `show.env` `SOUNDTRACK_AUDIO_PATH` (the taiko theme). Empty = skip. |
| `soundtrackVolume` | — | `35` (`show.env` `VOLUME`). |
| `chatWebhookUrl` | — | Incoming webhook for the announcement. Empty = none. |

## 5. Ops notes

- **The maxim must appear verbatim** in scenes 1 and 7 — that's the format's contract
  and the prompt enforces it; the committed
  [`stories/`](../../../show/SunTzuToday/stories/) are the acceptance reference.
- **Cursor drift vs the showrunner:** if you run both the CI showrunner and this
  workflow against the same campaign, they keep *separate* cursors and will collide on
  maxims. Run one or the other per campaign.
- **Cost per episode:** 7 scenes, three times a week (💸).
- Re-runs, season rollover, stalls, beta-first testing: identical to BBN — see
  [`breaking_bricks_news.md`](./breaking_bricks_news.md) §6.

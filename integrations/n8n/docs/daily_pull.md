# Replicating Daily Pull in n8n (episode mode)

**Goal:** run [`show/DailyPull`](../../../show/DailyPull/) — a daily three-card tarot
reading (Past / Present / Future from the 22 Major Arcana), drawn by a **date-seeded
RNG** and dramatized by a model — on an n8n instance, using the
[`workflow.yakyak-engine.json`](../workflow.yakyak-engine.json) engine in **`episode`
mode**.

The importable front-end is [`workflow.dailypull-daily.json`](../workflow.dailypull-daily.json).
The shared architecture is documented once in
[`breaking_bricks_news.md`](./breaking_bricks_news.md) (§2, §5); this doc covers the
**Randomized (seeded)** archetype: the reproducible draw and the no-repeat window.

---

## 1. Showrunner → n8n mapping

| Showrunner step | n8n equivalent |
| --- | --- |
| Cron (`CADENCE=daily`) | **Every morning** Schedule trigger, `0 6 * * *` |
| `compute.js` reads `corpus/major_arcana.md` from the checkout | **Fetch corpus** HTTP node — the same file from the repo's raw GitHub URL (configurable `corpusUrl`) |
| Date-seeded draw (FNV-1a → mulberry32 → Fisher–Yates) | **Draw cards** Code node — the **same algorithm and seed string** (`daily-pull:YYYY-MM-DD`), so a given date + window reproduces the showrunner's draw |
| No-repeat window: cards from the last 7 stories' audit markers | **workflow static data**, recorded in **Record draw** *after* the render succeeds (§3) |
| `claude -p` dramatizes the spread | **Build prompt** + **Write story (Claude)** — the compute.js prompt, file-write → "reply with only the markdown" + a `## Social title:` line |
| `CAST_ALIASES`: The Reader + all 22 card names | **Build story payload** — same 23 identity aliases |
| Everything from slot picking onward | ✅ the engine + the standard finalization nodes |

## 2. The front-end, node by node

```
Every morning (cron 0 6 * * *)
 └► Show config            Set — campaignId, userId, minTokenBalance, apiBase,
 │                          corpusUrl, soundtrack pin, chatWebhookUrl (§4)
 └► Fetch user             HTTP — GET /users/{userId}, 'YakYak API' credential
 └► Balance guard          Code — abort below minTokenBalance (5 scenes 💸)
 └► Fetch corpus           HTTP — GET corpusUrl (text). No corpus = no episode: fails hard
 └► Draw cards             Code — seeded draw + orientation; seed, exclusions and the
 │                          draw are all on this node's output (the audit marker)
 └► Build prompt           Code — the exact cards/orientations pinned; 5-scene structure
 └► Write story (Claude)   HTTP — claude-opus-4-8, 'Anthropic API key' credential
 └► Build story payload    Code — storyToDescription() port; Reader + 22 Arcana aliases
 └► Build engine payload   Code — mode: episode + plot + optional soundtrack pin
 └► Call engine            Execute Workflow — the yakyak-engine sub-workflow
 └► Record draw            Code — append today's cards to the no-repeat window,
 │                          ONLY after a rendered episode
 └► Set social fields      HTTP — title from the story call, caption = the draw line
 └► Announce               HTTP — 🔮 + title + movie URL to chatWebhookUrl
```

## 3. The draw: reproducible randomness, minimal state

The showrunner's contract for the Randomized archetype carries over intact:

- **Seed = the UTC date.** The port uses the same FNV-1a hash, the same mulberry32
  stream and the same `daily-pull:YYYY-MM-DD` seed string as
  [`compute.js`](../../../show/DailyPull/compute.js), consumed in the same order
  (shuffle, then orientations) — so for the same date and the same exclusion window,
  n8n and the showrunner draw the **same three cards with the same orientations**.
  Same day in → same draw out; re-running a failed day redraws identically.
- **No repeats within a week.** The showrunner re-reads the `<!-- pull: … -->` audit
  markers of the last 7 committed stories; the replica keeps the same record
  (`{date, cards}`, last 7 entries) in **workflow static data**. **Record draw** sits
  after **Call engine**, so only *rendered* episodes extend the window — and a
  same-date re-run replaces the day's entry rather than excluding its own cards. If
  the exclusions would leave fewer than 3 cards, the pool relaxes to the full deck,
  exactly like the original.
- **Static-data caveats** (same as Sun Tzu's cursor): manual *Test workflow* runs
  draw correctly but don't extend the window, and re-importing the workflow resets
  it — worst case is a repeated card inside a week, not a broken run.
- One divergence from `compute.js`, on purpose: the original clobbers the card's
  *reversed meaning* string with the orientation boolean (so a reversed card's brief
  prints `true` instead of its meaning). The port keeps `reversedMeaning` and
  `isReversed` separate, so Claude actually sees the reversed meaning text.

## 4. Assembly & configuration

Prerequisites as for BBN ([`breaking_bricks_news.md`](./breaking_bricks_news.md) §5):
engine + two credentials + `Anthropic API key`. Import
[`workflow.dailypull-daily.json`](../workflow.dailypull-daily.json), point **Call
engine** at the engine, fill **Show config**, **Publish**:

| Field | Required | Value |
| --- | --- | --- |
| `campaignId` | ✅ | `show.env` `CAMPAIGN_ID` (`de4faab5-c447-4357-afe9-fce57a5795e7` for the cookbook campaign — 23 pre-rendered cast portraits: The Reader + 22 Major Arcana); must be owned by the credential's account — fork it first if not ([`../../../docs/forking.md`](../../../docs/forking.md)). |
| `userId` | ✅ | The YakYak user id the PAT belongs to. |
| `minTokenBalance` | — | Default `2000`. |
| `apiBase` | — | Default `https://api.yakyak.ai`; beta for test runs. |
| `corpusUrl` | — | Defaults to the cookbook's `corpus/major_arcana.md` on GitHub. |
| `soundtrackAudioPath` | — | `show.env` `SOUNDTRACK_AUDIO_PATH` (the mystical ambient track). Empty = skip. |
| `soundtrackVolume` | — | `30` (`show.env` `VOLUME`). |
| `chatWebhookUrl` | — | Incoming webhook for the announcement. Empty = none. |

## 5. Ops notes

- **The drawn cards must lead their scenes** — the campaign has
  `allowNewCharacters=false` and every card has a stable pre-rendered portrait, which
  is why the alias map lists all 22 names and why the prompt pins the cast to the
  day's exact draw.
- **Shadow cards are transformation, not doom** — the tone rule rides in the prompt;
  the committed [`stories/`](../../../show/DailyPull/stories/) are the acceptance
  reference.
- **Cost per episode:** 5 scenes daily — the cheapest model-driven show in the
  gallery.
- Re-runs, season rollover, stalls, beta-first testing: identical to BBN — see
  [`breaking_bricks_news.md`](./breaking_bricks_news.md) §6.

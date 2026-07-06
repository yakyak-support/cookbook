# Replicating On This Day in n8n (episode mode)

**Goal:** run [`show/OnThisDay`](../../../show/OnThisDay/) — one real historical
anniversary a day, staged as a dramatized reenactment hosted by The Chronicler — on an
n8n instance, using the [`workflow.yakyak-engine.json`](../workflow.yakyak-engine.json)
engine in **`episode` mode**.

The importable front-end is [`workflow.onthisday-daily.json`](../workflow.onthisday-daily.json).
The shared architecture is documented once in
[`breaking_bricks_news.md`](./breaking_bricks_news.md) (§2, §5); this doc covers the
**Computed (date) + Extracted (corpus)** sourcing and the show's *deliberate* role as
the cookbook's content-moderation failure example.

---

## 1. Showrunner → n8n mapping

| Showrunner step | n8n equivalent |
| --- | --- |
| Cron (`CADENCE=daily`) | **Every morning** Schedule trigger, `0 6 * * *` |
| `compute.js` reads `corpus/on_this_day.md` from the checkout | **Fetch corpus** HTTP node — the same file from the cookbook repo's raw GitHub URL (configurable `corpusUrl`) |
| Date → entry selection; walk forward if today's MM-DD is empty | **Pick anniversary** Code node — the same algorithm, ported (§3) |
| Same-date entries rotate by story-file count | rotate by **year** — stateless, same effect (successive years differ) (§3) |
| `claude -p` dramatizes the factual account | **Build prompt** + **Write story (Claude)** — the compute.js prompt, file-write → "reply with only the markdown" + a `## Social title:` line |
| `CAST_ALIASES="The Chronicler=The Chronicler"` only | **Build story payload** — only the host is aliased; the day's historical figures are episodic (`allowNewCharacters=true` on this campaign) and keep their names |
| Everything from slot picking onward | ✅ the engine + the standard finalization nodes |

## 2. The front-end, node by node

```
Every morning (cron 0 6 * * *)
 └► Show config            Set — campaignId, userId, minTokenBalance, apiBase,
 │                          corpusUrl, soundtrack pin, chatWebhookUrl (§4)
 └► Fetch user             HTTP — GET /users/{userId}, 'YakYak API' credential
 └► Balance guard          Code — abort below minTokenBalance (7 scenes 💸)
 └► Fetch corpus           HTTP — GET corpusUrl (text). No corpus = no episode: fails hard
 └► Pick anniversary       Code — today's MM-DD → corpus entry; walks forward day by
 │                          day (wrapping at year end) if today has no entry yet
 └► Build prompt           Code — factual account as source of truth, 7 scenes,
 │                          archival-to-color look, The Chronicler opens and closes
 └► Write story (Claude)   HTTP — claude-opus-4-8, 'Anthropic API key' credential
 └► Build story payload    Code — storyToDescription() port; only The Chronicler aliased
 └► Build engine payload   Code — mode: episode + plot + optional soundtrack pin
 └► Call engine            Execute Workflow — the yakyak-engine sub-workflow
 └► Set social fields      HTTP — title from the story call, caption = the anniversary
 └► Announce               HTTP — 📜 + title + movie URL to chatWebhookUrl
```

## 3. The date → corpus selection

**Pick anniversary** is a direct port of the selection in
[`compute.js`](../../../show/OnThisDay/compute.js):

- Today's UTC **MM-DD** is the primary key into the corpus entries
  (`## 06-09 — 0068 — The Emperor Nero dies…`).
- If today has **no entry**, walk forward one day at a time (Dec 31 wraps to Jan 1;
  a fixed leap year keeps 02-29 reachable) to the next date that does — the daily
  render never fails for want of an entry, and coverage becomes exact as the corpus
  fills in over time. The `walked` count is visible on the node's output.
- **Same-date rotation:** where the showrunner rotates multiple entries for one date
  by story-file count, the replica rotates by **calendar year** — stateless, and the
  same calendar date still gets a different entry in successive years.

The corpus is public-domain and fetched per run from the repo's raw GitHub URL; point
`corpusUrl` at your fork to add dates.

## 4. Assembly & configuration

Prerequisites as for BBN ([`breaking_bricks_news.md`](./breaking_bricks_news.md) §5):
engine + two credentials + `Anthropic API key`. Import
[`workflow.onthisday-daily.json`](../workflow.onthisday-daily.json), point **Call
engine** at the engine, fill **Show config**, **Publish**:

| Field | Required | Value |
| --- | --- | --- |
| `campaignId` | ✅ | `show.env` `CAMPAIGN_ID` (`209b2a8e-0ddd-4658-aa5d-e8ff8b0f09a6` for the cookbook campaign, a **16:9** campaign); must be owned by the credential's account — fork it first if not ([`../../../docs/forking.md`](../../../docs/forking.md)). |
| `userId` | ✅ | The YakYak user id the PAT belongs to. |
| `minTokenBalance` | — | Default `2000`. |
| `apiBase` | — | Default `https://api.yakyak.ai`; beta for test runs. |
| `corpusUrl` | — | Defaults to the cookbook's `corpus/on_this_day.md` on GitHub. |
| `soundtrackAudioPath` | — | `show.env` `SOUNDTRACK_AUDIO_PATH` (the documentary score). Empty = skip. |
| `soundtrackVolume` | — | `35` (`show.env` `VOLUME`). |
| `chatWebhookUrl` | — | Incoming webhook for the announcement. Empty = none. |

## 5. Ops notes — this show fails on purpose

**OnThisDay is the cookbook's worked example of the content-moderation failure
path** ([`show/README.md`](../../../show/README.md#known-intentional-failure-onthisday)).
Dramatized history names real people and IP-protected entities, and the image/video
providers' safety systems reject those prompts — usually across the *whole* fallback
chain, so affected scenes (sometimes the whole episode) fail to render rather than
degrade. In n8n that surfaces as a **Call engine failure** after generation started.

That is expected, and the recovery is the same as for the showrunner: open the movie,
read the *Generation failure details* panel, edit the offending scene to drop the
protected name, regenerate the single asset — the full walkthrough is in
[`../../../docs/debugging.md`](../../../docs/debugging.md#the-generation-failure-details-modal).
A failed run is also self-healing at the slot level: the next morning's run lands on
the same unrendered episode slot.

Other notes:

- **Historical figures speak** in scenes 2–5 by design (`allowNewCharacters=true`) —
  don't add them to the alias map; only The Chronicler is recurring.
- **Cost per episode:** 7 scenes daily (💸), *plus* per-episode portrait generation
  for the new historical figures — this show renders more new assets per episode than
  the fixed-cast ones.
- Re-runs, season rollover, beta-first testing: identical to BBN — see
  [`breaking_bricks_news.md`](./breaking_bricks_news.md) §6.

# Automating YakYak with n8n — from zero to a working movie factory

This guide takes you from *never having opened n8n* to a running automation that:

1. **listens for an input event** (a webhook call, a schedule, a new row in a sheet — anything),
2. **resolves a target campaign** in your account — adopting your existing one by name;
   a template JSON is imported only the *first* time, never per run,
3. **applies the change** in one of two modes:
   **patch** (small event-driven edits to a standing movie — the trailer by default — reusing everything untouched) or
   **episode** (significant new content → a fresh episode slot in the same campaign),
4. **renders** the movie, and
5. **emits an output event** — posting the finished movie link to a chat.

It's written for people who have **not** used n8n before. If you already know n8n, skip to
[§6 The workflow, node by node](#6-the-workflow-node-by-node).

Everything here is backed by two files you can run today, in this folder
(`integrations/n8n/`):

| File | What it is |
| --- | --- |
| [`regen-from-template.mjs`](../integrations/n8n/regen-from-template.mjs) | A zero-dependency Node script that performs the **entire** flow from a terminal. Use it to prove the pipeline works before touching n8n. |
| [`workflow.import-regen-post.json`](../integrations/n8n/workflow.import-regen-post.json) | The **importable n8n workflow** — the same flow as visual nodes. |
| [`changes.example.json`](../integrations/n8n/changes.example.json) | An example "what to regenerate" plan. |

---

## 1. The 60-second mental model

A YakYak **movie** is a list of **scenes**. Each scene is built by a 4-stage pipeline,
in this order:

```
   image  ──►  movie (Ken Burns)  ──►  subtitle-movie (voiceover)  ──►  burn (subtitles onto video)
   still       animated clip           narration track                 final scene clip
```

Then all the scene clips are **concatenated** and a **soundtrack** is muxed on top to make
the finished movie:

```
   scene 1 burn  ┐
   scene 2 burn  ├──►  concat  ──►  + soundtrack  ──►  finalMovieUrl
   scene N burn  ┘
```

An **exported campaign** (the `…----export.json` you get from YakYak) contains every scene
*with the URLs of all four artifacts already filled in*. That is the key to "reuse vs
regenerate":

> **When you import a template, every scene keeps its existing image/movie/subtitle/burn
> URLs. A scene you don't touch is reused verbatim — no regeneration, no tokens spent.
> You only pay for the scenes you deliberately change.**

Changing a scene is done through **one** endpoint per kind of change, and that endpoint
*automatically re-runs the correct part of the pipeline*:

| You change… | Call | What re-runs (everything downstream) |
| --- | --- | --- |
| Scene **story / description** | `update-scene-story` | image → movie → burn |
| Scene **dialogue** (narration) | `update-scene-dialogue` | subtitle → burn |
| Scene **animation** (pan/zoom) | `update-scene-animation-prompt` | movie → burn |
| Subtitle **styling** (font/colour via lead cast) | `update-scene-lead-cast` | subtitle → burn |
| Nothing | *(skip the scene)* | reused as-is |

There are also two "re-run without editing" endpoints for retries:

| Goal | Call |
| --- | --- |
| Re-run a scene from a stage with the **same** content (e.g. you want a different random image) | `rerun-scene` `{ from: 'image' \| 'movie' \| 'subtitle' \| 'burn' }` |
| Regenerate **one** asset only, no cascade | `regen-scene-asset` `{ asset: 'image' \| 'movie' \| 'subtitle' \| 'burn' }` |

### The two run modes

The workflow never duplicates campaigns. Every run **resolves** a target instead — one
campaign per show, forever — and then routes by intent:

| Mode | For | What happens | Version trail |
| --- | --- | --- | --- |
| **`patch`** (default) | Small, event-driven changes — a GitHub push, a chat command, a re-delivered webhook | Edits **one standing movie** in place via `update-scene-*` and re-renders — the campaign's **trailer** by default, or the episode pinned via `target.movieId`. **Diff-aware**: a change whose value already matches is skipped (free). | The movie's **render-history** — every render's URL is immutable and keeps working |
| **`episode`** | Significant new content per run — showrunner-style daily/weekly episodes | Picks the **next unrendered slot** in the campaign (minting a new season when full), writes the plot, and `gen-movie-screenplay` writes + renders every scene server-side 💸 | One campaign, N distinct episodes |

That's the whole model. The rest of this doc is plumbing.

---

## 2. Prerequisites

### 2.1 A YakYak personal access token (PAT)

The API authenticates with a **PAT** shaped `yy_live_…`.

1. Sign in at [yakyak.ai](https://yakyak.ai/) → open **`/profile`**.
2. Under **Personal Access Tokens** → **+ New token**.
3. Name it (e.g. `n8n`) and give it the **`video_creation`** scope (required to import,
   edit, and render). Add **`social_publishing`** only if you'll auto-post.
4. **Copy the `yy_live_…` value now** — it's shown once.

> 💡 The `import-campaign` request body wants a plain `userId` — but the PAT **already
> encodes it** (it's `yy_live_` + a normal JWT with the id in its payload), so both the
> script and the workflow **decode it from the token automatically**. You never need to
> look it up. `YAKYAK_USER_ID` exists only as an optional override (e.g. admins acting
> on another account).

> 💰 **Top up your token balance first.** Regenerating scenes and rendering cost tokens.
> Reused scenes are free; only what you change (and the final concat/soundtrack) is billed.

### 2.2 An exported campaign template

Any campaign you can see in YakYak can be exported:

```
GET https://api.yakyak.ai/workflow/export-campaign/{campaignId}
Authorization: Bearer yy_live_…
```

The response is the same shape as the `…----export.json` file you already have. Save it —
you'll feed it in as `importData` **on the first run only**: the workflow imports it once to
provision your campaign, and every later run finds that campaign by name and reuses it. If
your campaign already lives in your account, you don't need an export at all — pass
`target.campaignId` or `target.campaignName` instead.

### 2.3 An output chat webhook (optional but recommended)

Slack, Discord, and Teams all support **incoming webhooks** — a URL you `POST` a
`{ "text": "…" }` body to, and it appears as a message. Create one:

- **Slack:** *Apps → Incoming Webhooks → Add to a channel* → copy the `https://hooks.slack.com/…` URL.
- **Discord:** *Channel → Edit → Integrations → Webhooks → New Webhook* → copy URL. (Discord's
  field is `content`, not `text`; both scripts send `text` — for Discord change the body key,
  or use n8n's native **Discord** node.)

---

## 3. Prove it works *without* n8n first (5 minutes)

Before wiring nodes, run the reference script. It does the whole flow and prints the final
movie URL. If this works, your token, template, and account are all good — and any later n8n
problem is an n8n-config problem, not a YakYak one.

> 🧪 **Keep token and API base in the same environment.** Tokens are per-environment
> (separate JWT secrets). Beta base is `https://api.beta.yakyak.ai`, prod is
> `https://api.yakyak.ai`. For heavy iteration prefer **beta** (its accounts carry a large
> token balance, so re-running is effectively free); use prod only for the real thing.
> Your `userId` is decoded from the token itself, so it automatically matches whichever
> environment minted the token.

```bash
cd integrations/n8n

export YAKYAK_TOKEN="yy_live_…"
export MODE="patch"                                   # or "episode"; default patch
export TEMPLATE_PATH="/path/to/your----export.json"   # first run only (provision-once)
# …or target an existing campaign directly:
# export CAMPAIGN_NAME="My Show"                      # adopt by name
# export CAMPAIGN_ID="…"  MOVIE_ID="…"                # or pin ids explicitly
export CHANGES_PATH="./changes.example.json"          # omit for a straight re-render
export CHAT_WEBHOOK_URL="https://hooks.slack.com/…"   # optional

node regen-from-template.mjs
```

Expected output (abridged, patch mode):

```
→ resolving target (mode=patch)…
  campaign=… (reused) movie=…
  10 scenes; 2 change(s) requested
  · scene #3: story
  · scene #5: dialogue (no-op, skipped)
→ waiting for scene regeneration…
  scenes img 1/1 · mov 1/1 · sub -/- · burn 1/1
→ export-render…
→ waiting for concat + soundtrack…
  concat=completed soundtrack=completed

🎬 Finished movie (patch, 1 change(s)): https://cdn.yakyak.ai/…/final.mp4
→ posting to chat webhook…
```

Note the `(no-op, skipped)`: patch mode compares each change against the scene's current
value and skips identical ones, so re-running the same plan is idempotent and free. Run it
twice to see every change turn into a no-op.

Requires **Node 18+** (uses the built-in `fetch`). No `npm install` needed.

> The script is the canonical spec of the flow — every n8n node below maps to a block in it.
> Read it top-to-bottom once; it's ~200 commented lines.

---

## 4. Installing n8n

Two easy options.

### 4.1 n8n Cloud (nothing to install)
Sign up at [n8n.io](https://n8n.io/) → you get a hosted instance with a URL. Good for a quick
try. Note: setting **environment variables** (used below for the token) may require the
self-hosted option or their variables feature.

### 4.2 Self-hosted with Docker (recommended — lets you set env vars)

```bash
docker run -it --rm \
  --name n8n \
  -p 5678:5678 \
  -v ~/.n8n:/home/node/.n8n \
  -e YAKYAK_API_BASE="https://api.yakyak.ai" \
  -e YAKYAK_TOKEN="yy_live_…" \
  -e N8N_BLOCK_ENV_ACCESS_IN_NODE=false \
  -e N8N_RUNNERS_ENABLED=true \
  docker.n8n.io/n8nio/n8n
```

`N8N_BLOCK_ENV_ACCESS_IN_NODE=false` matters: recent n8n versions **block Code nodes from
reading `$env` by default**, and this workflow's two Code nodes need it (for the token and
the userId derivation). Without it every run dies immediately with *"access to env vars
denied"* in the **Resolve target** node.

Open <http://localhost:5678>. On first launch n8n asks for an **email + password** — that's
just creating the local owner account for *your* instance (stored in `~/.n8n`, no n8n.io
signup, no verification email). Pick anything and note it down; skip the optional
license/survey screens.

The two `YAKYAK_*` env vars are what the workflow reads for
its base URL and auth (so **no secrets are stored inside the workflow JSON**).

> **Why env vars, not the workflow file?** The exported `workflow…json` is meant to be shared.
> Keeping the token in the n8n **environment** (or a credential, see §5.4) keeps it out of the
> file. If you prefer a native credential instead of env vars, see §5.4.

---

## 5. Importing and configuring the workflow

### 5.1 Import
The import menu lives in the workflow **editor**, not on the workflows list page. In n8n:
**Create workflow** (opens a blank canvas) **→ top-right menu (⋯, next to Save) → Import
from File… →** choose `integrations/n8n/workflow.import-regen-post.json`, then **Save**.
(Copy-pasting the JSON straight onto the canvas also works.) You'll see a canvas of 16
nodes wired left-to-right with two small feedback loops (the polling waits).

### 5.2 What it expects
The workflow is triggered by a **Webhook** node. You start a run by `POST`ing a JSON body:

```jsonc
{
  "target": {
    "mode": "patch",                    // "patch" (default) or "episode"
    "campaignId": "…",                  // optional: pin the campaign explicitly
    "campaignName": "My Show",          // optional: adopt your campaign by name
    "movieId": "…"                      // optional (patch mode): pin the episode
  },
  "importData": { "campaigns": [ /* … */ ] },  // FIRST RUN ONLY: provision-once fallback
  "changes": {
    "movie":  { "title": "optional new title", "plot": "episode mode: the story text" },
    "scenes": [                                // patch mode only
      { "sceneNumber": 3, "action": "story",     "story": "new description…" },
      { "sceneNumber": 5, "action": "dialogue",  "dialogue": "new line, no trailing period" }
    ]
  },
  "chatWebhookUrl": "https://hooks.slack.com/services/…"
}
```

- `target` — which campaign/movie to operate on, and how (see [§1](#the-two-run-modes)).
  Resolution order: explicit `campaignId` → **derived from `movieId`** (a movie-id-only call
  is enough; the movie record knows its campaign) → `campaignName` matched against your owned
  campaigns (oldest match wins — it's the canonical original) → **import `importData` once**.
  In patch mode the movie is `movieId` if given, else the campaign's **trailer/template
  movie** — the stable default. Numbered episodes are never auto-picked (grabbing S1E1 out
  of a grid of episodes is a footgun); pin one with `movieId` when you mean an episode.
  In episode mode it's the next unrendered slot (a new season is created when all slots are
  rendered).
- `importData` — the **entire** exported campaign JSON (top-level `campaigns` array). Only
  consulted when no owned campaign matches; every later run adopts the imported campaign by
  name. **This is what stops duplicate campaigns piling up.**
- `changes` — your change plan (see [§7](#7-the-change-plan-schema)). Patch mode: omit or
  leave `scenes: []` to reuse everything and just re-render. Episode mode: `movie.plot` is
  **required** — it's the story the new episode is generated from.
- `chatWebhookUrl` — where to post the finished movie. Optional: if omitted, the **Post to
  chat** node fails softly (it's set to *continue on error*) and the run still responds with
  the movie URL. Delete the node if you never want an output event.

### 5.3 Env vars the nodes read
Every YakYak HTTP node sends `Authorization: Bearer {{ $env.YAKYAK_TOKEN }}` and builds its
URL from `{{ $env.YAKYAK_API_BASE }}`. Make sure those two are set on your n8n instance
(§4.2). The `userId` some request bodies want is **decoded from the token** by the
**Resolve target** node — set `YAKYAK_USER_ID` only if you need to override it.

### 5.4 (Alternative) Use an n8n credential instead of env vars
If you'd rather store the token as a proper credential:

1. **Credentials → New → Header Auth.** Name: `YakYak Bearer`. Header **Name** `Authorization`,
   **Value** `Bearer yy_live_…`.
2. On each HTTP Request node: **Authentication → Generic → Header Auth →** pick `YakYak Bearer`,
   and remove the manual `Authorization` header.
3. The **Resolve target** and **Apply changes** Code nodes still read `$env.YAKYAK_TOKEN`
   (Code nodes can't use a credential directly) — keep that env var either way.

### 5.5 Activate (a.k.a. Publish)
Click **Publish** top-right (older n8n versions: toggle **Active**) to deploy the workflow and
expose the production webhook URL. **Unpublish** deactivates it. While developing, don't
publish — use **Test workflow** + the *test* webhook URL instead (see §8).

---

## 6. The workflow, node by node

```
Input event (Webhook)
   └─► Resolve target (Code)                                    ← userId from PAT; campaign by
        │                                                          id / name / import-once;
        │                                                          movie by mode (standing
        │                                                          episode | next empty slot)
        └─► Get scenes (GET /workflow/get-scenes/:movieId)      ← current values, for diffing
             └─► Apply changes (Code)                           ← patch: diff-aware update-scene-*
                  │                                                episode: set plot + gen-screenplay
                  └─► Generation progress (GET, per mode) ──────────────┐
                       └─► Generation settled? (Code)                   │ poll loop
                            └─► IF generation done ──false──► Wait 15s ─┘
                                   │true
                                   ▼
                              Export render (POST /workflow/export-render {force:true})
                                   └─► Movie progress (GET get-movie-progress) ┐
                                        └─► Render done? (Code)                │ poll loop
                                             └─► IF render done ─false─► Wait ─┘
                                                    │true
                                                    ▼
                                               Get movie (GET /workflow/get-movie/:movieId)
                                                    └─► Post to chat (POST chatWebhookUrl)
                                                         └─► Respond ({ url, movieId, mode, … })
```

| Node | Type | Does |
| --- | --- | --- |
| **Input event** | Webhook | Entry point. `POST` body = `{ target, importData?, changes, chatWebhookUrl? }`. |
| **Resolve target** | Code | The anti-duplication heart. Decodes `userId` from the PAT; resolves the campaign (explicit id → adopt-by-name via `list-campaign` → `import-campaign` **once**); resolves the movie per mode — patch: `movieId` or the trailer/template (episodes are never auto-picked); episode: next unrendered slot, `create-new-season` when full, `gen-movie-season` bootstrap when empty (plus a best-effort switch to `basic` mode so generation auto-chains). |
| **Get scenes** | HTTP | `get-scenes/:movieId` — current values; patch mode maps `sceneNumber → id` **and** diffs against them. |
| **Apply changes** | Code | Patch: each change calls the matching `update-scene-*` (self-triggering its regen cascade), **skipping values that already match** — re-delivered events cost nothing. Episode: `set-movie-metadata {plot}` + `gen-movie-screenplay` (writes + renders every scene server-side 💸). |
| **Generation progress** → **Generation settled?** → **IF** → **Wait** | HTTP/Code/IF/Wait | Patch: polls `get-movie-scene-progress` until no stage is mid-flight (skipped entirely when nothing changed). Episode: polls `get-movie-progress` until the `movieScreenplay` execution completes — the web app's own signal. |
| **Export render** | HTTP | `export-render { force:true }` — concat + soundtrack. `force:true` guarantees a stitched output and, in episode mode, drives any per-scene renders still finishing. |
| **Movie progress** → **Render done?** → **IF** → **Wait** | HTTP/Code/IF/Wait | Polls `get-movie-progress` until `movieConcat` (and `movieSoundtrack`) are `completed`. |
| **Get movie** | HTTP | Reads `finalMovieUrl` (falls back to `soundtrackedMovieUrl` / `concatMovieUrl`). |
| **Post to chat** | HTTP | The **output event** — posts the movie link to `chatWebhookUrl`. Set to *continue on error* so a missing URL can't kill a finished run. |
| **Respond** | Respond to Webhook | Returns `{ url, movieId, campaignId, mode, changed }` to whoever called the trigger. |

### Why poll instead of a callback?
YakYak's render steps do have internal completion **hooks**, but they're locked to an internal
API key and call *back into YakYak* (they're how Creatomate/the Lambda notify the backend) —
they are **not** an outbound webhook you can point at n8n. So the output side must **poll**.
Renders take minutes, so a 15 s poll is cheap. (If you want push instead of poll, stand up a
tiny relay service that YakYak's internal hook hits and have it call your n8n webhook — only
worth it at high volume.)

---

## 7. The change plan schema

### Episode mode
The plan is just the story — `gen-movie-screenplay` writes and renders the scenes from it:

```jsonc
{
  "movie": {
    "title": "Episode title (optional)",
    "plot":  "The story text the new episode is generated from. REQUIRED in episode mode."
  }
}
```

`scenes[]` is ignored in episode mode (the scenes don't exist until generation writes them).

### Optional soundtrack fields (both modes)
`changes.movie` also accepts `soundtrackAudioPath` (a CDN content-address, applied via
`set-soundtrack-audio` — no upload, the render reuses the file) and `soundtrackVolume`
(0–100, via `set-soundtrack`). Omit both to keep the movie's current soundtrack. Used by
the Breaking Bricks News example
([`integrations/n8n/docs/breaking_bricks_news.md`](../integrations/n8n/docs/breaking_bricks_news.md)).

### Patch mode
`changes` describes what to regenerate on the target movie (the trailer by default). **Scenes you don't list are
reused as-is — and so is any listed change whose value already matches (no-op skip).**

```jsonc
{
  "movie": { "title": "optional — new movie title" },
  "scenes": [
    { "sceneNumber": 3, "action": "story",     "story": "A sandstorm rolls over the dunes…" },
    { "sceneNumber": 5, "action": "dialogue",  "dialogue": "Hold on tight" },
    { "sceneNumber": 2, "action": "animation", "prompt": "slow push-in, gentle upward tilt" },
    { "sceneNumber": 4, "action": "styling",   "leadCast": "Olivia" },
    { "sceneNumber": 4, "action": "styling",   "backgroundColor": "#0b1e3f" },
    { "sceneNumber": 7, "action": "retry",     "from": "image" },
    { "sceneNumber": 8, "action": "regen",     "asset": "movie" }
  ]
}
```

| `action` | Fields | Endpoint | Regenerates |
| --- | --- | --- | --- |
| `story` | `story` | `update-scene-story` | image → movie → burn (voiceover reused) |
| `dialogue` | `dialogue` | `update-scene-dialogue` | subtitle → burn |
| `animation` | `prompt` | `update-scene-animation-prompt` | movie → burn (same still) |
| `styling` | `leadCast` and/or `backgroundColor` | `update-scene-lead-cast` / `update-scene-background-color` (+ `rerun-scene from:subtitle`) | subtitle → burn |
| `title` | `title` | `update-scene-title` | nothing (metadata) |
| `retry` | `from` | `rerun-scene` | from that stage, same content |
| `regen` | `asset` | `regen-scene-asset` | just that one asset |

**`sceneNumber`** is the 1-based number from the template's `scenes[].sceneNumber`.

### Rules & gotchas
- **One action per entry.** If a single scene needs two different edits (say story *and*
  dialogue), they'd both race on the shared **burn** step. Put conflicting edits to the *same*
  scene in **separate runs**, or accept that the later cascade wins. Edits to *different*
  scenes never conflict.
- **Dialogue must not end in a period.** YakYak's generated dialogue convention is no trailing
  `.` (`!`/`?` are fine). Strip it when you transform text.
- **`story` keeps the existing voiceover.** It re-does the *visual* (image→movie) and re-burns,
  but reuses the narration audio. If you want new narration too, also send a `dialogue` change
  (separate run — see above).
- **Aspect ratio / animation type are campaign-level.** Changing them isn't a per-scene edit;
  set them on the campaign before import, or they'll dirty every scene.

---

## 8. Testing

### 8.1 Smallest possible test — resolve + re-render, zero regeneration
Cheapest path (only the final concat/soundtrack is billed):

```bash
curl -sS -X POST "http://localhost:5678/webhook-test/yakyak-regen" \
  -H "Content-Type: application/json" \
  -d "{\"importData\": $(cat /path/to/your----export.json), \"changes\": {\"scenes\": []}}"
```

The **first** run imports the template (no owned campaign matches its name yet); **every run
after that adopts the same campaign by name** — run it five times and you still have one
campaign. (Use `/webhook-test/…` with **Test workflow** running; use `/webhook/…` when the
workflow is **published**.) Watch the canvas light up node by node. The response is
`{ "url": "…", "movieId": "…", "campaignId": "…", "mode": "patch", "changed": 0 }`.

### 8.2 A patch run
Swap in a small `changes`:

```bash
CHANGES='{"scenes":[{"sceneNumber":5,"action":"dialogue","dialogue":"The desert does not forgive hesitation"}]}'
curl -sS -X POST "http://localhost:5678/webhook-test/yakyak-regen" \
  -H "Content-Type: application/json" \
  -d "{\"importData\": $(cat /path/to/your----export.json), \"changes\": $CHANGES, \"chatWebhookUrl\": \"https://hooks.slack.com/…\"}"
```

Only scene 5's subtitle+burn regenerate; the other scenes are reused; the movie re-concats;
the link lands in your chat. **Run the same curl again**: `changed` comes back `0` — the
value already matches, so nothing regenerates and nothing is billed except the re-render.

### 8.3 An episode run
Mint a new episode in the same campaign from a story (💸 — generates every scene):

```bash
curl -sS -X POST "http://localhost:5678/webhook-test/yakyak-regen" \
  -H "Content-Type: application/json" \
  -d '{
    "target":  { "mode": "episode", "campaignName": "My Show" },
    "changes": { "movie": { "title": "S01E02 — The Storm", "plot": "Johan and Claire shelter from a sandstorm in a caravanserai, where an old merchant tells them the road ahead is cursed…" } }
  }'
```

The run picks the next unrendered slot (creating a new season when all are rendered),
generates the screenplay + scenes server-side, renders, and returns the new episode's URL.

### 8.4 Inspecting a run
The canvas only animates live for **test** runs. Production runs (`/webhook/…` on a published
workflow) execute silently in the background — open the **Executions** tab and click the run
to watch it node by node instead. Either way, click any node afterwards to see its
input/output JSON: the **Resolve target** node's output shows which campaign/movie was chosen
and whether it was `reused` or `imported`; the **Get scenes** output shows the
`sceneNumber → id` mapping; the progress nodes show the live counts.

### 8.5 Triggering from something other than a webhook
The **Input event** can be any n8n trigger. Common swaps:
- **Schedule** trigger + `mode: "episode"` → a fresh episode every morning (the showrunner
  pattern: same campaign, next slot, new story).
- **GitHub / chat / form** trigger + `mode: "patch"` → an event tweaks the standing movie (trailer by default)
  and re-renders it.
- **Google Sheets / Airtable** trigger → a new row = a new episode plot.

Just map your trigger's payload into the same `{ target, changes }` shape.

---

## 9. Endpoint reference (everything the flow uses)

Base URL `https://api.yakyak.ai`. All require `Authorization: Bearer yy_live_…`.

| Method & path | Body | Returns |
| --- | --- | --- |
| `GET  /workflow/list-campaign/:userId` | — | `{ campaigns:[{ id, name, createdAt, template:{ id }, … }] }` — the adopt-by-name lookup |
| `GET  /workflow/get-campaign/:campaignId` | — | `{ campaign:{ movies:[{ id, season, episode, renderedMovieUrl, … }] } }` — numbered episodes only |
| `POST /workflow/import-campaign` | `{ userId, importData }` | `{ imported, campaigns:[{ id, name, movies:[{ id, title, season, episode }] }] }` — **provision-once fallback** |
| `POST /workflow/switch-campaign-mode` | `{ campaignId, mode: "basic"\|"pro" }` | basic mode auto-chains generation (episode mode needs it) |
| `POST /workflow/create-new-season` | `{ campaignId }` | mints the next season's empty episode slots (500s on an empty campaign) |
| `POST /workflow/gen-movie-season` | `{ movieId: templateMovieId }` | bootstraps season 1 on a slot-less campaign |
| `POST /workflow/set-movie-metadata` | `{ movieId, plot }` | writes the episode's story text |
| `POST /workflow/gen-movie-screenplay` | `{ movieId }` | writes the screenplay AND renders every scene server-side 💸 |
| `POST /workflow/fork-campaign` | `{ userId, sourceCampaignId, sourceMovieId? }` | new campaign/movie ids |
| `GET  /workflow/get-scenes/:movieId` | — | `{ scenes:[{ id, sceneNumber, title, story, dialogue, leadCast, imageUrl }], movieId }` |
| `POST /workflow/update-scene-story` | `{ sceneId, story }` | triggers image→movie→burn |
| `POST /workflow/update-scene-dialogue` | `{ sceneId, dialogue }` | triggers subtitle→burn |
| `POST /workflow/update-scene-animation-prompt` | `{ sceneId, prompt }` | triggers movie→burn |
| `POST /workflow/update-scene-lead-cast` | `{ sceneId, leadCast }` | triggers subtitle→burn |
| `POST /workflow/update-scene-background-color` | `{ sceneId, backgroundColor }` | persists (apply via a subtitle re-run) |
| `POST /workflow/update-scene-title` | `{ sceneId, title }` | metadata only |
| `POST /workflow/update-movie-title` | `{ movieId, title }` | metadata only |
| `POST /workflow/rerun-scene` | `{ sceneId, from?: image\|movie\|subtitle\|burn }` | re-run same content from a stage |
| `POST /workflow/regen-scene-asset` | `{ sceneId, asset: image\|movie\|subtitle\|burn }` | regen one asset, no cascade |
| `GET  /workflow/get-movie-scene-progress/:movieId` | — | `{ steps:{ image, movie, subtitlesMovie, burn }:{ done, total, failed }, totals:{ scenes } }` |
| `POST /workflow/export-render` | `{ movieId, force?: boolean }` | starts concat + soundtrack |
| `GET  /workflow/get-movie-progress/:movieId` | — | `{ executions:[{ type, status }] }` (`type` ∈ movieConcat, movieSoundtrack, …) |
| `GET  /workflow/get-movie/:movieId` | — | `{ movie:{ finalMovieUrl, soundtrackedMovieUrl, concatMovieUrl } }` |
| `GET  /workflow/export-campaign/:campaignId` | — | the exportable template JSON |

The full, always-current list is the OpenAPI spec:
- **Swagger UI:** <https://api.yakyak.ai/api/docs>
- **OpenAPI JSON:** <https://api.yakyak.ai/api/docs-json> (the published `yakyak-sdk` is generated
  from this; the SDK wraps these same endpoints if you'd rather write TypeScript/Python than raw
  HTTP — see `sdk/` and `course/` in this repo).

---

## 10. Troubleshooting

| Symptom | Likely cause / fix |
| --- | --- |
| n8n shows a **sign-in** screen (not "set up owner"), and *Forgot password* says "n8n isn't set up to send email" | Your `~/.n8n` volume already has a database with an owner account from an earlier run, and password recovery needs SMTP (a local instance has none). Reset it: `docker exec n8n n8n user-management:reset` → reload → the setup screen is back. Workflows are kept. |
| `401 Unauthorized` on every node | `YAKYAK_TOKEN` missing/expired, or the `Bearer ` prefix got dropped. Re-check the env var / Header Auth credential. |
| `403` / owner error during import | You set the optional `YAKYAK_USER_ID` override and it doesn't match the token's owner (import is owner-scoped). Unset it — the workflow decodes the right id from the token. |
| `500 Internal server error` on import (`P2003 campaign_userId_fkey`) | Only reachable with a `YAKYAK_USER_ID` override that **isn't a real user in the environment you're hitting** (`import-campaign` writes `userId` as a foreign key). Normally a wrong `userId` returns a clean **403** — but if your account is an admin (`ADMIN_EMAILS`) the ownership guard is *bypassed*, so the bad id slips through to this DB error. Unset the override, or set it to an id that exists in that exact environment. |
| **Resolve target** fails: `access to env vars denied` | Recent n8n blocks `$env` in Code nodes by default. Add `-e N8N_BLOCK_ENV_ACCESS_IN_NODE=false` to the docker run (§4.2) and restart. |
| **Resolve target** fails: could not decode a userId | `YAKYAK_TOKEN` is missing or isn't a `yy_live_…`/JWT-shaped token. Re-check the env var; or set `YAKYAK_USER_ID` explicitly as a workaround. |
| **Resolve target** adopts the *wrong* campaign | Several owned campaigns share the name (v1-era import duplicates). The oldest match wins by design — pass `target.campaignId` to pin explicitly, and delete the stray duplicates in the web app. |
| **Resolve target** fails: `season creation is still in progress` | `create-new-season` / `gen-movie-season` hadn't produced slots within the Code node's time budget (~40 s; task runners cap Code nodes at ~60 s). The season *is* being created — just re-run in a minute and it picks up the new slot. |
| Patch mode edited an unexpected movie | With no `target.movieId`, patch targets the campaign's **trailer/template** movie (episodes are never auto-picked). To edit an episode, pin its id via `target.movieId` — the **Get scenes** / error output lists the candidates. The trailer's id is `list-campaign`'s `entry.template.id`; `get-campaign` filters it out of the episode list. |
| Episode run produces an empty/2-scene movie | That's what `gen-movie-screenplay` wrote from your `plot` (plus the system outro). Give it a richer story; scenes are derived from it, not from `changes.scenes` (ignored in episode mode). |
| Episode generation never settles / scenes stuck | The campaign may be in `pro` mode, where the pipeline doesn't auto-chain. The workflow best-effort switches to `basic` in **Resolve target**; verify with the web app (campaign settings) if it keeps stalling. |
| `401 Unauthorized` when you switch `YAKYAK_API_BASE` | Tokens are **per-environment** — beta and prod have separate JWT secrets. A prod `yy_live_…` token only works against `api.yakyak.ai`; a beta token only against `api.beta.yakyak.ai`. Mint a token in the same environment you're calling. |
| Import fails: "no campaigns found" | `importData` must be the full object with the top-level `campaigns` array — not a single campaign object. |
| Scene changes seem ignored | You referenced a `sceneNumber` that doesn't exist, or the scene was reused (not in `changes`). Check the **Get scenes** output for valid numbers. |
| Run hangs forever in the **Generation progress** poll loop, `movieConcat` stays `draft` | A movie can report a stage as forever-pending with `failed: 0` (the dialogue-less outro scene has no subtitle/burn asset, so `subtitlesMovie`/`burn` sit at N-1/N). The workflow skips the wait when nothing changed — if you edited the **Generation settled?** node, keep that short-circuit. |
| The final URL is empty | `export-render` ran but the movie wasn't ready when **Get movie** fired. The render poll should prevent this; if you edited the workflow, ensure **Get movie** is *after* the `IF render done → true` branch. |
| Render never finishes / times out | A scene stage `failed` (see **Generation progress** counts, the `failed` column). Re-run that scene with a `retry` action. The script surfaces `✗` counts in its log. |
| n8n kills the run mid-render | Raise the execution timeout: env `EXECUTIONS_TIMEOUT=3600` (the workflow also sets `settings.executionTimeout`). Renders can take several minutes. |
| Code node error: `this.helpers is undefined` | Enable task runners (`N8N_RUNNERS_ENABLED=true`) or run a recent n8n; older versions expose helpers differently. As a fallback, replace the **Apply changes** Code node with individual HTTP Request nodes in a loop. |
| Nothing arrives in chat | Test the `chatWebhookUrl` with a plain `curl -d '{"text":"hi"}'`. For Discord, change the body key to `content` or use the native Discord node. |

---

## 11. Where to go next

- **Add social posting** as the output event: after **Get movie**, call the YakYak social
  endpoints (or n8n's Slack/YouTube/Instagram nodes) instead of / in addition to the chat webhook.
- **Batch generation:** put a **Schedule** or **Split In Batches** trigger in front with
  `mode: "episode"` to produce a season of episodes from a list of plots — one campaign,
  one episode per prompt.
- **Skip the JSON round-trip:** if your show already lives in YakYak, drop `importData`
  entirely and pass `target.campaignId` (or `campaignName`) — no export file needed.
- **Write it in code instead:** the `yakyak-sdk` (TypeScript & Python) wraps every endpoint used
  here — see [`course/`](../course/) for worked SDK examples, and
  [`regen-from-template.mjs`](../integrations/n8n/regen-from-template.mjs) for the raw-HTTP version.

See also: [`integrations/n8n/README.md`](../integrations/n8n/README.md) ·
[`docs/yakyak-pat-and-secrets.md`](./yakyak-pat-and-secrets.md) (minting the PAT) ·
[`docs/workflows.md`](./workflows.md).

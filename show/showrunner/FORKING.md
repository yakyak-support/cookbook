# Fork → your first episode

You forked YakYak and want to produce episodes the way the showrunner does — your
own cast, your own daily story, rendered into a finished video. This is the shortest
path to do that **against the hosted API** (`https://api.yakyak.ai`). You drive three
small scripts from your own checkout; no Docker, no CI, no AWS.

> The engine (`show/showrunner/`) is show-agnostic. Everything specific to *your*
> show — campaign, cast, soundtrack, story source, cadence — lives in one directory
> under `show/`, selected at runtime with `--show`. For the full engine reference
> see [`README.md`](./README.md); for the gallery of example shows to copy from see
> [`../README.md`](../README.md).

---

## With AI or without?

There is exactly one decision that changes your prereqs. It's *how the daily story
gets written* — everything after that (images, voices, render) is the same.

| | **Without AI** (deterministic) | **With AI** (model-dramatized) |
| --- | --- | --- |
| Story source | `compute.{py,js,sh}` — pure code | `prompt.md` (or `compute` that calls `claude`) |
| `show.env` | `PREPARE_KIND="compute"`, `REQUIRES_MODEL="false"` | `PREPARE_KIND="prompt"`, `REQUIRES_MODEL="true"` |
| Extra prereq | none | `claude` CLI + `ANTHROPIC_API_KEY` |
| Copy this template | [`../LuckyDay`](../LuckyDay) (date-math almanac) | [`../PettyCourt`](../PettyCourt) (WebFetch + dramatize) |
| Good for | Computed / Randomized / Extracted shows (anything reproducible from a date, a seed, or a corpus) | WebFetch / dramatized shows (live data, or a corpus turned into scenes by a model) |

Either way, YakYak still generates the images and voices server-side — that "AI" is
the product, not something you run. "Without AI" means **you** write no prompts and
need no model key to source your story.

> **Meta-shortcut:** if you *do* have Claude Code, the most painless authoring path is
> to point it at this file plus an existing show and let it write your `show.env`,
> `campaign.import.json`, and `compute.js`/`prompt.md` for you.

---

## Prerequisites

Install once:

- `git`, plus the toolchain for the **one** engine port you'll use:
  - **shell port** — just `bash`, `curl`, `jq` (nothing to install per-run);
  - **JS port** — `node ≥ 18` + `npm` (then `npm install` in `show/showrunner/`);
  - **Python port** — `python3 ≥ 3.8` + `pip` (then `pip install -r show/showrunner/requirements.txt`).
- `curl` + `jq` are needed by `setup_show.sh` **regardless** of which port you pick.
- **AI path only:** the `claude` CLI (`npm i -g @anthropic-ai/claude-code`) and an
  `ANTHROPIC_API_KEY` (or `CLAUDE_CODE_OAUTH_TOKEN`) in your environment.

All three ports read the same `show.env` and produce identical results — pick whichever
language you're comfortable in.

---

## Step 1 — Get a YakYak account and mint a PAT

The scripts authenticate with a **personal access token** (format `yy_live_…`).

1. Sign in at yakyak.ai and open **`/profile`**.
2. Under **Personal Access Tokens**, click **+ New token**.
3. Name it (e.g. "showrunner"), check the **video_creation** scope (add
   **social_publishing** only if you'll auto-post), and create it.
4. **Copy the `yy_live_…` token now** — it's shown once and never again.

```bash
export YAKYAK_PAT="yy_live_..."
```

> Producing episodes costs tokens — `setup_show.sh` generates cast portraits, composes
> a soundtrack, and renders a trailer; each episode then renders too. The free signup
> grant won't cover a full setup, so top up the account's balance first. The scripts
> abort if the balance is below `MIN_TOKEN_BALANCE` (default 2000).

The API base defaults to `https://api.yakyak.ai`; override with `YAKYAK_API_URL` if
you ever need to point elsewhere.

---

## Step 2 — Create your show directory

Copy the template that matches your AI/no-AI choice, then rename it:

```bash
cp -r show/LuckyDay   show/MyShow     # without AI (deterministic)
# or
cp -r show/PettyCourt show/MyShow     # with AI (prompt.md)
```

Now edit three things inside `show/MyShow/`:

**`show.env`** — clear the campaign id and set your knobs:

```bash
CAMPAIGN_ID=""                 # leave empty — setup (step 3) fills this in
CAST_ALIASES="Host=Host,..."   # map each leading-character name your story emits
STORY_GLOB="*_my_show.md"      # how the engine finds the freshest story
STORY_SUFFIX="_my_show.md"     # what prepare.sh names the file it writes
PREPARE_KIND="compute"         # or "prompt"
REQUIRES_MODEL="false"         # "true" for the prompt path
ENGINE="py"                    # which port: py | js | sh
VOLUME="30"                    # soundtrack volume 0–100
MIN_TOKEN_BALANCE="2000"
```

**`campaign.import.json`** — your campaign + cast roster. Set `name`, `prompt`,
`aspectRatio` (`9:16` / `16:9` / `1:1`), `animationType` (`kenburns`),
`allowNewCharacters` (`false` = recurring cast with pre-generated portraits; `true`
= new faces per episode), and `style.{label,description}` — the style string is
**appended to every image prompt**, so put your art direction there. Fill the
`customCast` / `cast` roster with each character's `castVoices` and `castSubtitles`
(font + color).

**The story source** — either `compute.{py,js,sh}` (no AI) or `prompt.md` (AI). Both
must emit the **story-markdown contract** below; that contract is the entire interface
between your source and the renderer.

### The story-markdown contract

`prepare.sh` (or whatever you write) must produce a file shaped like this — abridged
from a real `show/DailyPull/stories/…` file:

```markdown
# My Show — 2026-06-09
**Generated (UTC):** 20260609T034437Z

## Headlines we drew from:
- 🔮 My Show — 2026-06-09: the one-liner that becomes the social caption

---

## Scene 1 — The Title
**Leading character:** Host          ← must match a name in CAST_ALIASES
**Dialog:** "One spoken line, eight to fourteen words, no trailing period"

A ~180-word prose brief describing what the viewer sees — the visual direction,
the action, the mood. This is what the image prompt is built from.

## Scene 2 — …
**Leading character:** …
**Dialog:** "…"

…prose…
```

Rules that matter: the **first Headlines bullet is the social caption**; each
`**Leading character:**` must resolve through `CAST_ALIASES`; and **dialog lines never
end in a period** (`!` and `?` are fine).

A `compute.*` script receives `OUTPUT_FILE`, `TIMESTAMP`, and `SHOW_DIR` in its
environment and writes the markdown to `$OUTPUT_FILE`. A `prompt.md` uses the
`{{OUTPUT_FILE}}` / `{{TIMESTAMP}}` placeholders and is driven by `claude -p`
(WebFetch + Write).

---

## Step 3 — One-time campaign setup

This imports `campaign.import.json` into a new campaign, generates the recurring cast
portraits, composes one reusable soundtrack, renders a trailer, bootstraps season 1,
and writes the resolved `CAMPAIGN_ID` + `SOUNDTRACK_AUDIO_PATH` back into your
`show.env`. It's **idempotent** — safe to re-run; paid steps already done are skipped.

```bash
./show/showrunner/setup_show.sh show/MyShow
```

(Needs `curl` + `jq` and your `YAKYAK_PAT`. Pass `--no-soundtrack` to skip music.)

### Faster (and free): fork an existing campaign instead

If you're happy reusing the **cast, style, and soundtrack of an existing campaign**
(e.g. one of the showrunner demos, or one you already set up once), you can **fork it
instead of running `setup_show.sh`** — and skip `campaign.import.json` entirely.

Forking deep-copies the source and **reuses its already-generated cast portraits,
voices, subtitle styles, soundtrack, and rendered trailer** — so it costs **zero
tokens and is instant**, where `setup_show.sh` *regenerates* all of that (paid).

Easiest: open the source campaign in the app and click **Fork** — your account gets a
private copy. Or script it (the source must be public/known to you; the new campaign
belongs to your PAT's user):

```bash
# derive your userId from the PAT, then fork
USER_ID=$(printf '%s' "${YAKYAK_PAT#yy_live_}" | cut -d. -f2 \
  | tr '_-' '/+' | base64 -d 2>/dev/null | jq -r .id)

curl -s -X POST "$YAKYAK_API_URL/workflow/fork-campaign" \
  -H "Authorization: Bearer $YAKYAK_PAT" -H "Content-Type: application/json" \
  -d "{\"userId\":\"$USER_ID\",\"sourceCampaignId\":\"<SOURCE_CAMPAIGN_ID>\"}" | jq .
```

Then put the returned campaign id into your `show.env` and **skip to step 4**:

```bash
CAMPAIGN_ID="<the forked campaign id>"
SOUNDTRACK_AUDIO_PATH="..."   # copy from the source's show.env, or read it from
                              # GET /workflow/get-campaign/<id>; empty = generic picker
```

Caveats:
- **Fork only helps if you want that campaign's cast and look.** For a brand-new
  cast/style there's nothing to inherit — use `setup_show.sh`. (A nice middle path:
  set one campaign up once with `setup_show.sh`, then fork *that* for free forever.)
- **The source must be fully rendered** (portraits + soundtrack + trailer); a fork
  inherits any incompleteness.
- **`allowNewCharacters` is not copied** (it resets to the default) and the fork is
  forced into `pro` mode — both fine for the upload step, but patch
  `allowNewCharacters` afterward if your show needs new faces per episode.
- You still author your own `show.env` (`CAST_ALIASES`, `STORY_*`) and story source
  so they emit the inherited cast's names.

---

## Step 4 — Generate the next story

```bash
./show/showrunner/prepare.sh show/MyShow
```

Writes `show/MyShow/stories/<UTC-timestamp><STORY_SUFFIX>`. The compute path is
deterministic and free; the prompt path calls `claude` (needs your Anthropic key).

---

## Step 5 — Upload + render the episode

Pick **one** port — behaviour is identical:

```bash
# shell — needs only curl + jq
./show/showrunner/upload_to_yakyak.sh --show show/MyShow

# JS — run `npm install` in show/showrunner/ once first
node show/showrunner/upload_to_yakyak.js --show show/MyShow

# Python — run `pip install -r show/showrunner/requirements.txt` once first
python3 show/showrunner/upload_to_yakyak.py --show show/MyShow
```

The script finds the next empty episode slot, stamps your story onto it, regenerates
the screenplay, waits for every scene to render, adds the soundtrack, exports the final
render, and prints the video URL. Add `--post --yes` to also publish to every social
network linked to the campaign — that's **irreversible**, so it's off by default and
requires the explicit `--yes`.

You can watch the result in the dashboard, or fetch it:
`GET /workflow/get-campaign/<campaignId>`.

---

## Recap

```bash
export YAKYAK_PAT="yy_live_..."
cp -r show/LuckyDay show/MyShow      # then edit show.env + campaign.import.json + compute.js/prompt.md
./show/showrunner/setup_show.sh   show/MyShow   # once
./show/showrunner/prepare.sh      show/MyShow   # per episode
./show/showrunner/upload_to_yakyak.sh --show show/MyShow   # per episode
```

Repeat steps 4–5 whenever you want a new episode. To automate it later, wire those two
commands into any scheduler you like (a local cron, a GitHub Action with `YAKYAK_PAT`
as a secret, etc.) — the scripts are non-interactive-safe.

---

## How your fork gets engine bug fixes

The showrunner is split into two layers, and that split is what determines how
upstream fixes reach you:

- **Engine** (`upload_to_yakyak.{py,js,sh}`, `story-format.js`, `prepare.sh`,
  `setup_show.sh`, `ensure_owned_campaign.sh`) — the show-agnostic machinery. This
  is baked **into** the Docker images.
- **Show content** (`show.env`, `prompt.md`, `compute.*`, `campaign.import.json`) —
  everything specific to *your* show. CI mounts this from your checkout **over** the
  baked copy at runtime, so your show dirs always come from your repo, never the image.

How you receive a fix depends on how you run the engine:

### If you run via CI / Docker (recommended)

You get engine fixes **automatically, without touching your repo**. The scheduled
[`run-shows.yml`](../../.github/workflows/run-shows.yml) pulls the engine images from
upstream's Docker Hub namespace (`yakyaksdk/showrunner-{py,js,sh,prepare}`) on every
run — anonymously, so you need no Docker credentials. When upstream ships a fix and
publishes a new image, your next scheduled run does a fresh `docker pull` and is now
running the patched engine. Because your checkout only supplies show content (which is
yours anyway), there is nothing to merge and no conflict to resolve.

Two things to know:

- **`latest` auto-tracks; a pinned tag freezes.** `run-shows.yml` pulls the tag in the
  `SHOWRUNNER_TAG` repo variable, defaulting to `latest`. Leaving it on `latest` means
  you ride upstream fixes as they publish. Pinning it to a specific version gives you
  reproducible, roll-back-able runs — but then you stay on that engine until you bump
  the pin yourself. You can't have both auto-patching and pinned reproducibility from
  the same knob; choose per the trade-off you want.
- **Upstream publishes manually.** `:latest` reflects the last time upstream published
  an image, not the latest upstream commit — so a just-merged fix reaches you only once
  it's been published.

### If you run locally from your checkout (no Docker)

The Docker channel doesn't apply — you're running the engine scripts straight from your
files. Your only fix channel is **merging from upstream** (`git pull` / merge the
upstream remote). As long as you've customized *only* your show dirs under `show/` and
left the engine (`show/showrunner/**`) untouched, those merges stay clean.

### Don't edit the engine in your fork

If you modify `show/showrunner/**` in your checkout, you break both channels: Docker
runs silently ignore your edits (the baked image wins for engine code — only show dirs
are mounted over it), and you'll hit merge conflicts pulling upstream fixes. Keep all
your customization in your show directory; if you think the engine itself needs a
change, it's worth proposing upstream so every fork benefits.

# showrunner — the show-agnostic YakYak engine

> **Forked the repo and want to ship your own episodes?** Start with
> [`FORKING.md`](./FORKING.md) — the shortest path from fork to a rendered episode,
> with and without AI tools.

`showrunner/` is the shared engine that turns a prepared **story-markdown** file
into a rendered (and optionally posted) YakYak episode. It is **show-agnostic**:
everything specific to a show — campaign, cast, soundtrack, cadence — lives in
that show's `show.env`, selected at runtime with `--show`.

Breaking Bricks News is just the first show. See
[`../BreakingBricksNews/docs/alternative_setups.md`](../BreakingBricksNews/docs/alternative_setups.md)
for 10 more, and [`../BreakingBricksNews/docs/yakyak_upload_usage.md`](../BreakingBricksNews/docs/yakyak_upload_usage.md)
for the full flag/cron/Docker/CI reference.

## Why this layout (no duplication)

```
show/
  showrunner/                 # the engine — ONE copy, three language ports
    upload_to_yakyak.py|js|sh # the uploader (pick any port; behaviour is identical)
    story-format.js           # shared story-markdown → payload converters
    prepare.sh                # generic story-sourcing step (compute or prompt)
    plan_due_shows.sh         # CI: which shows are due today → matrix
    Dockerfile.{py,js,sh}     # engine images
    Dockerfile.prepare        # prepare image (adds the `claude` CLI for prompt shows)
  BreakingBricksNews/         # a SHOW = config + sourcing + media (no scripts)
    show.env                  # all the per-show settings
    prompt.md                 # creative brief for `claude -p` (prompt-kind sourcing)
    stories/  assets/  images/  docs/
  Horoscopes/                 # a COMPUTED example show (no model needed)
    show.env
    compute.py                # deterministic story generator
    stories/
```

The three language ports exist on purpose — this is an **SDK demo**. They read
the same `show.env` and produce identical results.

## show.env reference

`KEY="value"`, shell-style. **Comments must be on their own line** (the loaders
do not strip trailing inline comments).

| Key | Required | Default | Meaning |
| --- | --- | --- | --- |
| `CAMPAIGN_ID` | yes | — | Target campaign uuid. |
| `SOUNDTRACK_AUDIO_PATH` | no | (picker) | audioPath set on the movie; verified on CDN. Empty → fall back to `/workflow/available-soundtracks`. |
| `VOLUME` | no | `45` | Soundtrack volume % (0–100). |
| `MIN_TOKEN_BALANCE` | no | `2000` | Abort threshold for the token-balance gate. |
| `STORY_GLOB` | no | `*_latest_update.md` | Glob used to find the freshest story in `stories/`. |
| `CAST_ALIASES` | no | (empty) | `"Full Name=Alias,Other=Alias"`, substring→alias in priority order. Empty → "first name". |
| `PAT_ENV_KEY` | no | `YAKYAK_PAT` | Which env var holds the PAT. Legacy `YAKYAK_BB_PAT` is always honored as a fallback. |
| `PREPARE_KIND` | no | auto | `compute` (run `compute.*`) or `prompt` (run `prompt.md` via `claude`). Auto-detected if unset. |
| `STORY_SUFFIX` | no | `_latest_update.md` | Filename suffix `prepare.sh` writes (`<UTC-ts><suffix>`). Keep it consistent with `STORY_GLOB`. |
| `REQUIRES_MODEL` | no | `false` | CI hint: prepare needs `ANTHROPIC_API_KEY` + the prepare image. |
| `CADENCE` | no | `daily` | CI scheduling: `daily` or `weekly` (weekly = Sundays). |
| `ENGINE` | no | `py` | Which port CI runs for this show (`py`/`js`/`sh`). |
| `ENABLED` | no | `true` | Set `false` to skip in scheduled runs. |
| `POST` | no | `false` | Set `true` to PUBLISH to social on scheduled runs (irreversible). Default render-only. |

### The story-markdown contract

`prepare.sh` (or any sourcing you write) must emit:

```markdown
## Headlines we drew from:
- <bullet>            ← becomes the social caption

## Scene 1 — <title>
**Leading character:** <name>      ← mapped via CAST_ALIASES
**Dialog:** "<one line, no trailing period>"
<prose: the visual brief>
... repeat per scene ...
```

## Running locally

```bash
# 1) source a story into <show>/stories/
./prepare.sh ../BreakingBricksNews        # prompt-kind → needs `claude`
./prepare.sh ../Horoscopes                # compute-kind → deterministic, no model

# 2) upload + render (+ optionally post). Pick any port — same behaviour:
./upload_to_yakyak.py --show ../Horoscopes
node upload_to_yakyak.js --show ../Horoscopes
./upload_to_yakyak.sh  --show ../Horoscopes --post --yes
```

PAT resolution: process env `$YAKYAK_PAT` (or the show's `PAT_ENV_KEY`), else
`<repo>/e2e/.env.bb`. The file is optional when the env var is set.

## Adding a new show

1. Create the campaign in the app; note its uuid + (optional) soundtrack audioPath.
2. `mkdir show/<Show> && touch show/<Show>/stories/.gitkeep`.
3. Write `show/<Show>/show.env` (copy an existing one; set `CAMPAIGN_ID`,
   `CAST_ALIASES`, `CADENCE`, `ENGINE`, `PREPARE_KIND`, `STORY_SUFFIX`/`STORY_GLOB`).
4. Add the sourcing:
   - **compute** show → `compute.py` / `compute.sh` / `compute.js` that writes
     `$OUTPUT_FILE` (env vars `OUTPUT_FILE`, `TIMESTAMP`, `SHOW_DIR` are provided).
   - **prompt** show → `prompt.md` with `{{OUTPUT_FILE}}` / `{{TIMESTAMP}}`
     placeholders, driven by `claude -p` (WebFetch + Write).
5. Done — the engine, Docker images, and CI matrix pick it up automatically. No
   engine code changes.

## One-time campaign setup (`setup_show.sh`)

If a show ships a `campaign.import.json` (config + cast roster, no rendered
assets — see `show/Horoscopes/`), `setup_show.sh` does the whole first-time
setup from just a PAT:

```bash
YAKYAK_PAT=yy_live_... ./show/showrunner/setup_show.sh show/Horoscopes
```

It is **idempotent** — safe to re-run and to call from CI:

1. Decodes the PAT's userId.
2. **Ensures the campaign exists**: uses `show.env`'s `CAMPAIGN_ID` if set; else
   finds an existing campaign by **name** (`list-campaign/:userId`, so re-runs
   never duplicate); else imports `campaign.import.json`. `--force` imports a fresh one.
   Writes the resolved `CAMPAIGN_ID` into `show.env`.
3. **Cast portraits**: generates only the characters missing an image
   (`gen-movie-cast-image`) and polls `get-cast` until all exist. Reused by every
   episode via `copyCastFromSource`.
4. **Soundtrack** (skip with `--no-soundtrack`): if none is set, composes one AI
   track from `MUSIC_PROMPT` (or the API's `suggested-music-prompt`) via
   `gen-movie-soundtrack`, polls `audio-tracks`, and writes the resulting
   `SOUNDTRACK_AUDIO_PATH` into `show.env` — reused by every episode.

`YAKYAK_API_URL` defaults to `https://api.yakyak.ai`. Already-done paid steps
(cast images, soundtrack) are skipped on re-run.

> Cast images and AI soundtrack are paid/slow. A show that *uploads* its own
> portraits/track instead (cookbook lessons 3 & 7:
> `upload-cast-character-image` / `upload-soundtrack-audio`) skips generation.

**CI self-heal.** `run-shows.yml` runs `setup_show.sh` automatically when a show
has a `campaign.import.json` but no committed `CAMPAIGN_ID`, then mounts the
checked-out `show.env` into the engine container (overriding the baked copy). So
either commit `show.env` with the ids after a local setup (recommended — gates the
paid steps behind a human), or let CI self-heal on first run.

## Docker

Build from the **repo root** (Dockerfile `COPY` paths assume it):

```bash
docker build -f show/showrunner/Dockerfile.py -t yakyak/showrunner-py .
docker run --rm -e YAKYAK_PAT \
  -v "$PWD/show/Horoscopes/stories:/app/show/Horoscopes/stories" \
  yakyak/showrunner-py --show show/Horoscopes
```

`Dockerfile.prepare` adds the `claude` CLI for prompt-kind shows; compute shows
prepare in the plain engine images.

## CI (GitHub Actions)

- **`.github/workflows/build-showrunner.yml`** — on changes under
  `show/showrunner/**`, builds the four images and pushes them to ECR
  (`426496910306.dkr.ecr.us-west-2.amazonaws.com/yakyak/showrunner-*`) tagged by
  git SHA + `latest`.
- **`.github/workflows/run-shows.yml`** — daily cron + manual dispatch. `plan`
  reads every `show.env` via `plan_due_shows.sh` and emits a matrix of due shows;
  `run` pulls the pinned image and, per show, prepares → uploads → renders.
  **Render-only by default**; pass the `post` dispatch input to publish.

Required CI secrets/vars:

| Name | Kind | Purpose |
| --- | --- | --- |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | secret | ECR push/pull (existing) |
| `YAKYAK_PAT` | secret | single shared PAT for all demo shows |
| `ANTHROPIC_API_KEY` | secret | only for prompt-kind shows' prepare step |
| `SHOWRUNNER_TAG` | variable | pin runs to a known-good image SHA (default `latest`) |

## Release process

### SDK (when the API changes)
1. Run `publish-sdks.yml` with the new version (e.g. `0.0.8`)
2. Update `requirements.txt` and `package.json` to that version
3. Run `npm install` in `show/showrunner/` to regenerate `package-lock.json`
4. Commit + push all three files

### Docker images (after SDK pins are updated, or any showrunner code change)
1. Get the next version — no need to open Docker Hub, just run:
   ```bash
   curl -s "https://hub.docker.com/v2/repositories/yakyaksdk/showrunner-prepare/tags/?page_size=10&ordering=-last_updated" \
     | python3 -c "import json,sys; tags=[t['name'] for t in json.load(sys.stdin)['results'] if t['name']!='latest']; print('latest:', tags[0])"
   ```
2. Make sure the SDK pin changes are pushed first — the Docker build COPYs `requirements.txt` and `package-lock.json` from the repo
3. Run `publish-dockerhub.yml` with the new version

## Two non-interactive gates (cron/CI)

Both ports are no-TTY safe. Unattended:
- token balance `< MIN_TOKEN_BALANCE` → **aborts** (keep it topped up);
- `--post` requires `--yes` or it refuses to post.

#!/usr/bin/env bash
#
# upload_to_yakyak.sh — push a prepared story into the next available episode
# slot of a YakYak campaign on yakyak.ai, then wait for scene generation, attach
# the soundtrack, trigger the final render, wait for it to finish, and
# (optionally) post to social.
#
# Show-AGNOSTIC engine. All show-specific settings (campaign, cast, soundtrack,
# volume, …) live in <showDir>/show.env and are selected with --show. BBN is just
# one show; see show/showrunner/README.md + docs/alternative_setups.md.
#
# Usage:
#   ./upload_to_yakyak.sh --show <showDir> [campaignId] [storyFile] [flags]
#
# Flags:
#   --show <showDir>         REQUIRED (or $SHOW_DIR). Dir with show.env + stories/.
#   --post                   Post the rendered episode to every social network
#                            linked to the campaign (NOT default).
#   --post-only              Skip upload + render entirely; just post an
#                            already-rendered episode. Implies --post. Target is
#                            the MOST RECENTLY RENDERED episode in the campaign
#                            (by render time), unless --movie is also passed.
#   --movie <movieId>        Explicit movie ID; overrides next-episode picker
#                            (works in both default and --post-only modes).
#   --volume <N>             Soundtrack volume percentage (overrides show.env).
#   --soundtrack <audioPath> Override show.env SOUNDTRACK_AUDIO_PATH. Set directly
#                            on the movie (verified reachable on CDN first); it
#                            does NOT need to be in /workflow/available-soundtracks.
#   --skip-finalize          Stop after kicking off screenplay regen (skip the
#                            wait-for-scenes + soundtrack + render steps).
#   -y, --yes                Skip the pre-post confirmation prompt (for cron /
#                            unattended runs). Without it, posting requires a
#                            TTY confirmation of the chosen episode + networks.
#   -h, --help               Show this help.
#
# Cron / Docker / CI:
#   Non-interactive-safe (no TTY -> deterministic). For unattended runs, prebuilt
#   per-language Docker images, and the GitHub Actions matrix, see
#   docs/yakyak_upload_usage.md and docs/alternative_setups.md.
#
# Config (per show, from <showDir>/show.env; CLI overrides where applicable):
#   CAMPAIGN_ID, SOUNDTRACK_AUDIO_PATH, VOLUME, MIN_TOKEN_BALANCE, STORY_GLOB,
#   CAST_ALIASES ("Full Name=Alias,…"), PAT_ENV_KEY (default YAKYAK_PAT).
#
# Required env (process env, or e2e/.env.bb if present):
#   YAKYAK_PAT            Personal Access Token ("yy_live_…") with the scopes for
#                         the full flow. Override the var name per show with
#                         PAT_ENV_KEY; legacy YAKYAK_BB_PAT is still honored.
# Optional:
#   YAKYAK_API_URL        (defaults to https://api.yakyak.ai)
#   YAKYAK_CDN_URL        (defaults to https://cdn.yakyak.ai)
#
# What it does:
#   1. Token-balance check (>= MIN_TOKEN_BALANCE). Warn+prompt on TTY, abort non-interactive.
#   2. Use the PAT as the bearer token; decode its embedded JWT to get
#      the userId (no login round-trip).
#   3. GET  /workflow/get-campaign/<campaignId>
#   4. Find lowest-(season,episode) movie whose renderedMovieUrl is empty (not
#      yet rendered). If none and the campaign has movies, POST
#      /workflow/create-new-season; if the campaign has NO movies at all (fresh/
#      forked, no slots yet), POST /workflow/gen-movie-season on the template
#      instead (create-new-season can't bootstrap an empty campaign). Then poll
#      until episodes appear.
#   5. POST /workflow/set-movie-metadata (movieId + story-file body as description)
#   6. POST /workflow/update-movie-social-description (caption + title)
#   7. POST /workflow/gen-movie-screenplay (kick the regen pipeline)
#   8. Poll /workflow/get-movie/<movieId> until every scene's
#      sceneBurnSubtitle.status == "completed".
#   9. POST /workflow/set-soundtrack-audio    (configured audioPath, set
#      directly after verifying it's reachable on the CDN)
#  10. POST /workflow/set-soundtrack          (volumePercentage)
#  11. POST /workflow/export-render           (kick concat + soundtrack)
#  12. Poll /workflow/render-history/<movieId> until items[0].finishedAt
#      appears (the rendered MP4 is now on CDN).
#  13. If --post: POST /social/post-movie/<movieId>/<connectedNetworkId> for
#      every network in /social/campaign-links/<campaignId>.
#
# No Chrome is needed at runtime; only curl + jq.

set -euo pipefail

# ---- defaults / config -----------------------------------------------------

# Show-agnostic engine: per-show settings live in <showDir>/show.env (loaded at
# runtime). The values below are only *fallbacks* for absent keys.
FALLBACK_VOLUME=45
FALLBACK_MIN_TOKEN_BALANCE=2000
FALLBACK_STORY_GLOB="*_latest_update.md"
# Single shared PAT by default; a show may override via PAT_ENV_KEY. Legacy
# YAKYAK_BB_PAT is honored so an existing e2e/.env.bb keeps working.
DEFAULT_PAT_ENV_KEY="YAKYAK_PAT"
LEGACY_PAT_ENV_KEY="YAKYAK_BB_PAT"
# Scene-generation poll: every 15s for up to 30 min. The full pipeline (cast,
# image, voice, animate, subtitle, burn) for ~11 scenes typically completes
# inside 10-15 min.
SCENE_POLL_INTERVAL=15
SCENE_POLL_MAX=120
# Render poll: every 5s up to ~15 min. The export-render concat job is
# typically ~30-60s once it picks up, but Creatomate queue depth can push it
# out a few minutes.
RENDER_POLL_INTERVAL=5
RENDER_POLL_MAX=180

# ---- args ------------------------------------------------------------------

POST_TO_SOCIAL=false
POST_ONLY=false
SKIP_FINALIZE=false
ASSUME_YES=false
MOVIE_ID_OVERRIDE=""
SHOW_DIR_ARG="${SHOW_DIR:-}"
VOLUME_ARG=""        # empty => take from show.env
SOUNDTRACK_ARG=""    # empty => take from show.env
POS_ARGS=()

show_help() {
  # Print the banner from "Usage:" through the "-h, --help" line (robust to
  # line-number shifts in the header).
  sed -n '/^# Usage:/,/^#   -h, --help/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --post)            POST_TO_SOCIAL=true; shift ;;
    --post-only)       POST_ONLY=true; POST_TO_SOCIAL=true; shift ;;
    --skip-finalize)   SKIP_FINALIZE=true; shift ;;
    -y|--yes)          ASSUME_YES=true; shift ;;
    --show)
      [[ $# -ge 2 ]] || { echo "error: --show needs a value" >&2; exit 1; }
      SHOW_DIR_ARG="$2"
      shift 2 ;;
    --movie)
      [[ $# -ge 2 ]] || { echo "error: --movie needs a value" >&2; exit 1; }
      MOVIE_ID_OVERRIDE="$2"
      shift 2 ;;
    --volume)
      [[ $# -ge 2 ]] || { echo "error: --volume needs a value" >&2; exit 1; }
      VOLUME_ARG="$2"
      shift 2 ;;
    --soundtrack)
      [[ $# -ge 2 ]] || { echo "error: --soundtrack needs a value" >&2; exit 1; }
      SOUNDTRACK_ARG="$2"
      shift 2 ;;
    -h|--help) show_help; exit 0 ;;
    --) shift; while [[ $# -gt 0 ]]; do POS_ARGS+=("$1"); shift; done ;;
    -*) echo "error: unknown flag '$1' (try --help)" >&2; exit 1 ;;
    *)  POS_ARGS+=("$1"); shift ;;
  esac
done

if [[ "$POST_ONLY" == true && "$SKIP_FINALIZE" == true ]]; then
  echo "error: --post-only and --skip-finalize are mutually exclusive" >&2
  exit 1
fi
if [[ -z "$SHOW_DIR_ARG" ]]; then
  echo "error: --show <showDir> is required (or set \$SHOW_DIR)." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # show/showrunner
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"                  # repo root
SHOW_DIR="$(cd "$SHOW_DIR_ARG" 2>/dev/null && pwd || true)"
if [[ -z "$SHOW_DIR" || ! -d "$SHOW_DIR" ]]; then
  echo "error: --show dir not found: $SHOW_DIR_ARG" >&2
  exit 1
fi
STORIES_DIR="$SHOW_DIR/stories"
ENV_FILE="$REPO_ROOT/e2e/.env.bb"

# ---- load per-show config (show.env) --------------------------------------
SHOW_ENV="$SHOW_DIR/show.env"
if [[ ! -f "$SHOW_ENV" ]]; then
  echo "error: no show config at $SHOW_ENV (see show/showrunner/README.md)." >&2
  exit 1
fi
set -o allexport
# shellcheck disable=SC1090
source "$SHOW_ENV"
set +o allexport

# CLI > show.env > fallback.
CAMPAIGN_ID="${POS_ARGS[0]:-${CAMPAIGN_ID:-}}"
if [[ -z "$CAMPAIGN_ID" ]]; then
  echo "error: CAMPAIGN_ID not set in $SHOW_ENV (and none on CLI)." >&2
  exit 1
fi
STORY_FILE_ARG="${POS_ARGS[1]:-}"
VOLUME_PERCENTAGE="${VOLUME_ARG:-${VOLUME:-$FALLBACK_VOLUME}}"
SOUNDTRACK_AUDIO_PATH="${SOUNDTRACK_ARG:-${SOUNDTRACK_AUDIO_PATH:-}}"
MIN_TOKEN_BALANCE="${MIN_TOKEN_BALANCE:-$FALLBACK_MIN_TOKEN_BALANCE}"
STORY_GLOB="${STORY_GLOB:-$FALLBACK_STORY_GLOB}"
CAST_ALIASES="${CAST_ALIASES:-}"
PAT_ENV_KEY="${PAT_ENV_KEY:-$DEFAULT_PAT_ENV_KEY}"

if ! [[ "$VOLUME_PERCENTAGE" =~ ^[0-9]+$ ]] || (( VOLUME_PERCENTAGE < 0 || VOLUME_PERCENTAGE > 100 )); then
  echo "error: volume must be an integer between 0 and 100 (got '$VOLUME_PERCENTAGE')" >&2
  exit 1
fi
echo "→ Show: $(basename "$SHOW_DIR")  (campaign $CAMPAIGN_ID)"

# ---- prerequisites --------------------------------------------------------

for bin in curl jq; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "error: '$bin' not found in PATH" >&2
    exit 1
  fi
done

# ---- credentials ----------------------------------------------------------

# PAT from the process env (cron/CI) or e2e/.env.bb (local). The file is OPTIONAL:
# if the env var is already set we don't need it. Try the show's configured key
# first, then the legacy YAKYAK_BB_PAT so existing setups keep working.
if [[ -f "$ENV_FILE" ]]; then
  set -o allexport
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +o allexport
fi

PAT="${!PAT_ENV_KEY:-}"
[[ -z "$PAT" ]] && PAT="${!LEGACY_PAT_ENV_KEY:-}"
API="${YAKYAK_API_URL:-https://api.yakyak.ai}"

if [[ -z "$PAT" ]]; then
  echo "error: no PAT found. Set \$$PAT_ENV_KEY in the environment, or put it in $ENV_FILE." >&2
  exit 1
fi
if [[ "$PAT" != yy_live_* ]]; then
  echo "error: \$$PAT_ENV_KEY does not look like a PAT (expected 'yy_live_…')" >&2
  exit 1
fi

# ---- pick story file ------------------------------------------------------
# Only needed for upload+render. --post-only doesn't touch the story.

STORY_FILE=""
if [[ "$POST_ONLY" != true ]]; then
  if [[ -n "$STORY_FILE_ARG" ]]; then
    STORY_FILE="$STORY_FILE_ARG"
  else
    if [[ ! -d "$STORIES_DIR" ]]; then
      echo "error: no stories dir at $STORIES_DIR. Run showrunner/prepare.sh $SHOW_DIR first, or pass a path." >&2
      exit 1
    fi
    # shellcheck disable=SC2086 — STORY_GLOB is an intentional glob pattern.
    STORY_FILE="$(/bin/ls -1 "$STORIES_DIR"/$STORY_GLOB 2>/dev/null | tail -1 || true)"
    if [[ -z "$STORY_FILE" ]]; then
      echo "error: no $STORY_GLOB files in $STORIES_DIR" >&2
      exit 1
    fi
  fi

  if [[ ! -f "$STORY_FILE" ]]; then
    echo "error: story file not found: $STORY_FILE" >&2
    exit 1
  fi

  STORY_BYTES="$(wc -c <"$STORY_FILE" | tr -d ' ')"
  echo "→ Story file: $STORY_FILE ($STORY_BYTES bytes)"
fi

# ---- authenticate (PAT) ----------------------------------------------------
# The PAT is sent verbatim as the bearer token ("Authorization: Bearer yy_live_…");
# the API strips the prefix and verifies the embedded JWT. That JWT's payload
# carries the userId in its `id` claim, so we decode it locally instead of a
# login round-trip (there's no /users/me endpoint).

# base64url-decode the JWT payload (middle segment) and emit its `.id` claim.
decode_pat_user_id() {
  local pat="$1" jwt payload pad
  jwt="${pat#yy_live_}"
  payload="${jwt#*.}"      # drop header.
  payload="${payload%%.*}" # drop .signature
  payload="${payload//-/+}"
  payload="${payload//_//}"
  pad=$(( ${#payload} % 4 ))
  (( pad == 2 )) && payload="${payload}=="
  (( pad == 3 )) && payload="${payload}="
  printf '%s' "$payload" | base64 -d 2>/dev/null | jq -r '.id // empty' 2>/dev/null
}

TOKEN="$PAT"
AUTH_H="Authorization: Bearer $TOKEN"
USER_ID="$(decode_pat_user_id "$PAT")"
if [[ -z "$USER_ID" ]]; then
  echo "error: could not extract userId from YAKYAK_BB_PAT (malformed token?)" >&2
  exit 1
fi
echo "→ Authenticated via PAT (userId $USER_ID)"

# ---- token balance gate ---------------------------------------------------
# Posting doesn't burn tokens, so the gate only fires on upload+render runs.

if [[ "$POST_ONLY" != true ]]; then
  echo "→ GET /users/$USER_ID  (token-balance check)"
  USER_RESP="$(curl -fsS -H "$AUTH_H" "$API/users/$USER_ID")"
  TOKEN_BALANCE="$(jq -r '.tokenBalance // 0' <<<"$USER_RESP")"
  echo "  tokenBalance=$TOKEN_BALANCE  (minimum $MIN_TOKEN_BALANCE)"

  if (( TOKEN_BALANCE < MIN_TOKEN_BALANCE )); then
    echo "⚠️  Insufficient tokens: $TOKEN_BALANCE < $MIN_TOKEN_BALANCE"
    if [[ -t 0 ]]; then
      read -r -p "    Continue anyway? [y/N] " yn
      case "$yn" in
        [Yy]*) echo "    proceeding at user's request" ;;
        *)     echo "    aborted by user"; exit 1 ;;
      esac
    else
      echo "    non-interactive (no TTY) → aborting." >&2
      exit 1
    fi
  fi
fi

# ---- helpers --------------------------------------------------------------

fetch_campaign() {
  curl -fsS -H "$AUTH_H" "$API/workflow/get-campaign/$CAMPAIGN_ID"
}

# Switch the campaign's mode (basic|pro) via the REST API. 'basic' makes the
# render pipeline auto-chain (screenplay→cast→scenes→image→movie→subtitle→burn→
# concat→soundtrack); 'pro' stops after the screenplay for manual UI stepping.
# This script needs 'basic' to run unattended — in 'pro' the scenes sit at
# 'waiting' forever and the scene-poll below times out. shouldAutoChain() on the
# server re-checks the mode at EVERY step, so the campaign must stay 'basic' for
# the whole render; we only restore 'pro' on exit (see restore_pro_mode).
switch_campaign_mode() {
  local mode="$1"
  curl -fsS -X POST "$API/workflow/switch-campaign-mode" \
    -H "$AUTH_H" -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg c "$CAMPAIGN_ID" --arg m "$mode" '{campaignId:$c, mode:$m}')" \
    >/dev/null
}

# Switch to basic and CONFIRM it took. switch-campaign-mode is OWNER-LOCKED: a
# non-owner PAT 403s, leaving the campaign in 'pro' so the scene auto-chain never
# fires and the poll below hangs forever. The 200 response echoes the new mode,
# so assert it == basic (a 403 yields an empty body → mismatch). Retries once.
ensure_basic_mode() {
  local resp mode attempt
  for attempt in 1 2; do
    resp="$(curl -fsS -X POST "$API/workflow/switch-campaign-mode" \
      -H "$AUTH_H" -H 'Content-Type: application/json' \
      --data "$(jq -nc --arg c "$CAMPAIGN_ID" '{campaignId:$c, mode:"basic"}')" 2>/dev/null || true)"
    mode="$(jq -r '.mode // empty' <<<"$resp" 2>/dev/null || true)"
    [[ "$mode" == "basic" ]] && return 0
  done
  return 1
}

# Nudge a movie's pipeline to advance its next incomplete step (mode- and
# season-independent). Re-kicks a render that stalled or had a step fail mid-run;
# the server re-dispatches/resumes from resolved inputs. Best-effort.
resume_movie() {
  curl -fsS -X POST "$API/workflow/resume" \
    -H "$AUTH_H" -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg m "$1" '{movieId:$m}')" \
    >/dev/null 2>&1 || true
}

# EXIT trap: return the campaign to 'pro' so it goes back to its manual-editing
# default once the run ends — on success OR error. Only fires if we actually
# switched to 'basic'. The script blocks on render completion, so by the time it
# exits the pipeline is finished or genuinely stuck; either way restoring 'pro'
# is correct. Best-effort (|| true) so a restore failure never masks the real
# exit status.
restore_pro_mode() {
  if [[ "${SWITCHED_TO_BASIC:-false}" == true ]]; then
    echo "→ Restoring campaign mode → pro" >&2
    switch_campaign_mode pro || echo "⚠️  Failed to restore pro mode — set it manually if needed" >&2
  fi
}

# Selects the lowest-(season,episode) movie whose renderedMovieUrl is empty
# (i.e. not yet rendered). NOTE: do NOT also gate on status != 'completed' —
# in this campaign every episode is status 'completed' (that field tracks episode
# *generation*, not rendering), so adding it makes the picker match nothing and
# wrongly spin up a new season while free slots (e.g. S3E7) exist.
# Emits "<movieId>|<season>|<episode>|<title>" or empty string when none.
pick_next_episode() {
  local campaign_json="$1"
  jq -r '
    [.campaign.movies[]
      | select((.renderedMovieUrl // "") == "")]
    | sort_by(.season, .episode)
    | first
    | if . == null then ""
      else "\(.id)|\(.season)|\(.episode)|\(.title)"
      end
  ' <<<"$campaign_json"
}

# Selects the MOST RECENTLY RENDERED movie (by actual render time), among those
# with a non-empty renderedMovieUrl. Used by --post-only when no explicit
# --movie was passed.
#
# We deliberately do NOT sort by (season, episode): season numbers are not
# chronological in this campaign. Seeded demo seasons (e.g. S8E1, S9E1, rendered
# back on 2026-05-19) sit numerically ABOVE the live production line (currently
# season 3), so a (season,episode) max picks a stale demo — that's exactly how
# `--post-only` posted S9E1 instead of the freshly-minted S3E6.
#
# Render time isn't in /workflow/get-campaign, so for each rendered movie we read
# /workflow/render-history/<movieId> items[0].finishedAt (ordered desc, backfilled
# for pre-rollout movies) and keep the newest. ISO-8601 UTC strings compare
# correctly with a lexicographic test. Emits the usual pipe-separated shape, or
# empty string when none. Progress goes to stderr to keep stdout = the result.
pick_latest_rendered() {
  local campaign_json="$1"
  local rendered
  rendered="$(jq -r '
    [.campaign.movies[] | select((.renderedMovieUrl // "") != "")]
    | sort_by(.season, .episode)
    | .[]
    | "\(.id)|\(.season)|\(.episode)|\(.title)"
  ' <<<"$campaign_json")"

  [[ -z "$rendered" ]] && { echo ""; return; }

  local best_line="" best_ts="" line mid rh ts
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    mid="${line%%|*}"
    rh="$(curl -fsS -H "$AUTH_H" "$API/workflow/render-history/$mid" 2>/dev/null || true)"
    ts="$(jq -r '.items[0].finishedAt // empty' <<<"$rh" 2>/dev/null || true)"
    if [[ -z "$ts" ]]; then
      echo "  …skipping ${line#*|} (no render-history finishedAt)" >&2
      continue
    fi
    if [[ -z "$best_ts" || "$ts" > "$best_ts" ]]; then
      best_ts="$ts"
      best_line="$line"
    fi
  done <<<"$rendered"

  [[ -n "$best_ts" ]] && echo "  newest render: $best_ts" >&2
  echo "$best_line"
}

# Looks up a movie by id inside the campaign and emits the same pipe-separated
# shape. Empty string if not found.
lookup_movie_in_campaign() {
  local campaign_json="$1" mid="$2"
  jq -r --arg id "$mid" '
    [.campaign.movies[] | select(.id == $id)] | first
    | if . == null then ""
      else "\(.id)|\(.season)|\(.episode)|\(.title)"
      end
  ' <<<"$campaign_json"
}

# ---- ensure auto-chain: basic during the run, pro restored on exit ---------
# --post-only doesn't render, so it doesn't need basic mode (skip the flip).
SWITCHED_TO_BASIC=false
if [[ "$POST_ONLY" != true ]]; then
  if ensure_basic_mode; then
    SWITCHED_TO_BASIC=true
    echo "→ Campaign mode → basic (auto-chain enabled for this run)"
    trap restore_pro_mode EXIT
  else
    echo "error: could not enable basic mode — campaign still pro; check that the PAT owns campaign $CAMPAIGN_ID" >&2
    exit 1
  fi
fi

# ---- pick target episode --------------------------------------------------

echo "→ Fetching campaign $CAMPAIGN_ID"
CAMPAIGN_JSON="$(fetch_campaign)"
TOTAL_MOVIES="$(jq -r '.campaign.movies | length' <<<"$CAMPAIGN_JSON")"
echo "  campaign has $TOTAL_MOVIES movie(s)"

if [[ -n "$MOVIE_ID_OVERRIDE" ]]; then
  NEXT="$(lookup_movie_in_campaign "$CAMPAIGN_JSON" "$MOVIE_ID_OVERRIDE")"
  if [[ -z "$NEXT" ]]; then
    echo "error: --movie $MOVIE_ID_OVERRIDE not found in campaign $CAMPAIGN_ID" >&2
    exit 1
  fi
elif [[ "$POST_ONLY" == true ]]; then
  echo "→ Finding most recently rendered episode (checking render-history per rendered movie)…"
  NEXT="$(pick_latest_rendered "$CAMPAIGN_JSON")"
  if [[ -z "$NEXT" ]]; then
    echo "error: --post-only: no movie in campaign has a renderedMovieUrl" >&2
    exit 1
  fi
else
  NEXT="$(pick_next_episode "$CAMPAIGN_JSON")"

  if [[ -z "$NEXT" ]]; then
    # Two distinct "no episode to fill" cases:
    #  - movies exist → a season exists but every slot is rendered;
    #    create-new-season adds the next season (needs an existing episode).
    #  - 0 movies → a fresh/forked campaign has NO numbered slots yet.
    #    create-new-season can't bootstrap from nothing (it 500s), so seed
    #    season 1 from the template via gen-movie-season (as setup_show.sh does).
    #    get-campaign filters the template out, so it's found via list-campaign.
    if [[ "$TOTAL_MOVIES" -gt 0 ]]; then
      echo "→ No available episode in current season(s); creating new season"
      CREATE_BODY="$(jq -nc --arg c "$CAMPAIGN_ID" '{campaignId:$c}')"
      CREATE_RESP="$(curl -fsS -X POST -H "$AUTH_H" -H 'Content-Type: application/json' \
        --data "$CREATE_BODY" \
        "$API/workflow/create-new-season")"
      echo "  $CREATE_RESP"
    else
      echo "→ Campaign has no episode slots; bootstrapping season 1 from template"
      TEMPLATE_MOVIE_ID="$(curl -fsS -H "$AUTH_H" "$API/workflow/list-campaign/$USER_ID" \
        | jq -r --arg id "$CAMPAIGN_ID" '.campaigns[]? | select(.id == $id) | .template.id // empty')"
      [[ -n "$TEMPLATE_MOVIE_ID" ]] || { echo "error: campaign $CAMPAIGN_ID has no template movie to bootstrap from" >&2; exit 1; }
      echo "  template movie $TEMPLATE_MOVIE_ID → gen-movie-season"
      SEED_BODY="$(jq -nc --arg mid "$TEMPLATE_MOVIE_ID" '{movieId:$mid}')"
      SEED_RESP="$(curl -fsS -X POST -H "$AUTH_H" -H 'Content-Type: application/json' \
        --data "$SEED_BODY" \
        "$API/workflow/gen-movie-season")"
      echo "  $SEED_RESP"
    fi

    echo "→ Polling for episodes (up to ~3 minutes)…"
    for i in $(seq 1 36); do
      sleep 5
      CAMPAIGN_JSON="$(fetch_campaign)"
      NEXT="$(pick_next_episode "$CAMPAIGN_JSON")"
      if [[ -n "$NEXT" ]]; then
        NEW_TOTAL="$(jq -r '.campaign.movies | length' <<<"$CAMPAIGN_JSON")"
        echo "  new episodes appeared ($NEW_TOTAL total)"
        break
      fi
      echo "  …still waiting ($i/36)"
    done

    if [[ -z "$NEXT" ]]; then
      echo "error: season bootstrap did not produce episodes within timeout" >&2
      exit 1
    fi
  fi
fi

IFS='|' read -r MOVIE_ID SEASON EPISODE TITLE <<<"$NEXT"
echo "→ Target episode: S${SEASON}E${EPISODE}  \"${TITLE}\"  (${MOVIE_ID})"

if [[ "$POST_ONLY" != true ]]; then

# ---- convert markdown story → flat bullet description --------------------
#
# Target shape (matches what the YakYak UI POSTs, as observed in
# breaking-bricks-news-dl.har):
#
#   - <scene 1 prose collapsed to one line> Bob says: "<dialog>"
#
#     - <scene 2 prose collapsed to one line> Trump says: "<dialog>"
#
#     - <scene 3 prose collapsed to one line> Mojtaba says: "<dialog>"
#     …
#
# Anything before the first "## Scene N" header (H1 title, headlines list,
# etc.) is dropped. The leading-character full name from the markdown is
# mapped to the short alias the screenplay generator expects.

# Cast map comes from the show via -v aliases="Needle=Alias,Other=Alias" (in
# priority order). map_short scans the ordered list and returns the first alias
# whose needle is a substring of the character name; falls back to first token.
DESCRIPTION="$(awk -v aliases="$CAST_ALIASES" '
  BEGIN { n_alias = split(aliases, pairs, ",") }
  function map_short(n,    a, i, kv) {
    for (i = 1; i <= n_alias; i++) {
      if (split(pairs[i], kv, "=") == 2 && index(n, kv[1]) > 0) return kv[2]
    }
    split(n, a, " "); return a[1]
  }
  function emit(    short) {
    if (!in_scene) return
    gsub(/[ \t]+/, " ", prose); sub(/^ +/, "", prose); sub(/ +$/, "", prose)
    short = map_short(character)
    if (n_scenes == 0) printf("- %s %s says: \"%s\"", prose, short, dialog)
    else               printf("\n\n  - %s %s says: \"%s\"", prose, short, dialog)
    n_scenes++
  }
  /^## Scene/ { emit(); in_scene = 1; prose = ""; character = ""; dialog = ""; next }
  !in_scene { next }
  /^\*\*Leading character:\*\*/ {
    sub(/^\*\*Leading character:\*\*[[:space:]]*/, "")
    character = $0; next
  }
  /^\*\*Dialog:\*\*/ {
    sub(/^\*\*Dialog:\*\*[[:space:]]*/, "")
    sub(/^"/, ""); sub(/"[[:space:]]*$/, "")
    dialog = $0; next
  }
  { if ($0 != "") prose = (prose == "" ? $0 : prose " " $0) }
  END { emit() }
' "$STORY_FILE")"

if [[ -z "$DESCRIPTION" ]]; then
  echo "error: converter produced an empty description from $STORY_FILE" >&2
  echo "       (no '## Scene N' headers were found)" >&2
  exit 1
fi

# ---- set plot -------------------------------------------------------------
# NOTE: the API field was renamed description -> plot (movie plot now lives on
# movie.plot). The story-derived text is unchanged; only the field name changed.

META_BODY="$(jq -nc --arg m "$MOVIE_ID" --arg d "$DESCRIPTION" '{movieId:$m, plot:$d}')"

echo "→ POST /workflow/set-movie-metadata"
META_RESP="$(curl -fsS -X POST -H "$AUTH_H" -H 'Content-Type: application/json' \
  --data "$META_BODY" \
  "$API/workflow/set-movie-metadata")"
echo "  $META_RESP"

# ---- build social caption + social title from Headlines section ----------
#
# Caption: matches the shape captured in save-social.har — first line is the
# section title (e.g. "Headlines we drew from"), then one headline per line
# with the "- " bullet prefix stripped. Section ends at the next "## " heading.
#
# Title: a ≤50-char punchy headline summarizing the day, generated by `claude
# -p` from the same headlines. On generation failure or over-length output,
# hard-truncate to 50 chars and continue (per agreed behavior).

SOCIAL_CAPTION="$(awk '
  /^## Headlines/ { sub(/^## /, ""); print; in_h = 1; next }
  /^## / { in_h = 0 }
  in_h && /^- / { sub(/^- /, ""); print }
' "$STORY_FILE")"

# Just the bullet lines (without the section-title prefix) — better signal
# for the LLM than the entire caption.
HEADLINES_ONLY="$(awk '
  /^## Headlines/ { in_h = 1; next }
  /^## / { in_h = 0 }
  in_h && /^- / { sub(/^- /, ""); print }
' "$STORY_FILE")"

SOCIAL_TITLE=""
if [[ -n "$HEADLINES_ONLY" ]] && command -v claude >/dev/null 2>&1; then
  echo "→ Generating social title from headlines via claude -p (50 char max)"
  TITLE_PROMPT="Read these news headlines and write ONE punchy social-post headline of MAX 50 characters that captures the day's top story. Output ONLY the headline text — no quotes, no preamble, no markdown, no trailing period.

Headlines:
$HEADLINES_ONLY"
  # No tools needed — pure completion.
  RAW_TITLE="$(claude -p "$TITLE_PROMPT" --allowed-tools "" --output-format text 2>/dev/null || true)"
  # Strip surrounding whitespace and any wrapping quotes/markdown the model might emit.
  SOCIAL_TITLE="$(printf '%s' "$RAW_TITLE" \
    | tr -d '\r' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
          -e 's/^"//' -e 's/"$//' \
          -e "s/^'//" -e "s/'$//" \
          -e 's/^`//' -e 's/`$//')"
  # Take only the first non-empty line if the model emitted multiple.
  SOCIAL_TITLE="$(printf '%s' "$SOCIAL_TITLE" | awk 'NF{print; exit}')"
fi

if [[ -z "$SOCIAL_TITLE" ]]; then
  # Fallback: first headline bullet, trimmed.
  SOCIAL_TITLE="$(printf '%s' "$HEADLINES_ONLY" | awk 'NF{print; exit}')"
fi

# Hard 50-char clamp (multibyte-safe via Python; falls back to byte cut).
if [[ ${#SOCIAL_TITLE} -gt 50 ]]; then
  if command -v python3 >/dev/null 2>&1; then
    SOCIAL_TITLE="$(python3 -c 'import sys; print(sys.argv[1][:50])' "$SOCIAL_TITLE")"
  else
    SOCIAL_TITLE="${SOCIAL_TITLE:0:50}"
  fi
fi

if [[ -n "$SOCIAL_CAPTION" || -n "$SOCIAL_TITLE" ]]; then
  if [[ -n "$SOCIAL_TITLE" ]]; then
    echo "  socialTitle: \"$SOCIAL_TITLE\" (${#SOCIAL_TITLE} chars)"
  fi
  SOCIAL_BODY="$(jq -nc \
    --arg m "$MOVIE_ID" \
    --arg s "$SOCIAL_CAPTION" \
    --arg t "$SOCIAL_TITLE" \
    '{movieId:$m}
     + (if $s == "" then {} else {socialDescription:$s} end)
     + (if $t == "" then {} else {socialTitle:$t} end)')"
  echo "→ POST /workflow/update-movie-social-description"
  SOCIAL_RESP="$(curl -fsS -X POST -H "$AUTH_H" -H 'Content-Type: application/json' \
    --data "$SOCIAL_BODY" \
    "$API/workflow/update-movie-social-description")"
  echo "  ${SOCIAL_RESP}"
else
  echo "→ skipping social overrides (no '## Headlines' section in story file)"
fi

# ---- trigger screenplay regen ---------------------------------------------

GEN_BODY="$(jq -nc --arg m "$MOVIE_ID" '{movieId:$m}')"
echo "→ POST /workflow/gen-movie-screenplay"
GEN_RESP="$(curl -fsS -X POST -H "$AUTH_H" -H 'Content-Type: application/json' \
  --data "$GEN_BODY" \
  "$API/workflow/gen-movie-screenplay")"
echo "  $GEN_RESP"

if [[ "$SKIP_FINALIZE" == true ]]; then
  echo
  echo "✓ Done (--skip-finalize); soundtrack + render NOT triggered."
  echo "  Movie:    ${MOVIE_ID}  (S${SEASON}E${EPISODE} - ${TITLE})"
  echo "  Preview:  https://yakyak.ai/export?movieId=${MOVIE_ID}"
  exit 0
fi

# ---- drive all scenes to a burned state (image → movie → subtitle → burn) --
#
# A scene is "ready for concat" when sceneBurnSubtitle.status == "completed".
# Rather than hard-fail on a single stuck/failed scene (which a deploy/restart
# can cause mid-render, even though the server then self-recovers), detect stalls
# and re-kick the pipeline — mirrors setup_show.sh's drive-loop:
#   - progress is measured across ALL four scene phases (subtitle/image/movie/
#     burn), not just burns, so a stall at any phase is detected;
#   - on a real stall OR any 'failed' step, re-assert basic mode (in case it was
#     switched) AND resume the movie;
#   - bail only when the overall poll window is exhausted.

echo "→ Waiting for scene generation (poll every ${SCENE_POLL_INTERVAL}s, up to $((SCENE_POLL_INTERVAL*SCENE_POLL_MAX/60)) min)…"

SCENES_READY=false
last_prog=-1; stall=0
for i in $(seq 1 "$SCENE_POLL_MAX"); do
  sleep "$SCENE_POLL_INTERVAL"
  MOVIE_JSON="$(curl -fsS -H "$AUTH_H" "$API/workflow/get-movie/$MOVIE_ID" || true)"
  if [[ -z "$MOVIE_JSON" ]]; then
    echo "  …poll $i/${SCENE_POLL_MAX}: get-movie returned empty, retrying"
    continue
  fi

  SCENE_COUNT="$(jq -r '(.scene // []) | length' <<<"$MOVIE_JSON" 2>/dev/null || echo 0)"
  if [[ "$SCENE_COUNT" == "0" ]]; then
    echo "  …poll $i/${SCENE_POLL_MAX}: screenplay not yet generated"
    continue
  fi

  DONE="$(jq -r '[(.scene // [])[] | select((.sceneBurnSubtitle.status // "") == "completed")] | length' <<<"$MOVIE_JSON" 2>/dev/null || echo 0)"
  # Completed steps across all four scene phases — the stall signal.
  prog="$(jq -r '[(.scene // [])[] | (.sceneSubtitleMovie.status // ""),(.sceneImage.status // ""),(.sceneMovie.status // ""),(.sceneBurnSubtitle.status // "")] | map(select(. == "completed")) | length' <<<"$MOVIE_JSON" 2>/dev/null || echo 0)"
  FAILED="$(jq -r '[(.scene // [])[] | select((.sceneBurnSubtitle.status // "") == "failed" or (.sceneImage.status // "") == "failed" or (.sceneMovie.status // "") == "failed")] | length' <<<"$MOVIE_JSON" 2>/dev/null || echo 0)"
  echo "  …poll $i/${SCENE_POLL_MAX}: ${DONE}/${SCENE_COUNT} burned (steps $prog/$((SCENE_COUNT*4)), failed $FAILED)"
  if [[ "$DONE" == "$SCENE_COUNT" ]]; then
    SCENES_READY=true
    echo "  all $SCENE_COUNT scene(s) burned and ready"
    break
  fi
  if [[ "$prog" -gt "$last_prog" ]]; then last_prog="$prog"; stall=0; else stall=$((stall+1)); fi
  # Re-kick on a real stall, or immediately if something is in 'failed'.
  if [[ "$stall" -ge 4 || "$FAILED" -gt 0 ]]; then
    echo "  …stalled/failed — re-asserting basic mode + resume"
    switch_campaign_mode basic || true
    resume_movie "$MOVIE_ID"
    stall=0
  fi
done

if [[ "$SCENES_READY" != true ]]; then
  echo "error: scenes did not complete within timeout. Run again with --skip-finalize and finalize later." >&2
  exit 1
fi

# ---- pick + assign soundtrack ---------------------------------------------
#
# We set the configured soundtrack path DIRECTLY. /workflow/set-soundtrack-audio
# stores any audioPath verbatim, and the render step reuses it straight from the
# CDN by path ("Reusing existing audio file: <path>") — so the path does NOT
# need to appear in /workflow/available-soundtracks.
#
# That endpoint is a GLOBAL, recency-capped picker (30 most-recent completed
# soundtracks across ALL users, then ETag-deduped to 10). The BBN intro track
# ages out of that window within a few days of normal platform activity, so
# gating on it is exactly what silently composited a stranger's track onto the
# 2026-05-30 episode. We only consult the picker as a last resort when no
# soundtrack path was configured at all.

CHOSEN_AUDIO_PATH="$SOUNDTRACK_AUDIO_PATH"

if [[ -n "$CHOSEN_AUDIO_PATH" ]]; then
  # Verify the configured audio actually exists on the CDN before we commit to
  # it — a missing file would otherwise surface as a late, opaque Lambda render
  # failure. cdn base mirrors the API's YAKYAK_CDN_URL default.
  CDN_BASE="${YAKYAK_CDN_URL:-https://cdn.yakyak.ai}"
  AUDIO_HTTP="$(curl -fsS -o /dev/null -w '%{http_code}' -I "$CDN_BASE/$CHOSEN_AUDIO_PATH" || true)"
  if [[ ! "$AUDIO_HTTP" =~ ^2 ]]; then
    echo "error: configured soundtrack not reachable on CDN (HTTP $AUDIO_HTTP):" >&2
    echo "       $CDN_BASE/$CHOSEN_AUDIO_PATH" >&2
    echo "       Pass a valid --soundtrack <audioPath> or fix SOUNDTRACK_AUDIO_PATH in show.env." >&2
    exit 1
  fi
  echo "→ Using configured soundtrack (verified on CDN, HTTP $AUDIO_HTTP)"
else
  echo "→ No soundtrack configured; falling back to /workflow/available-soundtracks/$MOVIE_ID"
  SOUNDTRACKS_JSON="$(curl -fsS -H "$AUTH_H" "$API/workflow/available-soundtracks/$MOVIE_ID")"
  CHOSEN_AUDIO_PATH="$(jq -r '.[0].audioPath // empty' <<<"$SOUNDTRACKS_JSON")"
  if [[ -z "$CHOSEN_AUDIO_PATH" ]]; then
    echo "error: no soundtrack configured and none available for movie $MOVIE_ID" >&2
    exit 1
  fi
  echo "  picker items[0]: $CHOSEN_AUDIO_PATH"
fi
echo "  audioPath: $CHOSEN_AUDIO_PATH"

SOUNDTRACK_BODY="$(jq -nc --arg m "$MOVIE_ID" --arg p "$CHOSEN_AUDIO_PATH" \
  '{movieId:$m, audioPath:$p}')"
echo "→ POST /workflow/set-soundtrack-audio"
SET_AUDIO_RESP="$(curl -fsS -X POST -H "$AUTH_H" -H 'Content-Type: application/json' \
  --data "$SOUNDTRACK_BODY" \
  "$API/workflow/set-soundtrack-audio")"
echo "  ${SET_AUDIO_RESP:-ok}"

# ---- set volume -----------------------------------------------------------

VOLUME_BODY="$(jq -nc --arg m "$MOVIE_ID" --argjson v "$VOLUME_PERCENTAGE" \
  '{movieId:$m, volumePercentage:$v}')"
echo "→ POST /workflow/set-soundtrack  (volumePercentage=$VOLUME_PERCENTAGE)"
SET_VOLUME_RESP="$(curl -fsS -X POST -H "$AUTH_H" -H 'Content-Type: application/json' \
  --data "$VOLUME_BODY" \
  "$API/workflow/set-soundtrack")"
echo "  ${SET_VOLUME_RESP:-ok}"

# ---- trigger final render + wait for it to finish -------------------------
#
# Wait (not fire-and-forget) so that /social/post-movie can read the freshly
# rendered MP4 off the movie when --post is set. Even without --post, the
# extra signal is useful for piping into other tooling.

RENDER_BODY="$(jq -nc --arg m "$MOVIE_ID" '{movieId:$m, force:false}')"
echo "→ POST /workflow/export-render"
RENDER_RESP="$(curl -fsS -X POST -H "$AUTH_H" -H 'Content-Type: application/json' \
  --data "$RENDER_BODY" \
  "$API/workflow/export-render")"
echo "  $RENDER_RESP"

echo "→ Waiting for render to finish (poll every ${RENDER_POLL_INTERVAL}s, up to $((RENDER_POLL_INTERVAL*RENDER_POLL_MAX/60)) min)…"
RENDER_URL=""
for i in $(seq 1 "$RENDER_POLL_MAX"); do
  sleep "$RENDER_POLL_INTERVAL"
  RH_JSON="$(curl -fsS -H "$AUTH_H" "$API/workflow/render-history/$MOVIE_ID" || true)"
  if [[ -z "$RH_JSON" ]]; then
    echo "  …poll $i/${RENDER_POLL_MAX}: render-history returned empty, retrying"
    continue
  fi
  FINISHED_AT="$(jq -r '.items[0].finishedAt // empty' <<<"$RH_JSON")"
  if [[ -n "$FINISHED_AT" ]]; then
    RENDER_URL="$(jq -r '.items[0].soundtrackedMovieUrl // empty' <<<"$RH_JSON")"
    echo "  finished at $FINISHED_AT"
    echo "  $RENDER_URL"
    break
  fi
  echo "  …poll $i/${RENDER_POLL_MAX}: still rendering"
done

if [[ -z "$RENDER_URL" ]]; then
  echo "error: render did not finish within timeout. Skipping --post (if set)." >&2
  exit 1
fi

fi  # end POST_ONLY != true (skip-upload+render block)

# ---- optional: post to social --------------------------------------------

if [[ "$POST_TO_SOCIAL" == true ]]; then
  echo "→ GET /social/campaign-links/$CAMPAIGN_ID"
  LINKS_JSON="$(curl -fsS -H "$AUTH_H" "$API/social/campaign-links/$CAMPAIGN_ID")"
  LINK_COUNT="$(jq -r '.count // 0' <<<"$LINKS_JSON")"
  echo "  $LINK_COUNT linked network(s)"

  # ---- confirmation gate ---------------------------------------------------
  # Posting is irreversible, and in --post-only mode the target episode comes
  # from a heuristic (most-recent render across the campaign). Show the exact
  # episode + networks and require explicit confirmation before firing, so a
  # buggy picker can't silently post the wrong episode. Bypass with --yes/-y for
  # automated/cron runs.
  NETWORK_LIST="$(jq -r '[.campaignLinks[]?.socialNetworkName] | join(", ")' <<<"$LINKS_JSON")"
  echo
  echo "  ┌─ About to POST to social ──────────────────────────────"
  echo "  │ Episode:  S${SEASON}E${EPISODE}  \"${TITLE}\""
  echo "  │ Movie:    ${MOVIE_ID}"
  echo "  │ Networks: ${NETWORK_LIST:-<none linked>}"
  echo "  │ Preview:  https://yakyak.ai/export?movieId=${MOVIE_ID}"
  echo "  └────────────────────────────────────────────────────────"
  if [[ "$ASSUME_YES" == true ]]; then
    echo "  --yes given → posting without confirmation"
  elif [[ -t 0 ]]; then
    read -r -p "  Post THIS episode to the networks above? [y/N] " yn
    case "$yn" in
      [Yy]*) echo "  confirmed; posting" ;;
      *)     echo "  aborted by user — nothing was posted"; exit 1 ;;
    esac
  else
    echo "error: refusing to post non-interactively without --yes (episode picker is heuristic)." >&2
    echo "       Re-run on a TTY to confirm, or pass --yes/-y to post unattended." >&2
    exit 1
  fi

  # Iterate without piping — preserves the parent shell's exit-code visibility.
  POST_OK=0
  POST_FAIL=0
  while IFS=$'\t' read -r CONN_ID NETWORK_NAME; do
    [[ -z "$CONN_ID" ]] && continue
    echo "→ POST /social/post-movie/$MOVIE_ID/$CONN_ID  ($NETWORK_NAME)"
    # Use -sS (no -f) so we can read the body on 4xx and keep going. The
    # backend's batched PFM integration already handles 429s server-side,
    # but per-network 4xx can still happen (mis-configured account, etc.).
    HTTP_RESP="$(curl -sS -X POST -H "$AUTH_H" -H 'Content-Type: application/json' \
      -w '\n%{http_code}' \
      --data '' \
      "$API/social/post-movie/$MOVIE_ID/$CONN_ID" || true)"
    HTTP_CODE="$(printf '%s\n' "$HTTP_RESP" | tail -n1)"
    BODY="$(printf '%s\n' "$HTTP_RESP" | sed '$d')"
    if [[ "$HTTP_CODE" =~ ^2 ]]; then
      POST_OK=$((POST_OK + 1))
      echo "  ✓ $HTTP_CODE"
    else
      POST_FAIL=$((POST_FAIL + 1))
      echo "  ✗ $HTTP_CODE  $(printf '%s' "$BODY" | head -c 240)"
    fi
  done < <(jq -r '.campaignLinks[]? | "\(.connectedNetworkId)\t\(.socialNetworkName)"' <<<"$LINKS_JSON")

  echo "  social posting: $POST_OK ok, $POST_FAIL failed"
else
  echo "→ skipping social posting (pass --post to enable)"
fi

echo
echo "✓ Done."
echo "  Movie:    ${MOVIE_ID}  (S${SEASON}E${EPISODE} - ${TITLE})"
if [[ "$POST_ONLY" != true ]]; then
  echo "  Story:    ${STORY_FILE}"
  echo "  Volume:   ${VOLUME_PERCENTAGE}%"
fi
echo "  Preview:  https://yakyak.ai/export?movieId=${MOVIE_ID}"

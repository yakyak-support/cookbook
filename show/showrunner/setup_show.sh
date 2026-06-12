#!/usr/bin/env bash
#
# setup_show.sh — one-time (idempotent) setup for a show: ensure its campaign
# exists, generate the recurring cast portraits, compose a reusable soundtrack,
# and wire the resulting ids into show.env.
#
#   YAKYAK_PAT=yy_live_... ./setup_show.sh [showDir] [--force] [--no-soundtrack]
#   (showDir defaults to show/Horoscopes)
#
# Idempotent / safe to re-run (and to call from CI self-heal):
#   - Campaign: reuses show.env CAMPAIGN_ID if set; else finds an existing campaign
#     by NAME (from campaign.import.json) for this user; else imports a new one.
#     --force always imports a fresh campaign.
#   - Cast images: generated only for characters missing a portrait.
#   - Soundtrack: composed only if none is set yet (skip with --no-soundtrack).
#   Already-done paid steps (cast images, soundtrack) are skipped on re-run.
#
# Env:
#   YAKYAK_PAT       (required)  yy_live_… PAT. Falls back to YAKYAK_BB_PAT, then e2e/.env.bb.
#   YAKYAK_API_URL   (optional)  defaults to https://api.yakyak.ai
# Needs: curl, jq.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # show/showrunner
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

FORCE=false
NO_SOUNDTRACK=false
SHOW_DIR_ARG=""
for a in "$@"; do
  case "$a" in
    --force) FORCE=true ;;
    --no-soundtrack) NO_SOUNDTRACK=true ;;
    -h|--help) sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "error: unknown flag '$a'" >&2; exit 1 ;;
    *) SHOW_DIR_ARG="$a" ;;
  esac
done
SHOW_DIR_ARG="${SHOW_DIR_ARG:-$REPO_ROOT/show/Horoscopes}"

SHOW_DIR="$(cd "$SHOW_DIR_ARG" 2>/dev/null && pwd || true)"
[[ -n "$SHOW_DIR" && -d "$SHOW_DIR" ]] || { echo "error: show dir not found: $SHOW_DIR_ARG" >&2; exit 1; }
IMPORT_FILE="$SHOW_DIR/campaign.import.json"
SHOW_ENV="$SHOW_DIR/show.env"
[[ -f "$IMPORT_FILE" ]] || { echo "error: no campaign.import.json in $SHOW_DIR" >&2; exit 1; }
[[ -f "$SHOW_ENV" ]]    || { echo "error: no show.env in $SHOW_DIR" >&2; exit 1; }

for bin in curl jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "error: '$bin' not found in PATH" >&2; exit 1; }
done

# ---- credentials -----------------------------------------------------------
ENV_FILE="$REPO_ROOT/e2e/.env.bb"
PAT="${YAKYAK_PAT:-${YAKYAK_BB_PAT:-}}"
if [[ -z "$PAT" && -f "$ENV_FILE" ]]; then
  set -o allexport; # shellcheck disable=SC1090
  source "$ENV_FILE"; set +o allexport
  PAT="${YAKYAK_PAT:-${YAKYAK_BB_PAT:-}}"
fi
API="${YAKYAK_API_URL:-https://api.yakyak.ai}"
[[ -n "$PAT" ]] || { echo "error: set \$YAKYAK_PAT (or YAKYAK_BB_PAT / e2e/.env.bb)" >&2; exit 1; }
[[ "$PAT" == yy_live_* ]] || { echo "error: \$YAKYAK_PAT does not look like a PAT (expected 'yy_live_…')" >&2; exit 1; }

AUTH=(-H "Authorization: Bearer $PAT")
JSON=(-H 'Content-Type: application/json')

# Switch a campaign between basic/pro. Rendering must run in BASIC so the
# pipeline auto-chains scenes — a pro-mode campaign suppresses shouldAutoChain()
# (api workflow.service.ts) and the scenes hang in "waiting" forever. This
# mirrors upload_to_yakyak.py, which switches to basic per run for the same reason.
set_campaign_mode() {
  curl -fsS -X POST "${AUTH[@]}" "${JSON[@]}" \
    -d "$(jq -n --arg cid "$1" --arg m "$2" '{campaignId:$cid, mode:$m}')" \
    "$API/workflow/switch-campaign-mode" >/dev/null 2>&1 || true
}
# Kick a movie's scene pipeline (advances the next incomplete phase, mode- and
# season-independent). The template trailer (season==null) is NOT auto-rendered
# by the screenplay hook — it pauses for review — so we trigger it explicitly.
resume_movie() {
  curl -fsS -X POST "${AUTH[@]}" "${JSON[@]}" \
    -d "$(jq -n --arg mid "$1" '{movieId:$mid}')" \
    "$API/workflow/resume" >/dev/null 2>&1 || true
}
# Switch a campaign to basic and CONFIRM it took. set_campaign_mode is best-effort
# (swallows errors), but switch-campaign-mode is OWNER-LOCKED — a non-owner PAT
# 403s, leaving the campaign 'pro' so auto-chain never fires and the scene poll
# hangs forever. The 200 response echoes the new mode, so assert it == basic (a
# 403 yields an empty body → mismatch). Retries once; non-zero if it never took.
ensure_basic_mode() {
  local cid="$1" resp mode attempt
  for attempt in 1 2; do
    resp="$(curl -fsS -X POST "${AUTH[@]}" "${JSON[@]}" \
      -d "$(jq -n --arg cid "$cid" '{campaignId:$cid, mode:"basic"}')" \
      "$API/workflow/switch-campaign-mode" 2>/dev/null || true)"
    mode="$(jq -r '.mode // empty' <<<"$resp" 2>/dev/null || true)"
    [[ "$mode" == "basic" ]] && return 0
  done
  return 1
}

decode_user_id() {
  local pat="$1" jwt payload
  jwt="${pat#yy_live_}"; payload="${jwt#*.}"; payload="${payload%%.*}"
  payload="${payload//-/+}"; payload="${payload//_//}"
  case $(( ${#payload} % 4 )) in 2) payload="$payload==";; 3) payload="$payload=";; esac
  printf '%s' "$payload" | base64 -d 2>/dev/null | jq -r '.id // empty'
}
USER_ID="$(decode_user_id "$PAT")"
[[ -n "$USER_ID" ]] || { echo "error: could not decode userId from PAT" >&2; exit 1; }

# Replace (or append) KEY="value" in show.env.
set_env_key() {
  local f="$1" k="$2" v="$3" tmp; tmp="$(mktemp)"
  awk -v k="$k" -v v="$v" 'BEGIN{d=0} $0 ~ "^"k"="{print k"=\""v"\""; d=1; next} {print} END{if(!d) print k"=\""v"\""}' "$f" >"$tmp" && mv "$tmp" "$f"
}
get_env_key() { grep -E "^$2=" "$1" | head -1 | sed -E "s/^$2=//; s/^\"//; s/\"$//"; }

echo "→ Show:    $(basename "$SHOW_DIR")"
echo "→ API:     $API"
echo "→ User:    $USER_ID"

CAMPAIGN_NAME="$(jq -r '.campaigns[0].name // empty' "$IMPORT_FILE")"
existing_cid="$(get_env_key "$SHOW_ENV" CAMPAIGN_ID)"

# ---- 1. ensure the campaign exists ----------------------------------------
CAMPAIGN_ID=""
if [[ "$FORCE" == true ]]; then
  existing_cid=""   # force a fresh import
elif [[ -n "$existing_cid" ]]; then
  CAMPAIGN_ID="$existing_cid"
  echo "→ Using CAMPAIGN_ID from show.env: $CAMPAIGN_ID"
fi

if [[ -z "$CAMPAIGN_ID" ]]; then
  # Find an existing campaign by NAME for this user (idempotent; safe in CI).
  list="$(curl -fsS "${AUTH[@]}" "$API/workflow/list-campaign/$USER_ID")"
  CAMPAIGN_ID="$(jq -r --arg n "$CAMPAIGN_NAME" '.campaigns[] | select(.name == $n) | .id' <<<"$list" | head -1)"
  if [[ -n "$CAMPAIGN_ID" ]]; then
    echo "→ Found existing campaign by name \"$CAMPAIGN_NAME\": $CAMPAIGN_ID"
  else
    echo "→ Importing $IMPORT_FILE"
    body="$(jq -n --arg uid "$USER_ID" --slurpfile d "$IMPORT_FILE" '{userId:$uid, importData:$d[0]}')"
    resp="$(curl -fsS -X POST "${AUTH[@]}" "${JSON[@]}" -d "$body" "$API/workflow/import-campaign")"
    CAMPAIGN_ID="$(jq -r '.campaigns[0].id // empty' <<<"$resp")"
    [[ -n "$CAMPAIGN_ID" ]] || { echo "error: import returned no campaign id: $(jq -c . <<<"$resp" | cut -c1-300)" >&2; exit 1; }
    echo "  imported campaign $CAMPAIGN_ID"
  fi
  set_env_key "$SHOW_ENV" CAMPAIGN_ID "$CAMPAIGN_ID"
  echo "  wrote CAMPAIGN_ID into $SHOW_ENV"
fi

# ---- 2. resolve the template movie + any existing soundtrack ---------------
list="$(curl -fsS "${AUTH[@]}" "$API/workflow/list-campaign/$USER_ID")"
entry="$(jq -c --arg id "$CAMPAIGN_ID" '.campaigns[] | select(.id == $id)' <<<"$list" | head -1)"
[[ -n "$entry" ]] || { echo "error: campaign $CAMPAIGN_ID not found for user (wrong PAT?)" >&2; exit 1; }
TEMPLATE_MOVIE_ID="$(jq -r '.template.id // empty' <<<"$entry")"
EXISTING_AUDIO="$(jq -r '.template.audioPath // empty' <<<"$entry")"
[[ -n "$TEMPLATE_MOVIE_ID" ]] || { echo "error: campaign $CAMPAIGN_ID has no template movie" >&2; exit 1; }
echo "→ Template movie: $TEMPLATE_MOVIE_ID"

# ---- 3. cast images (generate missing, then poll) -------------------------
cast_json="$(curl -fsS "${AUTH[@]}" "$API/workflow/get-cast/$TEMPLATE_MOVIE_ID")"
TOTAL="$(jq -r '(.cast // []) | length' <<<"$cast_json")"
[[ "$TOTAL" -gt 0 ]] || { echo "error: template has no cast members to image" >&2; exit 1; }
ready_count() { jq -r '[ (.cast // [])[] | select(((.cdnUrl // .imageUrl) // "") != "") ] | length' <<<"$1"; }
ready="$(ready_count "$cast_json")"

if [[ "$ready" -ge "$TOTAL" ]]; then
  echo "→ Cast images already present ($ready/$TOTAL)."
else
  # A single gen-movie-cast-image call may only complete a sub-batch (observed:
  # ~6 at a time) and then leave the execution "processing" without finishing the
  # rest. So we re-trigger whenever progress stalls (no new image for ~36s) — a
  # new call picks up the still-missing characters. Idempotent: it only generates
  # portraits that are still absent.
  trigger_cast() {
    curl -fsS -X POST "${AUTH[@]}" "${JSON[@]}" \
      -d "$(jq -n --arg mid "$TEMPLATE_MOVIE_ID" '{movieId:$mid}')" \
      "$API/workflow/gen-movie-cast-image" >/dev/null 2>&1 || true
  }
  echo "→ Generating cast images for $TOTAL character(s) (paid)…"
  trigger_cast
  last="$ready"; stall=0
  for i in $(seq 1 120); do
    sleep 6
    cast_json="$(curl -fsS "${AUTH[@]}" "$API/workflow/get-cast/$TEMPLATE_MOVIE_ID" || true)"
    [[ -n "$cast_json" ]] || { echo "  …poll $i/120: get-cast empty"; continue; }
    ready="$(ready_count "$cast_json")"
    echo "  …poll $i/120: cast images $ready/$TOTAL"
    [[ "$ready" -ge "$TOTAL" ]] && break
    if [[ "$ready" -gt "$last" ]]; then last="$ready"; stall=0; else stall=$((stall+1)); fi
    if [[ "$stall" -ge 6 ]]; then
      echo "  …no progress for ~36s — re-triggering generation for the missing $((TOTAL-ready))"
      trigger_cast; stall=0
    fi
  done
  [[ "$ready" -ge "$TOTAL" ]] || { echo "error: cast images timed out ($ready/$TOTAL); re-run to resume." >&2; exit 1; }
fi

# ---- 4. soundtrack (compose once, reused by every episode) -----------------
cfg_audio="$(get_env_key "$SHOW_ENV" SOUNDTRACK_AUDIO_PATH)"
if [[ "$NO_SOUNDTRACK" == true ]]; then
  echo "→ Skipping soundtrack (--no-soundtrack)."
elif [[ -n "$cfg_audio" ]]; then
  echo "→ Soundtrack already set in show.env."
elif [[ -n "$EXISTING_AUDIO" ]]; then
  echo "→ Soundtrack already on template; wiring into show.env."
  set_env_key "$SHOW_ENV" SOUNDTRACK_AUDIO_PATH "$EXISTING_AUDIO"
else
  # Mood prompt: MUSIC_PROMPT from show.env > API suggestion > generic default.
  music_prompt="$(get_env_key "$SHOW_ENV" MUSIC_PROMPT)"
  if [[ -z "$music_prompt" ]]; then
    music_prompt="$(curl -fsS "${AUTH[@]}" "$API/workflow/suggested-music-prompt/$TEMPLATE_MOVIE_ID" | jq -r '.prompt // empty' || true)"
  fi
  [[ -n "$music_prompt" ]] || music_prompt="Ambient celestial instrumental: warm pads, soft chimes, slow and contemplative"
  echo "→ Composing soundtrack (paid): ${music_prompt:0:70}…"
  curl -fsS -X POST "${AUTH[@]}" "${JSON[@]}" \
    -d "$(jq -n --arg mid "$TEMPLATE_MOVIE_ID" '{movieId:$mid, audioPath:""}')" \
    "$API/workflow/set-soundtrack-audio" >/dev/null || true
  curl -fsS -X POST "${AUTH[@]}" "${JSON[@]}" \
    -d "$(jq -n --arg mid "$TEMPLATE_MOVIE_ID" --arg p "$music_prompt" '{movieId:$mid, musicPrompt:$p}')" \
    "$API/workflow/gen-movie-soundtrack" >/dev/null
  audio=""
  for i in $(seq 1 120); do
    sleep 6
    at="$(curl -fsS "${AUTH[@]}" "$API/workflow/audio-tracks/$TEMPLATE_MOVIE_ID" || true)"
    [[ -n "$at" ]] || at='{}'
    st="$(jq -r '.soundtrackStatus // "waiting"' <<<"$at" 2>/dev/null || echo waiting)"
    ap="$(jq -r '.audioPath // ""' <<<"$at" 2>/dev/null || echo '')"
    echo "  …poll $i/120: soundtrack=$st"
    if [[ "$st" == "completed" && -n "$ap" ]]; then audio="$ap"; break; fi
    if [[ "$st" == "failed" ]]; then break; fi
  done
  if [[ -n "$audio" ]]; then
    set_env_key "$SHOW_ENV" SOUNDTRACK_AUDIO_PATH "$audio"
    echo "  wrote SOUNDTRACK_AUDIO_PATH into $SHOW_ENV"
  else
    echo "⚠️  soundtrack compose did not complete — leaving SOUNDTRACK_AUDIO_PATH empty" >&2
    echo "    (the render will fall back to the soundtrack picker; re-run setup to retry)" >&2
  fi
fi

# ---- 5. trailer (render the movie that precedes S1E1) ---------------------
# The trailer is the movie that plays before S1E1. In the data model it lives
# on the template row (season=null/episode=null) — the same row the engine
# also clones from for per-episode cast/styling — but conceptually it is the
# *first* watchable video of the campaign and is rendered exactly like a
# standard episode: stamp a plot via set-movie-metadata, generate the
# screenplay, wait for the burns, then export-render. The plot source for the
# trailer is the campaign-level prompt (campaigns[0].prompt from
# campaign.import.json) — there is no separate "trailer plot"; trailer and
# standard episodes are equal-class movies that each get a plot stamped onto
# them. (Episodes get theirs per-run via upload_to_yakyak.*.)
#
# Without this step the imported template carries only the cast-roster meta
# plot that arrived in campaign.import.json (e.g. "Recurring cast template…"),
# no screenplay or render is ever produced for it, and upload_to_yakyak.*
# ships S1E1 first.
#
# Idempotent: skipped when the template already has a soundtrackedMovieUrl.
# See show/docs/show_runner_missing_trailer_bug.md.
trailer_mv="$(curl -fsS "${AUTH[@]}" "$API/workflow/get-movie/$TEMPLATE_MOVIE_ID" 2>/dev/null || echo '{}')"
trailer_url="$(jq -r '.movieSoundtrack.soundtrackedMovieUrl // ""' <<<"$trailer_mv")"
if [[ -n "$trailer_url" ]]; then
  echo "→ Trailer already rendered."
else
  CAMPAIGN_PROMPT="$(jq -r '.campaigns[0].prompt // empty' "$IMPORT_FILE")"
  [[ -n "$CAMPAIGN_PROMPT" ]] || { echo "error: campaigns[0].prompt missing in $IMPORT_FILE — needed as the trailer plot" >&2; exit 1; }
  echo "→ Rendering trailer on template $TEMPLATE_MOVIE_ID (paid)…"
  echo "  plot: ${CAMPAIGN_PROMPT:0:90}…"

  # The trailer is the season==null template: the screenplay hook deliberately
  # does NOT auto-render its scenes (it pauses for review), and a pro-mode
  # campaign suppresses auto-chain entirely. So render in BASIC and kick the
  # scene pipeline explicitly via /workflow/resume (below). Restore PRO on exit.
  echo "  → campaign mode → basic (enables scene auto-chain)"
  ensure_basic_mode "$CAMPAIGN_ID" || {
    echo "error: could not enable basic mode — campaign still pro; check that the PAT owns campaign $CAMPAIGN_ID" >&2
    exit 1
  }
  trap 'echo "→ restoring campaign mode → pro"; set_campaign_mode "$CAMPAIGN_ID" pro' EXIT

  # 5a. stamp the campaign prompt as the trailer plot (overwrites the imported
  # cast-roster meta plot the screenplay step would otherwise consume).
  curl -fsS -X POST "${AUTH[@]}" "${JSON[@]}" \
    -d "$(jq -n --arg mid "$TEMPLATE_MOVIE_ID" --arg p "$CAMPAIGN_PROMPT" '{movieId:$mid, plot:$p}')" \
    "$API/workflow/set-movie-metadata" >/dev/null

  # 5b. screenplay (cast precondition in genMovieScreenplay skips episode==null
  # movies, so the template flows straight to generation).
  echo "  → POST /workflow/gen-movie-screenplay"
  curl -fsS -X POST "${AUTH[@]}" "${JSON[@]}" \
    -d "$(jq -n --arg mid "$TEMPLATE_MOVIE_ID" '{movieId:$mid}')" \
    "$API/workflow/gen-movie-screenplay" >/dev/null

  # 5b-bis. The screenplay hook leaves the template's scenes in "waiting"
  # (season==null pauses for review), so explicitly kick the scene pipeline. In
  # basic mode the per-scene hooks then auto-chain image→movie→burn→concat.
  sleep 5
  resume_movie "$TEMPLATE_MOVIE_ID"

  # 5c. Drive every scene to a burned state (~15s × 120 = 30 min max), detecting
  # stalls and re-kicking the pipeline. A movie can stall for reasons the screenplay
  # hook won't recover from: pro-mode suppresses auto-chain, the campaign can get
  # switched back to pro mid-render, or a single step can drop its chain. So:
  #   - progress is measured across ALL scene phases (subtitle/image/movie/burn),
  #     not just burns, so a stall at any phase is detected;
  #   - on every stall we RE-ASSERT basic mode (in case it was switched) AND resume;
  #   - 'failed' steps are re-kicked too (a retrigger often clears a transient fail),
  #     bounded by the overall timeout below.
  scenes_ready=false
  last_prog=-1; stall=0
  for i in $(seq 1 120); do
    sleep 15
    mv_json="$(curl -fsS "${AUTH[@]}" "$API/workflow/get-movie/$TEMPLATE_MOVIE_ID" 2>/dev/null || echo '{}')"
    scene_count="$(jq -r '(.scene // []) | length' <<<"$mv_json" 2>/dev/null || echo 0)"
    if [[ "$scene_count" -eq 0 ]]; then
      echo "  …poll $i/120: trailer screenplay not yet generated"
      continue
    fi
    done="$(jq -r '[(.scene // [])[] | select((.sceneBurnSubtitle.status // "") == "completed")] | length' <<<"$mv_json" 2>/dev/null || echo 0)"
    # Completed steps across all four scene phases — the stall signal.
    prog="$(jq -r '[(.scene // [])[] | (.sceneSubtitleMovie.status // ""),(.sceneImage.status // ""),(.sceneMovie.status // ""),(.sceneBurnSubtitle.status // "")] | map(select(. == "completed")) | length' <<<"$mv_json" 2>/dev/null || echo 0)"
    failed="$(jq -r '[(.scene // [])[] | select((.sceneBurnSubtitle.status // "") == "failed" or (.sceneImage.status // "") == "failed" or (.sceneMovie.status // "") == "failed")] | length' <<<"$mv_json" 2>/dev/null || echo 0)"
    echo "  …poll $i/120: $done/$scene_count burned (steps $prog/$((scene_count*4)), failed $failed)"
    if [[ "$done" -eq "$scene_count" ]]; then
      scenes_ready=true
      break
    fi
    if [[ "$prog" -gt "$last_prog" ]]; then last_prog="$prog"; stall=0; else stall=$((stall+1)); fi
    # Re-kick on a real stall, or immediately if something is in 'failed'.
    if [[ "$stall" -ge 4 || "$failed" -gt 0 ]]; then
      echo "  …stalled/failed — re-asserting basic mode + resume"
      set_campaign_mode "$CAMPAIGN_ID" basic
      resume_movie "$TEMPLATE_MOVIE_ID"
      stall=0
    fi
  done
  [[ "$scenes_ready" == true ]] || { echo "error: trailer scenes did not finish within timeout; re-run to resume." >&2; exit 1; }

  # 5d. (re)affirm soundtrack audio + volume on the template, then render.
  cfg_audio="$(get_env_key "$SHOW_ENV" SOUNDTRACK_AUDIO_PATH)"
  cfg_volume="$(get_env_key "$SHOW_ENV" VOLUME)"; cfg_volume="${cfg_volume:-45}"
  if [[ -n "$cfg_audio" ]]; then
    curl -fsS -X POST "${AUTH[@]}" "${JSON[@]}" \
      -d "$(jq -n --arg mid "$TEMPLATE_MOVIE_ID" --arg p "$cfg_audio" '{movieId:$mid, audioPath:$p}')" \
      "$API/workflow/set-soundtrack-audio" >/dev/null
  fi
  curl -fsS -X POST "${AUTH[@]}" "${JSON[@]}" \
    -d "$(jq -n --arg mid "$TEMPLATE_MOVIE_ID" --argjson v "$cfg_volume" '{movieId:$mid, volumePercentage:$v}')" \
    "$API/workflow/set-soundtrack" >/dev/null

  # export-render is REQUIRED to produce the final soundtracked movie — the
  # basic-mode auto-chain stops after the soundtrack STEP (status flips to
  # 'completed') without ever emitting render-history / soundtrackedMovieUrl. So
  # completion is keyed on render-history finishing, NOT on step statuses, and we
  # re-POST export-render if no render appears after a stall.
  echo "  → POST /workflow/export-render"
  curl -fsS -X POST "${AUTH[@]}" "${JSON[@]}" \
    -d "$(jq -n --arg mid "$TEMPLATE_MOVIE_ID" '{movieId:$mid, force:false}')" \
    "$API/workflow/export-render" >/dev/null

  rstall=0
  for i in $(seq 1 180); do
    sleep 5
    rh="$(curl -fsS "${AUTH[@]}" "$API/workflow/render-history/$TEMPLATE_MOVIE_ID" 2>/dev/null || echo '{}')"
    finished_at="$(jq -r '.items[0].finishedAt // ""' <<<"$rh" 2>/dev/null || echo '')"
    if [[ -n "$finished_at" && "$finished_at" != "null" ]]; then
      trailer_url="$(jq -r '.items[0].soundtrackedMovieUrl // ""' <<<"$rh")"
      echo "  trailer rendered: $trailer_url"
      break
    fi
    render_count="$(jq -r '(.items // []) | length' <<<"$rh" 2>/dev/null || echo 0)"
    echo "  …poll $i/180: trailer still rendering (render-history items=$render_count)"
    # No render row appeared at all after ~60s → the export-render didn't take
    # (e.g. mode flipped, or the chain marked soundtrack done without rendering).
    # Re-assert basic mode and re-POST export-render.
    if [[ "$render_count" -eq 0 ]]; then
      rstall=$((rstall+1))
      if [[ "$rstall" -ge 12 ]]; then
        echo "  …no render started — re-asserting basic mode + re-POST export-render"
        set_campaign_mode "$CAMPAIGN_ID" basic
        curl -fsS -X POST "${AUTH[@]}" "${JSON[@]}" \
          -d "$(jq -n --arg mid "$TEMPLATE_MOVIE_ID" '{movieId:$mid, force:false}')" \
          "$API/workflow/export-render" >/dev/null 2>&1 || true
        rstall=0
      fi
    fi
  done
  [[ -n "$trailer_url" ]] || { echo "error: trailer render did not finish within timeout; re-run to resume." >&2; exit 1; }
fi

# ---- 6. bootstrap season 1 episode slots ----------------------------------
# get-campaign returns only NUMBERED episodes (templates are filtered out). A
# freshly-imported campaign has none, and create-new-season can't bootstrap (it
# requires an existing episode). gen-movie-season on the template creates season
# 1's episode slots (titles are generated, then overwritten per run). The engine
# then fills the next empty slot each run; once a season is exhausted it uses
# create-new-season (which now works) for the next.
ep_count="$(curl -fsS "${AUTH[@]}" "$API/workflow/get-campaign/$CAMPAIGN_ID" 2>/dev/null | jq -r '(.campaign.movies // []) | length' 2>/dev/null || echo 0)"
if [[ "$ep_count" -gt 0 ]]; then
  echo "→ Episode slots already exist ($ep_count)."
else
  echo "→ Bootstrapping season 1 (gen-movie-season on template)…"
  curl -fsS -X POST "${AUTH[@]}" "${JSON[@]}" \
    -d "$(jq -n --arg mid "$TEMPLATE_MOVIE_ID" '{movieId:$mid}')" \
    "$API/workflow/gen-movie-season" >/dev/null
  for i in $(seq 1 48); do
    sleep 5
    ep_count="$(curl -fsS "${AUTH[@]}" "$API/workflow/get-campaign/$CAMPAIGN_ID" 2>/dev/null | jq -r '(.campaign.movies // []) | length' 2>/dev/null || echo 0)"
    echo "  …poll $i/48: episode slots=$ep_count"
    [[ "$ep_count" -gt 0 ]] && break
  done
  [[ "$ep_count" -gt 0 ]] || { echo "error: season bootstrap produced no episodes within timeout; re-run to resume." >&2; exit 1; }
fi

# ---- done ------------------------------------------------------------------
echo
echo "✓ Setup complete."
echo "  Campaign:   $CAMPAIGN_ID"
echo "  Template:   $TEMPLATE_MOVIE_ID  ($TOTAL cast portraits)"
echo "  Episodes:   $ep_count slot(s) in season 1"
echo "  Soundtrack: $(get_env_key "$SHOW_ENV" SOUNDTRACK_AUDIO_PATH | sed 's#.*/##; s/^$/(picker fallback)/')"
echo "  Trailer:    ${trailer_url:-(none)}"
echo "  Config:     $SHOW_ENV"
echo
echo "Next — generate + render an episode:"
echo "  ./show/showrunner/prepare.sh $SHOW_DIR"
echo "  python3 ./show/showrunner/upload_to_yakyak.py --show $SHOW_DIR"

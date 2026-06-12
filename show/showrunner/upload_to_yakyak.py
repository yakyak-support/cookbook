#!/usr/bin/env python3
"""
upload_to_yakyak.py — push a prepared story into the next available episode slot
of a YakYak campaign on yakyak.ai, then wait for scene generation, attach the
soundtrack, trigger the final render, wait for it to finish, and (optionally)
post to social.

This is the show-AGNOSTIC engine. All show-specific settings (campaign, cast,
soundtrack, volume, …) live in <showDir>/show.env and are selected with --show.
Breaking Bricks News is just one show; see show/showrunner/README.md and
docs/alternative_setups.md.

A Python port of upload_to_yakyak.sh, driving the YakYak API through the
official Python SDK (`yakyak-sdk`, https://github.com/yakyak-support/cookbook).

Usage:
  ./upload_to_yakyak.py --show <showDir> [campaignId] [storyFile] [flags]

Flags:
  --show <showDir>         REQUIRED (or $SHOW_DIR). Directory holding show.env +
                           stories/ (e.g. show/BreakingBricksNews).
  --post                   Post the rendered episode to every social network
                           linked to the campaign (NOT default).
  --post-only              Skip upload + render entirely; just post an
                           already-rendered episode. Implies --post. Target is
                           the MOST RECENTLY RENDERED episode in the campaign
                           (by render time), unless --movie is also passed.
  --movie <movieId>        Explicit movie ID; overrides next-episode picker
                           (works in both default and --post-only modes).
  --volume <N>             Soundtrack volume percentage (overrides show.env VOLUME).
  --soundtrack <audioPath> Override show.env SOUNDTRACK_AUDIO_PATH. Set directly
                           on the movie (verified reachable on CDN first); it
                           does NOT need to be in /workflow/available-soundtracks.
  --skip-finalize          Stop after kicking off screenplay regen (skip the
                           wait-for-scenes + soundtrack + render steps).
  -y, --yes                Skip the pre-post confirmation prompt (for cron /
                           unattended runs). Without it, posting requires a
                           TTY confirmation of the chosen episode + networks.
  -h, --help               Show this help.

Cron / Docker / CI:
  This script is non-interactive-safe (no TTY -> deterministic). For unattended
  runs (token-balance gate, --post + --yes), prebuilt per-language Docker images,
  and the GitHub Actions matrix, see docs/yakyak_upload_usage.md ("Running
  unattended" / "Containerized runs") and docs/alternative_setups.md.

Config (per show, from <showDir>/show.env; CLI overrides where applicable):
  CAMPAIGN_ID            target campaign uuid (required)
  SOUNDTRACK_AUDIO_PATH  audioPath of the soundtrack (optional)
  VOLUME                 soundtrack volume % (default 45)
  MIN_TOKEN_BALANCE      abort threshold (default 2000)
  STORY_GLOB             story filename glob in stories/ (default *_latest_update.md)
  CAST_ALIASES           "Full Name=Alias,Other=Alias" cast map (optional)
  PAT_ENV_KEY            which env var holds the PAT (default YAKYAK_PAT)

Required env (process env, or e2e/.env.bb if present):
  YAKYAK_PAT            Personal Access Token ("yy_live_..."). Must hold the
                        account_management, video_creation, and
                        social_publishing scopes for the full flow. (Override the
                        var name per show with PAT_ENV_KEY; legacy YAKYAK_BB_PAT
                        is still honored.)
Optional:
  YAKYAK_API_URL        (defaults to https://api.yakyak.ai)
  YAKYAK_CDN_URL        (defaults to https://cdn.yakyak.ai)

What it does (mirrors the shell version step-for-step):
  1. Token-balance check (>= MIN_TOKEN_BALANCE). Warn+prompt on TTY, abort non-interactive.
  2. Use the PAT as the bearer token; decode its embedded JWT to get
     the userId (no login round-trip).
  3. get-campaign
  4. Find lowest-(season,episode) movie whose renderedMovieUrl is empty.
     If none and the campaign has movies, create-new-season; if the campaign
     has NO movies at all (fresh/forked, no slots yet), gen-movie-season on the
     template instead (create-new-season can't bootstrap an empty campaign).
     Then poll until episodes appear.
  5. set-movie-metadata (movieId + story-file body as description)
  6. update-movie-social-description (caption + title)
  7. gen-movie-screenplay (kick the regen pipeline)
  8. Poll get-movie until every scene's sceneBurnSubtitle.status == "completed".
  9. set-soundtrack-audio  (configured audioPath, verified on CDN)
 10. set-soundtrack        (volumePercentage)
 11. export-render         (kick concat + soundtrack)
 12. Poll render-history until items[0].finishedAt appears.
 13. If --post: post-movie for every network in /social/campaign-links.

SDK notes
---------
yakyak-sdk 0.0.7 models the request bodies most of this flow needs, so the typed
methods are used for: get-campaign, set-movie-metadata, gen-movie-screenplay,
switch-campaign-mode, set-soundtrack-audio (set_soundtrack_audio_path),
set-soundtrack (volume), export-render, and campaign-links. A typed call that
returns non-2xx raises ApiException, caught at the entrypoint.

A few endpoints still aren't fully modelled, so they go through the SDK's own
low-level transport (`ApiClient.param_serialize` + `call_api`, same host/auth/
pool, raw JSON in/out):
  - create-new-season, gen-movie-season, update-movie-social-description — 0.0.7
    exposes these only as a generic request body (no DTO), so raw is just as
    clean. list-campaign (template lookup for empty-campaign bootstrap) is read
    raw too.
  - get-movie / render-history / available-soundtracks — read as plain dicts
    (nested fields like scene[].sceneBurnSubtitle.status) rather than models.
  - GET /users/{id} — the typed User schema omits `tokenBalance`.
  - post-movie (social) — sends a true empty body and tolerates per-network 4xx.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Optional

import certifi

from yakyak_sdk import (
    ApiClient,
    ApiException,
    Configuration,
    ExportRenderDto,
    GenMovieScreenplayRequestDto,
    SetMovieMetadataDto,
    SetSoundtrackAudioDto,
    SocialApi,
    SoundtrackVolumeRequestDto,
    SwitchCampaignModeDto,
    UsersApi,
    WorkflowApi,
)

# ---- defaults / config -----------------------------------------------------

# Always verify TLS against certifi's CA bundle rather than the interpreter's
# default trust store. The python.org macOS installer ships its own OpenSSL with
# an EMPTY trust store unless the user runs "Install Certificates.command", so a
# fresh machine otherwise fails every HTTPS call with CERTIFICATE_VERIFY_FAILED.
# Pointing at certifi makes the script self-sufficient regardless of that step.
CA_BUNDLE = certifi.where()

# This engine is show-agnostic: per-show settings live in <showDir>/show.env and
# are loaded at runtime (see load_show_config). The constants below are only
# *fallbacks* used when a key is absent from show.env (and a couple are also the
# defaults baked into a show.env by convention).
FALLBACK_VOLUME = 45
FALLBACK_MIN_TOKEN_BALANCE = 2000
# Glob used to find the freshly-prepared story in <showDir>/stories. The prepare
# step writes "<UTC-timestamp>_latest_update.md" by default, so this matches.
FALLBACK_STORY_GLOB = "*_latest_update.md"
# Single shared PAT by default (all demo shows owned by one account). A show may
# override with PAT_ENV_KEY=... in its show.env; we also fall back to the legacy
# YAKYAK_BB_PAT so existing e2e/.env.bb files keep working.
DEFAULT_PAT_ENV_KEY = "YAKYAK_PAT"
LEGACY_PAT_ENV_KEY = "YAKYAK_BB_PAT"
# Scene-generation poll: every 15s for up to 30 min.
SCENE_POLL_INTERVAL = 15
SCENE_POLL_MAX = 120
# Render poll: every 5s up to ~15 min.
RENDER_POLL_INTERVAL = 5
RENDER_POLL_MAX = 180


def die(msg: str, code: int = 1) -> "NoReturn":  # type: ignore[name-defined]
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(code)


# ---- YakYak client wrapper -------------------------------------------------


class YakYak:
    """Thin wrapper over the yakyak-sdk ApiClient.

    Typed SDK methods are used where the spec is complete; everything else goes
    through ``_request`` (the SDK's own low-level transport) so we can send/read
    raw JSON for the endpoints the spec doesn't model.
    """

    def __init__(self, api_base: str, pat: str) -> None:
        cfg = Configuration(host=api_base.rstrip("/"), access_token=pat)
        cfg.ssl_ca_cert = CA_BUNDLE  # verify against certifi (see CA_BUNDLE note)
        self.api_client = ApiClient(cfg)
        self.workflow = WorkflowApi(self.api_client)
        self.users = UsersApi(self.api_client)
        self.social = SocialApi(self.api_client)

    # -- low-level transport (handles the spec-gap endpoints) ----------------

    def _request(self, method: str, path: str, body: Any = None) -> tuple[int, Any]:
        """Send a request via the SDK's configured client. Returns (status, json).

        Does NOT raise on non-2xx — callers inspect the status (the social-post
        loop deliberately tolerates per-network 4xx and keeps going).
        """
        headers = {"Accept": "application/json"}
        if body is not None:
            headers["Content-Type"] = "application/json"
        params = self.api_client.param_serialize(
            method=method,
            resource_path=path,
            header_params=headers,
            body=body,
            auth_settings=["access-token"],
        )
        resp = self.api_client.call_api(*params)
        resp.read()
        data: Any = None
        if resp.data:
            try:
                data = json.loads(resp.data)
            except (ValueError, TypeError):
                data = resp.data.decode("utf-8", "replace")
        return resp.status, data

    def _request_ok(self, method: str, path: str, body: Any = None) -> Any:
        """Like _request but raises on non-2xx (the `curl -fsS` equivalent)."""
        status, data = self._request(method, path, body)
        if not 200 <= status <= 299:
            snippet = json.dumps(data)[:240] if data is not None else ""
            raise RuntimeError(f"{method} {path} -> HTTP {status} {snippet}")
        return data

    # -- typed reads ---------------------------------------------------------

    def get_user(self, user_id: str) -> dict:
        # User schema omits tokenBalance, so read it raw.
        return self._request_ok("GET", f"/users/{user_id}")

    def get_campaign(self) -> list[dict]:
        """Return the campaign's movies (list of dicts, camelCase keys)."""
        resp = self.workflow.workflow_controller_get_campaign(self.campaign_id)
        return list(resp.campaign.movies or [])

    def get_movie(self, movie_id: str) -> Optional[dict]:
        status, data = self._request("GET", f"/workflow/get-movie/{movie_id}")
        return data if 200 <= status <= 299 and isinstance(data, dict) else None

    def render_history(self, movie_id: str) -> Optional[dict]:
        status, data = self._request("GET", f"/workflow/render-history/{movie_id}")
        return data if 200 <= status <= 299 and isinstance(data, dict) else None

    def available_soundtracks(self, movie_id: str) -> list[dict]:
        data = self._request_ok("GET", f"/workflow/available-soundtracks/{movie_id}")
        return data or []

    def campaign_links(self, campaign_id: str):
        return self.social.social_controller_get_campaign_links(campaign_id)

    # -- writes --------------------------------------------------------------

    def switch_campaign_mode(self, mode: str) -> None:
        self.workflow.workflow_controller_switch_campaign_mode(
            SwitchCampaignModeDto.from_dict(
                {"campaignId": self.campaign_id, "mode": mode}
            )
        )

    def resume_movie(self, movie_id: str) -> None:
        """Nudge a movie's pipeline to advance its next incomplete step (mode-
        and season-independent). Used to re-kick a render that stalled or had a
        step fail mid-run — the server re-dispatches/resumes from resolved
        inputs. Best-effort: tolerate non-2xx (e.g. lease_denied when a render
        is genuinely in flight); the next poll re-evaluates."""
        try:
            self._request("POST", "/workflow/resume", {"movieId": movie_id})
        except Exception as e:  # noqa: BLE001 — best effort, never abort the run
            print(f"  ⚠️  resume nudge failed: {e}", file=sys.stderr)

    def template_movie_id(self) -> Optional[str]:
        """The campaign's template (season==null) movie id, via list-campaign.

        get-campaign filters templates out, so the template — the row used to
        bootstrap season 1 — is read from the per-user campaign list instead.
        """
        data = self._request_ok("GET", f"/workflow/list-campaign/{self.user_id}")
        for c in (data or {}).get("campaigns", []) or []:
            if c.get("id") == self.campaign_id:
                return (c.get("template") or {}).get("id") or None
        return None

    def gen_movie_season(self, template_movie_id: str) -> Any:
        # Seed a campaign's first season of numbered episode slots from its
        # template. Raw: 0.0.7 doesn't model this (no DTO).
        return self._request_ok(
            "POST", "/workflow/gen-movie-season", {"movieId": template_movie_id}
        )

    def create_new_season(self) -> Any:
        # Still raw: 0.0.7 models this only as a generic request body (no DTO).
        return self._request_ok(
            "POST", "/workflow/create-new-season", {"campaignId": self.campaign_id}
        )

    def set_movie_metadata(self, movie_id: str, plot: str) -> None:
        # The movie plot lives on movie.plot; SetMovieMetadataDto carries the
        # renamed `plot` field as of yakyak-sdk 0.0.7.
        self.workflow.workflow_controller_set_movie_metadata(
            SetMovieMetadataDto.from_dict({"movieId": movie_id, "plot": plot})
        )

    def update_movie_social_description(
        self, movie_id: str, caption: str, title: str
    ) -> Any:
        # Still raw: 0.0.7 models this only as a generic request body (no DTO).
        body: dict[str, Any] = {"movieId": movie_id}
        if caption:
            body["socialDescription"] = caption
        if title:
            body["socialTitle"] = title
        return self._request_ok(
            "POST", "/workflow/update-movie-social-description", body
        )

    def gen_movie_screenplay(self, movie_id: str) -> Any:
        return self.workflow.workflow_controller_gen_movie_screenplay(
            GenMovieScreenplayRequestDto.from_dict({"movieId": movie_id})
        )

    def set_soundtrack_audio(self, movie_id: str, audio_path: str) -> Any:
        return self.workflow.workflow_controller_set_soundtrack_audio_path(
            SetSoundtrackAudioDto.from_dict(
                {"movieId": movie_id, "audioPath": audio_path}
            )
        )

    def set_soundtrack_volume(self, movie_id: str, volume: int) -> None:
        self.workflow.workflow_controller_update_soundtrack_volume(
            SoundtrackVolumeRequestDto.from_dict(
                {"movieId": movie_id, "volumePercentage": volume}
            )
        )

    def export_render(self, movie_id: str) -> Any:
        return self.workflow.workflow_controller_export_render(
            ExportRenderDto.from_dict({"movieId": movie_id, "force": False})
        )

    def post_movie(self, movie_id: str, connected_network_id: str) -> tuple[int, Any]:
        # Tolerate 4xx so we can report and keep going across networks.
        # No request body: both IDs come from the path. Passing body="" would set
        # Content-Type: application/json and serialize to a literal `""`, which the
        # API's JSON body parser rejects ("... is not valid JSON"). body=None sends
        # a true empty body (no Content-Type), which is what this endpoint expects.
        return self._request(
            "POST", f"/social/post-movie/{movie_id}/{connected_network_id}", body=None
        )


# ---- credentials -----------------------------------------------------------


def load_env_file(env_file: Path) -> dict[str, str]:
    """Parse a KEY=VALUE env file (shell-style), stripping quotes/comments."""
    env: dict[str, str] = {}
    for raw in env_file.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export ") :].lstrip()
        if "=" not in line:
            continue
        key, val = line.split("=", 1)
        key = key.strip()
        val = val.strip()
        if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
            val = val[1:-1]
        env[key] = val
    return env


def load_show_config(show_dir: Path) -> dict[str, str]:
    """Load <showDir>/show.env (KEY=VALUE). Required — a show without it is an error."""
    cfg_file = show_dir / "show.env"
    if not cfg_file.is_file():
        die(
            f"no show config at {cfg_file}. Every show needs a show.env "
            "(see show/showrunner/README.md or an existing show for the keys)."
        )
    return load_env_file(cfg_file)


def parse_cast_aliases(spec: str) -> dict[str, str]:
    """Parse CAST_ALIASES="Full Name=Alias,Other=Alias" into an ordered dict.

    Order is preserved (Python dicts are insertion-ordered) so substring matches
    are tested in the author's intended priority, mirroring the old map_short
    if/elif chain.
    """
    aliases: dict[str, str] = {}
    for pair in spec.split(","):
        pair = pair.strip()
        if not pair or "=" not in pair:
            continue
        needle, alias = pair.split("=", 1)
        aliases[needle.strip()] = alias.strip()
    return aliases


def decode_pat_user_id(pat: str) -> str:
    """base64url-decode the embedded JWT payload and return its `.id` claim."""
    jwt = pat[len("yy_live_") :] if pat.startswith("yy_live_") else pat
    parts = jwt.split(".")
    if len(parts) < 2:
        return ""
    payload = parts[1]
    payload += "=" * (-len(payload) % 4)  # pad to a multiple of 4
    try:
        decoded = base64.urlsafe_b64decode(payload)
        return json.loads(decoded).get("id", "") or ""
    except (ValueError, json.JSONDecodeError):
        return ""


# ---- story file -> description converter -----------------------------------


def map_short(name: str, aliases: dict[str, str]) -> str:
    """Map a leading-character full name to the screenplay alias.

    `aliases` is the show's CAST_ALIASES (substring -> alias, in priority order).
    Falls back to the first whitespace-delimited token when nothing matches, so an
    empty map degrades to "first name" behaviour.
    """
    for needle, alias in aliases.items():
        if needle in name:
            return alias
    return name.split(" ")[0] if name else ""


def story_to_description(story_text: str, aliases: dict[str, str]) -> str:
    """Collapse the markdown scenes into the flat bullet shape the UI POSTs.

      - <scene 1 prose one line> Bob says: "<dialog>"

        - <scene 2 prose one line> Trump says: "<dialog>"
        ...

    Anything before the first "## Scene N" header is dropped.
    """
    parts: list[str] = []
    in_scene = False
    prose = ""
    character = ""
    dialog = ""

    def emit() -> None:
        nonlocal prose
        if not in_scene:
            return
        collapsed = re.sub(r"[ \t]+", " ", prose).strip()
        short = map_short(character, aliases)
        if not parts:
            parts.append(f'- {collapsed} {short} says: "{dialog}"')
        else:
            parts.append(f'\n\n  - {collapsed} {short} says: "{dialog}"')

    for line in story_text.splitlines():
        if line.startswith("## Scene"):
            emit()
            in_scene = True
            prose = ""
            character = ""
            dialog = ""
            continue
        if not in_scene:
            continue
        if line.startswith("**Leading character:**"):
            character = re.sub(r"^\*\*Leading character:\*\*\s*", "", line)
            continue
        if line.startswith("**Dialog:**"):
            d = re.sub(r"^\*\*Dialog:\*\*\s*", "", line)
            d = re.sub(r'^"', "", d)
            d = re.sub(r'"\s*$', "", d)
            dialog = d
            continue
        if line != "":
            prose = line if prose == "" else f"{prose} {line}"
    emit()
    return "".join(parts)


def extract_headlines(story_text: str) -> tuple[str, str]:
    """Return (social_caption, headlines_only) from the '## Headlines' section.

    Caption keeps the section title as its first line; headlines_only is just the
    bullet text (better LLM signal). Section ends at the next '## ' heading.
    """
    caption_lines: list[str] = []
    headline_lines: list[str] = []
    in_h = False
    for line in story_text.splitlines():
        if line.startswith("## Headlines"):
            caption_lines.append(re.sub(r"^## ", "", line))
            in_h = True
            continue
        if line.startswith("## "):
            in_h = False
            continue
        if in_h and line.startswith("- "):
            text = line[2:]
            caption_lines.append(text)
            headline_lines.append(text)
    return "\n".join(caption_lines), "\n".join(headline_lines)


def generate_social_title(headlines_only: str) -> str:
    """Punchy <=50-char title via `claude -p`, falling back to the first headline."""
    title = ""
    if headlines_only and shutil_which("claude"):
        print("→ Generating social title from headlines via claude -p (50 char max)")
        prompt = (
            "Read these news headlines and write ONE punchy social-post headline "
            "of MAX 50 characters that captures the day's top story. Output ONLY "
            "the headline text — no quotes, no preamble, no markdown, no trailing "
            "period.\n\nHeadlines:\n" + headlines_only
        )
        try:
            raw = subprocess.run(
                ["claude", "-p", prompt, "--allowed-tools", "", "--output-format", "text"],
                capture_output=True,
                text=True,
                timeout=120,
            ).stdout
        except (subprocess.SubprocessError, OSError):
            raw = ""
        cleaned = raw.replace("\r", "").strip()
        cleaned = re.sub(r'^["\'`]|["\'`]$', "", cleaned).strip()
        for ln in cleaned.splitlines():
            if ln.strip():
                title = ln.strip()
                break

    if not title:
        # Fallback: first headline bullet, trimmed.
        for ln in headlines_only.splitlines():
            if ln.strip():
                title = ln.strip()
                break

    if len(title) > 50:
        title = title[:50]
    return title


def shutil_which(name: str) -> Optional[str]:
    import shutil

    return shutil.which(name)


# ---- episode pickers -------------------------------------------------------


def pick_next_episode(movies: list[dict]) -> Optional[dict]:
    """Lowest-(season,episode) movie whose renderedMovieUrl is empty.

    NOTE: do NOT also gate on status != 'completed' — every episode in this
    campaign is status 'completed' (that field tracks episode *generation*, not
    rendering), so adding it matches nothing and wrongly spins up a new season.
    """
    candidates = [m for m in movies if not (m.get("renderedMovieUrl") or "")]
    if not candidates:
        return None
    candidates.sort(key=lambda m: (m.get("season"), m.get("episode")))
    return candidates[0]


def pick_latest_rendered(yy: YakYak, movies: list[dict]) -> Optional[dict]:
    """MOST RECENTLY RENDERED movie (by actual render time).

    We deliberately do NOT sort by (season, episode): season numbers are not
    chronological here (seeded demo seasons sit numerically above the live line).
    Render time isn't in get-campaign, so for each rendered movie we read
    render-history items[0].finishedAt and keep the newest (ISO-8601 UTC strings
    compare lexicographically).
    """
    rendered = [m for m in movies if (m.get("renderedMovieUrl") or "")]
    rendered.sort(key=lambda m: (m.get("season"), m.get("episode")))
    if not rendered:
        return None

    best: Optional[dict] = None
    best_ts = ""
    for m in rendered:
        rh = yy.render_history(m["id"])
        items = (rh or {}).get("items") or []
        ts = items[0].get("finishedAt") if items else None
        if not ts:
            print(
                f"  …skipping S{m.get('season')}E{m.get('episode')} "
                f"(no render-history finishedAt)",
                file=sys.stderr,
            )
            continue
        if not best_ts or ts > best_ts:
            best_ts = ts
            best = m
    if best_ts:
        print(f"  newest render: {best_ts}", file=sys.stderr)
    return best


def lookup_movie(movies: list[dict], movie_id: str) -> Optional[dict]:
    return next((m for m in movies if m.get("id") == movie_id), None)


# ---- CLI -------------------------------------------------------------------


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="upload_to_yakyak.py",
        description="Push a prepared story into a YakYak campaign and render it.",
        add_help=True,
    )
    # --show <dir> selects which show's config (show.env) and stories/ to use.
    # Defaults to $SHOW_DIR so a containerized run can set it once via the env.
    p.add_argument(
        "--show",
        dest="show",
        default=os.environ.get("SHOW_DIR"),
        metavar="showDir",
        help="Path to the show directory (contains show.env + stories/).",
    )
    # campaign_id / --volume / --soundtrack default to None so show.env supplies
    # them; an explicit value on the CLI still wins.
    p.add_argument("campaign_id", nargs="?", default=None)
    p.add_argument("story_file", nargs="?", default=None)
    p.add_argument("--post", action="store_true", help="Post to every linked network.")
    p.add_argument(
        "--post-only",
        action="store_true",
        help="Skip upload+render; just post the most-recently-rendered episode.",
    )
    p.add_argument("--skip-finalize", action="store_true")
    p.add_argument("-y", "--yes", action="store_true", help="Skip the pre-post prompt.")
    p.add_argument("--movie", default="", metavar="movieId")
    p.add_argument("--volume", type=int, default=None, metavar="N")
    p.add_argument("--soundtrack", default=None, metavar="audioPath")
    args = p.parse_args(argv)

    if args.post_only:
        args.post = True  # --post-only implies --post
    if args.post_only and args.skip_finalize:
        p.error("--post-only and --skip-finalize are mutually exclusive")
    if args.volume is not None and not 0 <= args.volume <= 100:
        p.error(f"--volume must be an integer between 0 and 100 (got '{args.volume}')")
    if not args.show:
        p.error("--show <showDir> is required (or set $SHOW_DIR).")
    return args


def confirm(prompt: str) -> bool:
    try:
        return input(prompt).strip().lower().startswith("y")
    except EOFError:
        return False


# ---- main ------------------------------------------------------------------


def main(argv: list[str]) -> int:
    args = parse_args(argv)

    script_dir = Path(__file__).resolve().parent          # show/showrunner
    repo_root = script_dir.parent.parent                   # repo root (yakyak/)
    show_dir = Path(args.show).resolve()
    if not show_dir.is_dir():
        die(f"--show dir not found: {show_dir}")
    stories_dir = show_dir / "stories"

    # ---- load per-show config (show.env) -----------------------------------
    cfg = load_show_config(show_dir)
    # CLI > show.env > fallback. campaign_id is positional; volume/soundtrack flags.
    args.campaign_id = args.campaign_id or cfg.get("CAMPAIGN_ID")
    if not args.campaign_id:
        die(f"CAMPAIGN_ID not set in {show_dir / 'show.env'} (and none on CLI).")
    if args.volume is None:
        args.volume = int(cfg.get("VOLUME") or FALLBACK_VOLUME)
    args.soundtrack = args.soundtrack or cfg.get("SOUNDTRACK_AUDIO_PATH") or ""
    args.min_token = int(cfg.get("MIN_TOKEN_BALANCE") or FALLBACK_MIN_TOKEN_BALANCE)
    story_glob = cfg.get("STORY_GLOB") or FALLBACK_STORY_GLOB
    args.cast_aliases = parse_cast_aliases(cfg.get("CAST_ALIASES") or "")
    pat_env_key = cfg.get("PAT_ENV_KEY") or DEFAULT_PAT_ENV_KEY
    print(f"→ Show: {show_dir.name}  (campaign {args.campaign_id})")

    # ---- credentials -------------------------------------------------------
    # PAT may come from the process env (cron/CI) OR e2e/.env.bb (local). The file
    # is optional: if the env var is set we don't need it. Try the show's configured
    # key first, then the legacy YAKYAK_BB_PAT so existing setups keep working.
    env_file = repo_root / "e2e" / ".env.bb"
    file_env = load_env_file(env_file) if env_file.is_file() else {}

    def resolve(key: str) -> str:
        return os.environ.get(key) or file_env.get(key) or ""

    pat = resolve(pat_env_key) or resolve(LEGACY_PAT_ENV_KEY)
    api = resolve("YAKYAK_API_URL") or "https://api.yakyak.ai"
    cdn_base = resolve("YAKYAK_CDN_URL") or "https://cdn.yakyak.ai"

    if not pat:
        die(
            f"no PAT found. Set ${pat_env_key} in the environment, or put it in "
            f"{env_file}."
        )
    if not pat.startswith("yy_live_"):
        die(f"${pat_env_key} does not look like a PAT (expected 'yy_live_…')")

    # ---- pick story file (upload+render only) ------------------------------
    story_file: Optional[Path] = None
    if not args.post_only:
        if args.story_file:
            story_file = Path(args.story_file)
        else:
            if not stories_dir.is_dir():
                die(
                    f"no stories dir at {stories_dir}. Run "
                    f"showrunner/prepare.sh {show_dir} first, or pass a path."
                )
            candidates = sorted(stories_dir.glob(story_glob))
            if not candidates:
                die(f"no {story_glob} files in {stories_dir}")
            story_file = candidates[-1]

        if not story_file.is_file():
            die(f"story file not found: {story_file}")
        print(f"→ Story file: {story_file} ({story_file.stat().st_size} bytes)")

    # ---- authenticate (PAT) ------------------------------------------------
    yy = YakYak(api, pat)
    yy.campaign_id = args.campaign_id  # type: ignore[attr-defined]
    user_id = decode_pat_user_id(pat)
    if not user_id:
        die(f"could not extract userId from ${pat_env_key} (malformed token?)")
    yy.user_id = user_id  # type: ignore[attr-defined]  # needed for list-campaign (template lookup)
    print(f"→ Authenticated via PAT (userId {user_id})")

    # ---- token balance gate ------------------------------------------------
    if not args.post_only:
        print(f"→ GET /users/{user_id}  (token-balance check)")
        user = yy.get_user(user_id)
        token_balance = int(user.get("tokenBalance") or 0)
        print(f"  tokenBalance={token_balance}  (minimum {args.min_token})")
        if token_balance < args.min_token:
            print(f"⚠️  Insufficient tokens: {token_balance} < {args.min_token}")
            if sys.stdin.isatty():
                if confirm("    Continue anyway? [y/N] "):
                    print("    proceeding at user's request")
                else:
                    print("    aborted by user")
                    return 1
            else:
                print("    non-interactive (no TTY) → aborting.", file=sys.stderr)
                return 1

    # ---- ensure auto-chain: basic during the run, pro restored on exit -----
    # 'basic' makes the render pipeline auto-chain; 'pro' stops after the
    # screenplay for manual UI stepping. We need 'basic' to run unattended, and
    # restore 'pro' on exit (success OR error). --post-only doesn't render.
    #
    # switch-campaign-mode is OWNER-LOCKED: a non-owner PAT 403s. If we limped on
    # in 'pro' the scene auto-chain never fires and the wait gate hangs forever,
    # so verify the switch took (the call raises on 403) — retry once, then abort
    # with an actionable error rather than hang later.
    switched_to_basic = False
    if not args.post_only:
        for attempt in (1, 2):
            try:
                yy.switch_campaign_mode("basic")
                switched_to_basic = True
                break
            except Exception as e:  # noqa: BLE001
                print(
                    f"⚠️  Could not switch campaign to basic (attempt {attempt}/2): {e}",
                    file=sys.stderr,
                )
        if not switched_to_basic:
            print(
                "error: could not enable basic mode — campaign still pro; check "
                f"that the PAT owns campaign {args.campaign_id}",
                file=sys.stderr,
            )
            return 1
        print("→ Campaign mode → basic (auto-chain enabled for this run)")

    try:
        return run(yy, args, story_file, cdn_base)
    finally:
        if switched_to_basic:
            print("→ Restoring campaign mode → pro", file=sys.stderr)
            try:
                yy.switch_campaign_mode("pro")
            except Exception:  # noqa: BLE001
                print(
                    "⚠️  Failed to restore pro mode — set it manually if needed",
                    file=sys.stderr,
                )


def run(yy: YakYak, args: argparse.Namespace, story_file: Optional[Path], cdn_base: str) -> int:
    campaign_id = args.campaign_id

    # ---- pick target episode ----------------------------------------------
    print(f"→ Fetching campaign {campaign_id}")
    movies = yy.get_campaign()
    print(f"  campaign has {len(movies)} movie(s)")

    if args.movie:
        target = lookup_movie(movies, args.movie)
        if not target:
            die(f"--movie {args.movie} not found in campaign {campaign_id}")
    elif args.post_only:
        print("→ Finding most recently rendered episode (checking render-history)…")
        target = pick_latest_rendered(yy, movies)
        if not target:
            die("--post-only: no movie in campaign has a renderedMovieUrl")
    else:
        target = pick_next_episode(movies)
        if not target:
            # Two distinct "no episode to fill" cases:
            #  - movies non-empty → a season exists but every slot is rendered;
            #    create-new-season adds the next season (needs an existing episode).
            #  - movies empty → a fresh/forked campaign has NO numbered slots yet.
            #    create-new-season can't bootstrap from nothing (it 500s), so seed
            #    season 1 from the template via gen-movie-season (as setup_show.sh
            #    does). get-campaign filters the template out, so it's found via
            #    list-campaign.
            if movies:
                print("→ No available episode in current season(s); creating new season")
                resp = yy.create_new_season()
                print(f"  {json.dumps(resp) if resp is not None else 'ok'}")
            else:
                print("→ Campaign has no episode slots; bootstrapping season 1 from template")
                template_id = yy.template_movie_id()
                if not template_id:
                    die(f"campaign {campaign_id} has no template movie to bootstrap from")
                print(f"  template movie {template_id} → gen-movie-season")
                resp = yy.gen_movie_season(template_id)
                print(f"  {json.dumps(resp) if resp is not None else 'ok'}")
            print("→ Polling for episodes (up to ~3 minutes)…")
            for i in range(1, 37):
                time.sleep(5)
                movies = yy.get_campaign()
                target = pick_next_episode(movies)
                if target:
                    print(f"  episodes appeared ({len(movies)} total)")
                    break
                print(f"  …still waiting ({i}/36)")
            if not target:
                die("season bootstrap did not produce episodes within timeout")

    movie_id = target["id"]
    season = target.get("season")
    episode = target.get("episode")
    title = target.get("title")
    print(f'→ Target episode: S{season}E{episode}  "{title}"  ({movie_id})')

    if not args.post_only:
        rc = upload_and_render(yy, args, story_file, movie_id, season, episode, title, cdn_base)
        if rc != 0:
            return rc

    # ---- optional: post to social -----------------------------------------
    if args.post:
        rc = post_to_social(yy, args, campaign_id, movie_id, season, episode, title)
        if rc != 0:
            return rc
    else:
        print("→ skipping social posting (pass --post to enable)")

    print()
    print("✓ Done.")
    print(f"  Movie:    {movie_id}  (S{season}E{episode} - {title})")
    if not args.post_only:
        print(f"  Story:    {story_file}")
        print(f"  Volume:   {args.volume}%")
    print(f"  Preview:  https://yakyak.ai/export?movieId={movie_id}")
    return 0


def upload_and_render(
    yy: YakYak,
    args: argparse.Namespace,
    story_file: Optional[Path],
    movie_id: str,
    season: Any,
    episode: Any,
    title: Any,
    cdn_base: str,
) -> int:
    story_text = story_file.read_text()  # type: ignore[union-attr]

    # ---- description -------------------------------------------------------
    description = story_to_description(story_text, args.cast_aliases)
    if not description:
        print(
            f"error: converter produced an empty description from {story_file}",
            file=sys.stderr,
        )
        print("       (no '## Scene N' headers were found)", file=sys.stderr)
        return 1

    print("→ POST /workflow/set-movie-metadata")
    yy.set_movie_metadata(movie_id, description)
    print("  ok")

    # ---- social caption + title -------------------------------------------
    social_caption, headlines_only = extract_headlines(story_text)
    social_title = generate_social_title(headlines_only)

    if social_caption or social_title:
        if social_title:
            print(f'  socialTitle: "{social_title}" ({len(social_title)} chars)')
        print("→ POST /workflow/update-movie-social-description")
        yy.update_movie_social_description(movie_id, social_caption, social_title)
        print("  ok")
    else:
        print("→ skipping social overrides (no '## Headlines' section in story file)")

    # ---- trigger screenplay regen -----------------------------------------
    print("→ POST /workflow/gen-movie-screenplay")
    yy.gen_movie_screenplay(movie_id)
    print("  ok")

    if args.skip_finalize:
        print()
        print("✓ Done (--skip-finalize); soundtrack + render NOT triggered.")
        print(f"  Movie:    {movie_id}  (S{season}E{episode} - {title})")
        print(f"  Preview:  https://yakyak.ai/export?movieId={movie_id}")
        sys.exit(0)

    # ---- drive all scenes to a burned state -------------------------------
    # A scene is ready when sceneBurnSubtitle.status == "completed". Rather than
    # hard-fail on a single stuck/failed scene (which a deploy/restart can cause
    # mid-render, even though the server then self-recovers), detect stalls and
    # re-kick the pipeline — mirrors setup_show.sh's drive-loop:
    #   - progress is measured across ALL four scene phases (subtitle/image/
    #     movie/burn), not just burns, so a stall at any phase is detected;
    #   - on a real stall (no progress for several polls) OR any 'failed' step,
    #     re-assert basic mode (in case it was switched) AND resume the movie;
    #   - bail only when the overall poll window is exhausted.
    phases = ("sceneSubtitleMovie", "sceneImage", "sceneMovie", "sceneBurnSubtitle")

    def _phase_status(scene: dict, phase: str) -> str:
        return (scene.get(phase) or {}).get("status") or ""

    max_min = SCENE_POLL_INTERVAL * SCENE_POLL_MAX // 60
    print(f"→ Waiting for scene generation (poll every {SCENE_POLL_INTERVAL}s, up to {max_min} min)…")
    scenes_ready = False
    last_prog = -1
    stall = 0
    for i in range(1, SCENE_POLL_MAX + 1):
        time.sleep(SCENE_POLL_INTERVAL)
        movie = yy.get_movie(movie_id)
        if not movie:
            print(f"  …poll {i}/{SCENE_POLL_MAX}: get-movie returned empty, retrying")
            continue
        scenes = movie.get("scene") or []
        scene_count = len(scenes)
        if scene_count == 0:
            print(f"  …poll {i}/{SCENE_POLL_MAX}: screenplay not yet generated")
            continue

        done = sum(1 for s in scenes if _phase_status(s, "sceneBurnSubtitle") == "completed")
        # Completed steps across all four scene phases — the stall signal.
        prog = sum(1 for s in scenes for p in phases if _phase_status(s, p) == "completed")
        failed = sum(
            1
            for s in scenes
            if any(_phase_status(s, p) == "failed"
                   for p in ("sceneBurnSubtitle", "sceneImage", "sceneMovie"))
        )
        print(
            f"  …poll {i}/{SCENE_POLL_MAX}: {done}/{scene_count} burned "
            f"(steps {prog}/{scene_count * 4}, failed {failed})"
        )
        if done == scene_count:
            scenes_ready = True
            print(f"  all {scene_count} scene(s) burned and ready")
            break
        if prog > last_prog:
            last_prog = prog
            stall = 0
        else:
            stall += 1
        # Re-kick on a real stall, or immediately if something is in 'failed'.
        if stall >= 4 or failed > 0:
            print("  …stalled/failed — re-asserting basic mode + resume")
            try:
                yy.switch_campaign_mode("basic")
            except Exception:  # noqa: BLE001 — best-effort re-assert
                pass
            yy.resume_movie(movie_id)
            stall = 0

    if not scenes_ready:
        print(
            "error: scenes did not complete within timeout. Run again with "
            "--skip-finalize and finalize later.",
            file=sys.stderr,
        )
        return 1

    # ---- pick + assign soundtrack -----------------------------------------
    # We set the configured soundtrack path DIRECTLY; the render reuses it
    # straight from the CDN by path, so it does NOT need to appear in
    # /workflow/available-soundtracks (a global, recency-capped picker that the
    # BBN intro track ages out of). We only consult the picker as a last resort.
    chosen_audio_path = args.soundtrack
    if chosen_audio_path:
        url = f"{cdn_base.rstrip('/')}/{chosen_audio_path}"
        http_code = head_status(url)
        if not (http_code and 200 <= http_code <= 299):
            print(
                f"error: configured soundtrack not reachable on CDN (HTTP {http_code}):",
                file=sys.stderr,
            )
            print(f"       {url}", file=sys.stderr)
            print(
                "       Pass a valid --soundtrack <audioPath> or fix "
                "DEFAULT_SOUNDTRACK_AUDIO_PATH.",
                file=sys.stderr,
            )
            return 1
        print(f"→ Using configured soundtrack (verified on CDN, HTTP {http_code})")
    else:
        print(
            "→ No soundtrack configured; falling back to "
            f"/workflow/available-soundtracks/{movie_id}"
        )
        soundtracks = yy.available_soundtracks(movie_id)
        chosen_audio_path = soundtracks[0].get("audioPath") if soundtracks else ""
        if not chosen_audio_path:
            die(f"no soundtrack configured and none available for movie {movie_id}")
        print(f"  picker items[0]: {chosen_audio_path}")
    print(f"  audioPath: {chosen_audio_path}")

    print("→ POST /workflow/set-soundtrack-audio")
    yy.set_soundtrack_audio(movie_id, chosen_audio_path)
    print("  ok")

    # ---- set volume --------------------------------------------------------
    print(f"→ POST /workflow/set-soundtrack  (volumePercentage={args.volume})")
    yy.set_soundtrack_volume(movie_id, args.volume)
    print("  ok")

    # ---- trigger final render + wait --------------------------------------
    print("→ POST /workflow/export-render")
    yy.export_render(movie_id)
    print("  ok")

    max_min = RENDER_POLL_INTERVAL * RENDER_POLL_MAX // 60
    print(f"→ Waiting for render to finish (poll every {RENDER_POLL_INTERVAL}s, up to {max_min} min)…")
    render_url = ""
    for i in range(1, RENDER_POLL_MAX + 1):
        time.sleep(RENDER_POLL_INTERVAL)
        rh = yy.render_history(movie_id)
        if not rh:
            print(f"  …poll {i}/{RENDER_POLL_MAX}: render-history returned empty, retrying")
            continue
        items = rh.get("items") or []
        finished_at = items[0].get("finishedAt") if items else None
        if finished_at:
            render_url = items[0].get("soundtrackedMovieUrl") or ""
            print(f"  finished at {finished_at}")
            print(f"  {render_url}")
            break
        print(f"  …poll {i}/{RENDER_POLL_MAX}: still rendering")

    if not render_url:
        print(
            "error: render did not finish within timeout. Skipping --post (if set).",
            file=sys.stderr,
        )
        return 1
    return 0


def post_to_social(
    yy: YakYak,
    args: argparse.Namespace,
    campaign_id: str,
    movie_id: str,
    season: Any,
    episode: Any,
    title: Any,
) -> int:
    print(f"→ GET /social/campaign-links/{campaign_id}")
    links = yy.campaign_links(campaign_id)
    link_rows = list(links.campaign_links or [])
    print(f"  {links.count or 0} linked network(s)")

    # ---- confirmation gate -------------------------------------------------
    network_list = ", ".join(
        (r.social_network_name or "") for r in link_rows if r.social_network_name
    )
    print()
    print("  ┌─ About to POST to social ──────────────────────────────")
    print(f'  │ Episode:  S{season}E{episode}  "{title}"')
    print(f"  │ Movie:    {movie_id}")
    print(f"  │ Networks: {network_list or '<none linked>'}")
    print(f"  │ Preview:  https://yakyak.ai/export?movieId={movie_id}")
    print("  └────────────────────────────────────────────────────────")
    if args.yes:
        print("  --yes given → posting without confirmation")
    elif sys.stdin.isatty():
        if confirm("  Post THIS episode to the networks above? [y/N] "):
            print("  confirmed; posting")
        else:
            print("  aborted by user — nothing was posted")
            return 1
    else:
        print(
            "error: refusing to post non-interactively without --yes "
            "(episode picker is heuristic).",
            file=sys.stderr,
        )
        print(
            "       Re-run on a TTY to confirm, or pass --yes/-y to post unattended.",
            file=sys.stderr,
        )
        return 1

    post_ok = 0
    post_fail = 0
    for r in link_rows:
        conn_id = r.connected_network_id
        network_name = r.social_network_name
        if not conn_id:
            continue
        print(f"→ POST /social/post-movie/{movie_id}/{conn_id}  ({network_name})")
        status, body = yy.post_movie(movie_id, conn_id)
        if 200 <= status <= 299:
            post_ok += 1
            print(f"  ✓ {status}")
        else:
            post_fail += 1
            snippet = (json.dumps(body) if not isinstance(body, str) else body)[:240]
            print(f"  ✗ {status}  {snippet}")

    print(f"  social posting: {post_ok} ok, {post_fail} failed")
    return 0


def head_status(url: str) -> Optional[int]:
    """Return the HTTP status of a HEAD request, or None on transport error.

    cdn.yakyak.ai sits behind Cloudflare, whose bot protection 403s the default
    "Python-urllib/x.y" User-Agent (the same URL returns 200 in a browser or
    with any normal UA). Send a browser-like UA so the reachability check sees
    what the render pipeline / browser would.
    """
    req = urllib.request.Request(
        url,
        method="HEAD",
        headers={"User-Agent": "Mozilla/5.0 (compatible; yakyak-uploader/1.0)"},
    )
    ctx = ssl.create_default_context(cafile=CA_BUNDLE)
    try:
        with urllib.request.urlopen(req, timeout=30, context=ctx) as resp:
            return resp.status
    except urllib.error.HTTPError as e:
        return e.code
    except (urllib.error.URLError, OSError):
        return None


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        print("\naborted", file=sys.stderr)
        sys.exit(130)
    except (RuntimeError, ApiException) as e:
        # RuntimeError = our raw-transport helper; ApiException = a typed SDK call
        # returning non-2xx. Both surface as a clean one-line error.
        die(str(e))

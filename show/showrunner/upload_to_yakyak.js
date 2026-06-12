#!/usr/bin/env node
//
// upload_to_yakyak.js — push a prepared story into the next available episode
// slot of a YakYak campaign on yakyak.ai, then wait for scene generation,
// attach the soundtrack, trigger the final render, wait for it to finish, and
// (optionally) post to social.
//
// Show-AGNOSTIC engine. All show-specific settings (campaign, cast, soundtrack,
// volume, …) live in <showDir>/show.env and are selected with --show. BBN is
// just one show; see show/showrunner/README.md + docs/alternative_setups.md.
//
// A JavaScript port of upload_to_yakyak.sh, driving the official `yakyak-sdk`
// JavaScript client (https://github.com/yakyak-support/cookbook/tree/main/sdk).
//
// Setup (one-time, in this directory):
//   npm install            # pulls yakyak-sdk from npm
//
// Usage:
//   node upload_to_yakyak.js --show <showDir> [campaignId] [storyFile] [flags]
//
// Flags:
//   --show <showDir>         REQUIRED (or $SHOW_DIR). Dir with show.env + stories/.
//   --post                   Post the rendered episode to every social network
//                            linked to the campaign (NOT default).
//   --post-only              Skip upload + render entirely; just post an
//                            already-rendered episode. Implies --post. Target is
//                            the MOST RECENTLY RENDERED episode in the campaign
//                            (by render time), unless --movie is also passed.
//   --movie <movieId>        Explicit movie ID; overrides next-episode picker
//                            (works in both default and --post-only modes).
//   --volume <N>             Soundtrack volume percentage (overrides show.env).
//   --soundtrack <audioPath> Override show.env SOUNDTRACK_AUDIO_PATH. Set directly
//                            on the movie (verified reachable on CDN first); it
//                            does NOT need to be in /workflow/available-soundtracks.
//   --skip-finalize          Stop after kicking off screenplay regen (skip the
//                            wait-for-scenes + soundtrack + render steps).
//   -y, --yes                Skip the pre-post confirmation prompt (for cron /
//                            unattended runs). Without it, posting requires a
//                            TTY confirmation of the chosen episode + networks.
//   -h, --help               Show this help.
//
// Cron / Docker / CI:
//   Non-interactive-safe (no TTY -> deterministic). For unattended runs,
//   prebuilt per-language Docker images, and the GitHub Actions matrix, see
//   docs/yakyak_upload_usage.md and docs/alternative_setups.md.
//
// Config (per show, from <showDir>/show.env; CLI overrides where applicable):
//   CAMPAIGN_ID, SOUNDTRACK_AUDIO_PATH, VOLUME, MIN_TOKEN_BALANCE, STORY_GLOB,
//   CAST_ALIASES ("Full Name=Alias,…"), PAT_ENV_KEY (default YAKYAK_PAT).
//
// Required env (process env, or e2e/.env.bb if present):
//   YAKYAK_PAT            Personal Access Token ("yy_live_…"), the scopes for the
//                         full flow. Override the var name per show with
//                         PAT_ENV_KEY; legacy YAKYAK_BB_PAT is still honored.
// Optional:
//   YAKYAK_API_URL        (defaults to https://api.yakyak.ai)
//   YAKYAK_CDN_URL        (defaults to https://cdn.yakyak.ai)

import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

import { YakYakClient } from 'yakyak-sdk';

import { storyToDescription, buildSocialCaption, buildHeadlinesOnly } from './story-format.js';

// ---- defaults / config -----------------------------------------------------

// Show-agnostic engine: per-show settings live in <showDir>/show.env (loaded at
// runtime). The constants below are only *fallbacks* for absent keys.
const FALLBACK_VOLUME = 45;
const FALLBACK_MIN_TOKEN_BALANCE = 2000;
const FALLBACK_STORY_GLOB = '*_latest_update.md';
// Single shared PAT by default; a show may override via PAT_ENV_KEY. Legacy
// YAKYAK_BB_PAT is honored so existing e2e/.env.bb files keep working.
const DEFAULT_PAT_ENV_KEY = 'YAKYAK_PAT';
const LEGACY_PAT_ENV_KEY = 'YAKYAK_BB_PAT';
// Scene-generation poll: every 15s for up to 30 min.
const SCENE_POLL_INTERVAL = 15;
const SCENE_POLL_MAX = 120;
// Render poll: every 5s up to ~15 min.
const RENDER_POLL_INTERVAL = 5;
const RENDER_POLL_MAX = 180;

// ---- tiny helpers ----------------------------------------------------------

const sleep = (secs) => new Promise((r) => setTimeout(r, secs * 1000));

function die(msg) {
  console.error(`error: ${msg}`);
  process.exit(1);
}

function showHelp() {
  // Mirror the shell --help: the header block above, sans comment markers.
  const src = fs.readFileSync(fileURLToPath(import.meta.url), 'utf8').split(/\r?\n/);
  // Lines describing Usage/Flags/Defaults live in the banner; print from the
  // "Usage:" line through the blank line before the imports.
  const start = src.findIndex((l) => l.startsWith('// Usage:'));
  for (let i = start; i < src.length; i++) {
    const l = src[i];
    if (!l.startsWith('//')) break;
    console.log(l.replace(/^\/\/ ?/, ''));
  }
}

async function ask(question) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  try {
    return await new Promise((resolve) => rl.question(question, resolve));
  } finally {
    rl.close();
  }
}

// ---- args ------------------------------------------------------------------

let POST_TO_SOCIAL = false;
let POST_ONLY = false;
let SKIP_FINALIZE = false;
let ASSUME_YES = false;
let MOVIE_ID_OVERRIDE = '';
let SHOW_DIR_ARG = process.env.SHOW_DIR || '';
let VOLUME_ARG = null;       // null => take from show.env
let SOUNDTRACK_ARG = null;   // null => take from show.env
const POS_ARGS = [];

{
  const argv = process.argv.slice(2);
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    switch (a) {
      case '--post': POST_TO_SOCIAL = true; break;
      case '--post-only': POST_ONLY = true; POST_TO_SOCIAL = true; break;
      case '--skip-finalize': SKIP_FINALIZE = true; break;
      case '-y':
      case '--yes': ASSUME_YES = true; break;
      case '--show':
        if (i + 1 >= argv.length) die('--show needs a value');
        SHOW_DIR_ARG = argv[++i];
        break;
      case '--movie':
        if (i + 1 >= argv.length) die('--movie needs a value');
        MOVIE_ID_OVERRIDE = argv[++i];
        break;
      case '--volume':
        if (i + 1 >= argv.length) die('--volume needs a value');
        VOLUME_ARG = argv[++i];
        break;
      case '--soundtrack':
        if (i + 1 >= argv.length) die('--soundtrack needs a value');
        SOUNDTRACK_ARG = argv[++i];
        break;
      case '-h':
      case '--help':
        showHelp();
        process.exit(0);
      case '--':
        for (i++; i < argv.length; i++) POS_ARGS.push(argv[i]);
        break;
      default:
        if (a.startsWith('-')) die(`unknown flag '${a}' (try --help)`);
        POS_ARGS.push(a);
    }
  }
}

if (POST_ONLY && SKIP_FINALIZE) {
  die('--post-only and --skip-finalize are mutually exclusive');
}
if (!SHOW_DIR_ARG) die('--show <showDir> is required (or set $SHOW_DIR).');

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));   // show/showrunner
const REPO_ROOT = path.resolve(SCRIPT_DIR, '..', '..');            // repo root
const SHOW_DIR = path.resolve(SHOW_DIR_ARG);
if (!fs.existsSync(SHOW_DIR)) die(`--show dir not found: ${SHOW_DIR}`);
const STORIES_DIR = path.join(SHOW_DIR, 'stories');

function loadEnvFile(file) {
  const env = {};
  for (const raw of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
    const m = raw.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
    if (!m) continue;
    let v = m[2].trim();
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) {
      v = v.slice(1, -1);
    }
    env[m[1]] = v;
  }
  return env;
}

function loadShowConfig(showDir) {
  const f = path.join(showDir, 'show.env');
  if (!fs.existsSync(f)) {
    die(`no show config at ${f}. Every show needs a show.env (see show/showrunner/README.md).`);
  }
  return loadEnvFile(f);
}

function parseCastAliases(spec) {
  const aliases = new Map();
  for (const pair of (spec || '').split(',')) {
    const p = pair.trim();
    const eq = p.indexOf('=');
    if (eq < 0) continue;
    aliases.set(p.slice(0, eq).trim(), p.slice(eq + 1).trim());
  }
  return aliases;
}

// ---- per-show config (show.env); CLI overrides where applicable ------------
const CFG = loadShowConfig(SHOW_DIR);
const CAMPAIGN_ID = POS_ARGS[0] || CFG.CAMPAIGN_ID;
if (!CAMPAIGN_ID) die(`CAMPAIGN_ID not set in ${path.join(SHOW_DIR, 'show.env')} (and none on CLI).`);
const STORY_FILE_ARG = POS_ARGS[1] || '';
let VOLUME_PERCENTAGE = VOLUME_ARG != null ? VOLUME_ARG : (CFG.VOLUME ?? FALLBACK_VOLUME);
if (!/^\d+$/.test(String(VOLUME_PERCENTAGE)) ||
    Number(VOLUME_PERCENTAGE) < 0 || Number(VOLUME_PERCENTAGE) > 100) {
  die(`volume must be an integer between 0 and 100 (got '${VOLUME_PERCENTAGE}')`);
}
VOLUME_PERCENTAGE = Number(VOLUME_PERCENTAGE);
const SOUNDTRACK_AUDIO_PATH = SOUNDTRACK_ARG != null ? SOUNDTRACK_ARG : (CFG.SOUNDTRACK_AUDIO_PATH || '');
const MIN_TOKEN_BALANCE = Number(CFG.MIN_TOKEN_BALANCE || FALLBACK_MIN_TOKEN_BALANCE);
const STORY_GLOB = CFG.STORY_GLOB || FALLBACK_STORY_GLOB;
const STORY_SUFFIX = STORY_GLOB.replace(/^\*/, '');   // simple "*suffix" glob support
const CAST_ALIASES = parseCastAliases(CFG.CAST_ALIASES);
const PAT_ENV_KEY = CFG.PAT_ENV_KEY || DEFAULT_PAT_ENV_KEY;
console.log(`→ Show: ${path.basename(SHOW_DIR)}  (campaign ${CAMPAIGN_ID})`);

// ---- credentials ----------------------------------------------------------
// PAT from process env (cron/CI) or e2e/.env.bb (local). The file is optional.
const ENV_FILE = path.join(REPO_ROOT, 'e2e', '.env.bb');
const fileEnv = fs.existsSync(ENV_FILE) ? loadEnvFile(ENV_FILE) : {};
const pick = (key) => process.env[key] || fileEnv[key] || '';
const PAT = pick(PAT_ENV_KEY) || pick(LEGACY_PAT_ENV_KEY);
const API = pick('YAKYAK_API_URL') || 'https://api.yakyak.ai';
const CDN_BASE = pick('YAKYAK_CDN_URL') || 'https://cdn.yakyak.ai';

if (!PAT) die(`no PAT found. Set $${PAT_ENV_KEY} in the environment, or put it in ${ENV_FILE}.`);
if (!PAT.startsWith('yy_live_')) {
  die(`$${PAT_ENV_KEY} does not look like a PAT (expected 'yy_live_…')`);
}

// ---- authenticate (PAT) ----------------------------------------------------
// The PAT is sent verbatim as the bearer token; the API strips the prefix and
// verifies the embedded JWT. That JWT's payload carries the userId in its `id`
// claim, so we decode it locally instead of a login round-trip.
function decodePatUserId(pat) {
  const jwt = pat.replace(/^yy_live_/, '');
  const parts = jwt.split('.');
  if (parts.length < 2) return '';
  try {
    const payload = Buffer.from(parts[1], 'base64url').toString('utf8');
    return JSON.parse(payload).id || '';
  } catch {
    return '';
  }
}

const USER_ID = decodePatUserId(PAT);
if (!USER_ID) die('could not extract userId from YAKYAK_BB_PAT (malformed token?)');

// The SDK sends `token` as `Authorization: Bearer <token>`.
const client = new YakYakClient({ baseUrl: API, token: PAT });

console.log(`→ Authenticated via PAT (userId ${USER_ID})`);

// ≤50-char punchy headline via `claude -p`; '' on any failure so the caller
// falls back to the first headline.
function generateSocialTitle(headlinesOnly) {
  if (!headlinesOnly) return '';
  const prompt =
    'Read these news headlines and write ONE punchy social-post headline of MAX 50 characters that captures the day\'s top story. Output ONLY the headline text — no quotes, no preamble, no markdown, no trailing period.\n\n' +
    `Headlines:\n${headlinesOnly}`;
  let raw = '';
  try {
    raw = execFileSync('claude', ['-p', prompt, '--allowed-tools', '', '--output-format', 'text'],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
  } catch {
    return '';
  }
  let t = raw
    .replace(/\r/g, '')
    .replace(/^\s+/, '')
    .replace(/\s+$/, '')
    .replace(/^"/, '').replace(/"$/, '')
    .replace(/^'/, '').replace(/'$/, '')
    .replace(/^`/, '').replace(/`$/, '');
  // First non-empty line.
  t = (t.split('\n').find((l) => l.trim() !== '') || '').trim();
  return t;
}

// ---- campaign helpers ------------------------------------------------------

async function fetchCampaign() {
  const resp = await client.workflow.getCampaign({ campaignId: CAMPAIGN_ID });
  return resp.campaign || {};
}

// Switch the campaign's mode (basic|pro). 'basic' makes the render pipeline
// auto-chain unattended; 'pro' stops after the screenplay for manual stepping.
async function switchCampaignMode(mode) {
  await client.workflow.switchCampaignMode({ switchCampaignModeDto: { campaignId: CAMPAIGN_ID, mode } });
}

// Nudge a movie's pipeline to advance its next incomplete step (mode- and
// season-independent). Used to re-kick a render that stalled or had a step fail
// mid-run — the server re-dispatches/resumes from resolved inputs. Best-effort.
async function resumeMovie(movieId) {
  try {
    await client.workflow.resumeMovie({ resumeMovieDto: { movieId } });
  } catch (e) {
    // lease_denied (a render is genuinely in flight) and transient errors are
    // expected here — the next poll re-evaluates. Don't abort the run.
    console.error(`  ⚠️  resume nudge failed: ${e?.message || e}`);
  }
}

let switchedToBasic = false;
let proRestored = false;
async function restoreProMode() {
  if (!switchedToBasic || proRestored) return;
  proRestored = true;
  console.error('→ Restoring campaign mode → pro');
  try {
    await switchCampaignMode('pro');
  } catch {
    console.error('⚠️  Failed to restore pro mode — set it manually if needed');
  }
}

// Lowest-(season,episode) movie whose renderedMovieUrl is empty. Do NOT gate on
// status — every episode here is 'completed' (that field tracks generation, not
// rendering). Returns {movieId,season,episode,title} or null.
function pickNextEpisode(movies) {
  const avail = movies
    .filter((m) => (m.renderedMovieUrl || '') === '')
    .sort((a, b) => (Number(a.season) - Number(b.season)) || (Number(a.episode) - Number(b.episode)));
  const m = avail[0];
  return m ? { movieId: m.id, season: m.season, episode: m.episode, title: m.title } : null;
}

// MOST RECENTLY RENDERED movie by actual render time. Season numbers are NOT
// chronological here (seeded demo seasons sit numerically above the live line),
// so we read render-history per rendered movie and keep the newest finishedAt.
async function pickLatestRendered(movies) {
  const rendered = movies
    .filter((m) => (m.renderedMovieUrl || '') !== '')
    .sort((a, b) => (Number(a.season) - Number(b.season)) || (Number(a.episode) - Number(b.episode)));

  if (rendered.length === 0) return null;

  let best = null;
  let bestTs = '';
  for (const m of rendered) {
    let ts = '';
    try {
      const rh = await client.workflow.listRenderHistory({ movieId: m.id });
      ts = rh?.items?.[0]?.finishedAt || '';
    } catch {
      ts = '';
    }
    if (!ts) {
      console.error(`  …skipping S${m.season}E${m.episode} "${m.title}" (no render-history finishedAt)`);
      continue;
    }
    if (!bestTs || ts > bestTs) {
      bestTs = ts;
      best = m;
    }
  }
  if (bestTs) console.error(`  newest render: ${bestTs}`);
  return best ? { movieId: best.id, season: best.season, episode: best.episode, title: best.title } : null;
}

function lookupMovieInCampaign(movies, mid) {
  const m = movies.find((x) => x.id === mid);
  return m ? { movieId: m.id, season: m.season, episode: m.episode, title: m.title } : null;
}

// ---- main ------------------------------------------------------------------

async function run() {
  // ---- pick story file -----------------------------------------------------
  let STORY_FILE = '';
  if (!POST_ONLY) {
    if (STORY_FILE_ARG) {
      STORY_FILE = STORY_FILE_ARG;
    } else {
      if (!fs.existsSync(STORIES_DIR)) {
        die(`no stories dir at ${STORIES_DIR}. Run showrunner/prepare.sh ${SHOW_DIR} first, or pass a path.`);
      }
      const candidates = fs.readdirSync(STORIES_DIR)
        .filter((f) => f.endsWith(STORY_SUFFIX))
        .sort();
      STORY_FILE = candidates.length ? path.join(STORIES_DIR, candidates[candidates.length - 1]) : '';
      if (!STORY_FILE) die(`no ${STORY_GLOB} files in ${STORIES_DIR}`);
    }

    if (!fs.existsSync(STORY_FILE)) die(`story file not found: ${STORY_FILE}`);
    const bytes = fs.statSync(STORY_FILE).size;
    console.log(`→ Story file: ${STORY_FILE} (${bytes} bytes)`);
  }

  // ---- token balance gate --------------------------------------------------
  // Posting doesn't burn tokens, so the gate only fires on upload+render runs.
  // The typed `findOne` model omits tokenBalance, so read the raw JSON.
  if (!POST_ONLY) {
    console.log(`→ GET /users/${USER_ID}  (token-balance check)`);
    const rawResp = await client.users.findOneRaw({ id: USER_ID });
    const userJson = await rawResp.raw.json();
    const tokenBalance = Number(userJson.tokenBalance || 0);
    console.log(`  tokenBalance=${tokenBalance}  (minimum ${MIN_TOKEN_BALANCE})`);

    if (tokenBalance < MIN_TOKEN_BALANCE) {
      console.log(`⚠️  Insufficient tokens: ${tokenBalance} < ${MIN_TOKEN_BALANCE}`);
      if (process.stdin.isTTY) {
        const yn = await ask('    Continue anyway? [y/N] ');
        if (/^[Yy]/.test(yn)) console.log("    proceeding at user's request");
        else { console.log('    aborted by user'); process.exit(1); }
      } else {
        console.error('    non-interactive (no TTY) → aborting.');
        process.exit(1);
      }
    }
  }

  // ---- ensure auto-chain: basic during the run, pro restored on exit -------
  // switch-campaign-mode is OWNER-LOCKED: a non-owner PAT 403s. If we limped on
  // in 'pro' the scene auto-chain never fires and the wait gate hangs forever,
  // so verify the switch actually took (the call throws on 403) — retry once,
  // then abort with an actionable error rather than hang later.
  if (!POST_ONLY) {
    let basicOk = false;
    for (const attempt of [1, 2]) {
      try {
        await switchCampaignMode('basic');
        basicOk = true;
        break;
      } catch (e) {
        console.error(`⚠️  Could not switch campaign to basic (attempt ${attempt}/2): ${e?.message || e}`);
      }
    }
    if (!basicOk) {
      die(`could not enable basic mode — campaign still pro; check that the PAT owns campaign ${CAMPAIGN_ID}`);
    }
    switchedToBasic = true;
    console.log('→ Campaign mode → basic (auto-chain enabled for this run)');
  }

  // ---- pick target episode -------------------------------------------------
  console.log(`→ Fetching campaign ${CAMPAIGN_ID}`);
  let campaign = await fetchCampaign();
  let movies = campaign.movies || [];
  console.log(`  campaign has ${movies.length} movie(s)`);

  let target;
  if (MOVIE_ID_OVERRIDE) {
    target = lookupMovieInCampaign(movies, MOVIE_ID_OVERRIDE);
    if (!target) die(`--movie ${MOVIE_ID_OVERRIDE} not found in campaign ${CAMPAIGN_ID}`);
  } else if (POST_ONLY) {
    console.log('→ Finding most recently rendered episode (checking render-history per rendered movie)…');
    target = await pickLatestRendered(movies);
    if (!target) die('--post-only: no movie in campaign has a renderedMovieUrl');
  } else {
    target = pickNextEpisode(movies);
    if (!target) {
      // Two distinct "no episode to fill" cases:
      //  - movies non-empty → a season exists but every slot is rendered;
      //    create-new-season adds the next season (needs an existing episode).
      //  - movies empty → a fresh/forked campaign has NO numbered slots yet.
      //    create-new-season can't bootstrap from nothing (it 500s), so seed
      //    season 1 from the template via gen-movie-season (as setup_show.sh
      //    does). get-campaign filters the template out, so it's found via
      //    list-campaign.
      if (movies.length > 0) {
        console.log('→ No available episode in current season(s); creating new season');
        const createResp = await client.workflow.createNewSeason({ requestBody: { campaignId: CAMPAIGN_ID } });
        console.log(`  ${JSON.stringify(createResp)}`);
      } else {
        console.log('→ Campaign has no episode slots; bootstrapping season 1 from template');
        const list = await client.workflow.listCampaigns({ userId: USER_ID });
        const entry = (list.campaigns || []).find((c) => c.id === CAMPAIGN_ID);
        const templateId = entry && entry.template && entry.template.id;
        if (!templateId) die(`campaign ${CAMPAIGN_ID} has no template movie to bootstrap from`);
        console.log(`  template movie ${templateId} → gen-movie-season`);
        const seedResp = await client.workflow.genMovieSeason({ requestBody: { movieId: templateId } });
        console.log(`  ${JSON.stringify(seedResp)}`);
      }

      console.log('→ Polling for episodes (up to ~3 minutes)…');
      for (let i = 1; i <= 36; i++) {
        await sleep(5);
        campaign = await fetchCampaign();
        movies = campaign.movies || [];
        target = pickNextEpisode(movies);
        if (target) {
          console.log(`  episodes appeared (${movies.length} total)`);
          break;
        }
        console.log(`  …still waiting (${i}/36)`);
      }
      if (!target) die('season bootstrap did not produce episodes within timeout');
    }
  }

  const { movieId: MOVIE_ID, season: SEASON, episode: EPISODE, title: TITLE } = target;
  console.log(`→ Target episode: S${SEASON}E${EPISODE}  "${TITLE}"  (${MOVIE_ID})`);

  if (!POST_ONLY) {
    const storyText = fs.readFileSync(STORY_FILE, 'utf8');

    // ---- set description ---------------------------------------------------
    const DESCRIPTION = storyToDescription(storyText, CAST_ALIASES);
    if (!DESCRIPTION) {
      console.error(`error: converter produced an empty description from ${STORY_FILE}`);
      console.error("       (no '## Scene N' headers were found)");
      process.exit(1);
    }

    console.log('→ POST /workflow/set-movie-metadata');
    // API field renamed description -> plot (movie plot now lives on movie.plot).
    // yakyak-sdk >=0.0.5 carries the renamed `plot` field on SetMovieMetadataDto.
    const metaResp = await client.workflow.setMovieMetadata({
      setMovieMetadataDto: { movieId: MOVIE_ID, plot: DESCRIPTION },
    });
    console.log(`  ${JSON.stringify(metaResp)}`);

    // ---- social caption + title -------------------------------------------
    const SOCIAL_CAPTION = buildSocialCaption(storyText);
    const HEADLINES_ONLY = buildHeadlinesOnly(storyText);

    let SOCIAL_TITLE = '';
    if (HEADLINES_ONLY) {
      console.log('→ Generating social title from headlines via claude -p (50 char max)');
      SOCIAL_TITLE = generateSocialTitle(HEADLINES_ONLY);
    }
    if (!SOCIAL_TITLE) {
      // Fallback: first headline bullet, trimmed.
      SOCIAL_TITLE = (HEADLINES_ONLY.split('\n').find((l) => l.trim() !== '') || '').trim();
    }
    // Hard 50-char clamp (code-point safe).
    if ([...SOCIAL_TITLE].length > 50) SOCIAL_TITLE = [...SOCIAL_TITLE].slice(0, 50).join('');

    if (SOCIAL_CAPTION || SOCIAL_TITLE) {
      if (SOCIAL_TITLE) console.log(`  socialTitle: "${SOCIAL_TITLE}" (${[...SOCIAL_TITLE].length} chars)`);
      const socialPayload = { movieId: MOVIE_ID };
      if (SOCIAL_CAPTION) socialPayload.socialDescription = SOCIAL_CAPTION;
      if (SOCIAL_TITLE) socialPayload.socialTitle = SOCIAL_TITLE;
      console.log('→ POST /workflow/update-movie-social-description');
      const socialResp = await client.workflow.updateMovieSocialDescription({ requestBody: socialPayload });
      console.log(`  ${JSON.stringify(socialResp)}`);
    } else {
      console.log("→ skipping social overrides (no '## Headlines' section in story file)");
    }

    // ---- trigger screenplay regen -----------------------------------------
    console.log('→ POST /workflow/gen-movie-screenplay');
    const genResp = await client.workflow.genMovieScreenplay({
      genMovieScreenplayRequestDto: { movieId: MOVIE_ID },
    });
    console.log(`  ${JSON.stringify(genResp)}`);

    if (SKIP_FINALIZE) {
      console.log('');
      console.log('✓ Done (--skip-finalize); soundtrack + render NOT triggered.');
      console.log(`  Movie:    ${MOVIE_ID}  (S${SEASON}E${EPISODE} - ${TITLE})`);
      console.log(`  Preview:  https://yakyak.ai/export?movieId=${MOVIE_ID}`);
      return;
    }

    // ---- drive all scenes to a burned state -------------------------------
    // A scene is ready when sceneBurnSubtitle.status == "completed". Rather than
    // hard-fail on a single stuck/failed scene (which a deploy/restart can cause
    // mid-render, even though the server then self-recovers), detect stalls and
    // re-kick the pipeline — mirrors setup_show.sh's drive-loop:
    //   - progress is measured across ALL four scene phases (subtitle/image/
    //     movie/burn), not just burns, so a stall at any phase is detected;
    //   - on a real stall (no progress for several polls) OR any 'failed' step,
    //     re-assert basic mode (in case it was switched) AND resume the movie;
    //   - bail only when the overall poll window is exhausted.
    const phaseStatus = (scene, phase) => scene?.[phase]?.status || '';
    const PHASES = ['sceneSubtitleMovie', 'sceneImage', 'sceneMovie', 'sceneBurnSubtitle'];
    console.log(`→ Waiting for scene generation (poll every ${SCENE_POLL_INTERVAL}s, up to ${Math.floor(SCENE_POLL_INTERVAL * SCENE_POLL_MAX / 60)} min)…`);

    let scenesReady = false;
    let lastProg = -1;
    let stall = 0;
    for (let i = 1; i <= SCENE_POLL_MAX; i++) {
      await sleep(SCENE_POLL_INTERVAL);
      let movie;
      try {
        movie = await client.workflow.getMovie({ movieId: MOVIE_ID });
      } catch {
        console.log(`  …poll ${i}/${SCENE_POLL_MAX}: get-movie returned empty, retrying`);
        continue;
      }
      const scenes = movie?.scene || [];
      if (scenes.length === 0) {
        console.log(`  …poll ${i}/${SCENE_POLL_MAX}: screenplay not yet generated`);
        continue;
      }
      const done = scenes.filter((s) => phaseStatus(s, 'sceneBurnSubtitle') === 'completed').length;
      // Completed steps across all four scene phases — the stall signal.
      const prog = scenes.reduce(
        (n, s) => n + PHASES.filter((p) => phaseStatus(s, p) === 'completed').length,
        0,
      );
      const failed = scenes.filter((s) =>
        ['sceneBurnSubtitle', 'sceneImage', 'sceneMovie'].some((p) => phaseStatus(s, p) === 'failed'),
      ).length;
      console.log(`  …poll ${i}/${SCENE_POLL_MAX}: ${done}/${scenes.length} burned (steps ${prog}/${scenes.length * 4}, failed ${failed})`);
      if (done === scenes.length) {
        scenesReady = true;
        console.log(`  all ${scenes.length} scene(s) burned and ready`);
        break;
      }
      if (prog > lastProg) { lastProg = prog; stall = 0; } else { stall += 1; }
      // Re-kick on a real stall, or immediately if something is in 'failed'.
      if (stall >= 4 || failed > 0) {
        console.log('  …stalled/failed — re-asserting basic mode + resume');
        try { await switchCampaignMode('basic'); } catch { /* best-effort re-assert */ }
        await resumeMovie(MOVIE_ID);
        stall = 0;
      }
    }

    if (!scenesReady) {
      die('scenes did not complete within timeout. Run again with --skip-finalize and finalize later.');
    }

    // ---- pick + assign soundtrack -----------------------------------------
    // Set the configured soundtrack path DIRECTLY; the render reuses it straight
    // from the CDN by path, so it need NOT appear in available-soundtracks (a
    // global, recency-capped picker the BBN track ages out of). Only fall back
    // to the picker when no soundtrack path is configured at all.
    let chosenAudioPath = SOUNDTRACK_AUDIO_PATH;

    if (chosenAudioPath) {
      // Verify the configured audio exists on the CDN before committing — a
      // missing file would otherwise surface as a late, opaque render failure.
      let httpCode = 0;
      try {
        const res = await fetch(`${CDN_BASE}/${chosenAudioPath}`, { method: 'HEAD' });
        httpCode = res.status;
      } catch {
        httpCode = 0;
      }
      if (!(httpCode >= 200 && httpCode < 300)) {
        console.error(`error: configured soundtrack not reachable on CDN (HTTP ${httpCode}):`);
        console.error(`       ${CDN_BASE}/${chosenAudioPath}`);
        console.error('       Pass a valid --soundtrack <audioPath> or fix SOUNDTRACK_AUDIO_PATH in show.env.');
        process.exit(1);
      }
      console.log(`→ Using configured soundtrack (verified on CDN, HTTP ${httpCode})`);
    } else {
      console.log(`→ No soundtrack configured; falling back to /workflow/available-soundtracks/${MOVIE_ID}`);
      const soundtracks = await client.workflow.getAvailableSoundtracks({ movieId: MOVIE_ID });
      chosenAudioPath = soundtracks?.[0]?.audioPath || '';
      if (!chosenAudioPath) die(`no soundtrack configured and none available for movie ${MOVIE_ID}`);
      console.log(`  picker items[0]: ${chosenAudioPath}`);
    }
    console.log(`  audioPath: ${chosenAudioPath}`);

    console.log('→ POST /workflow/set-soundtrack-audio');
    const setAudioResp = await client.workflow.setSoundtrackAudioPath(
      { setSoundtrackAudioDto: { movieId: MOVIE_ID, audioPath: chosenAudioPath } });
    console.log(`  ${JSON.stringify(setAudioResp) || 'ok'}`);

    // ---- set volume -------------------------------------------------------
    console.log(`→ POST /workflow/set-soundtrack  (volumePercentage=${VOLUME_PERCENTAGE})`);
    const setVolumeResp = await client.workflow.updateSoundtrackVolume({
      soundtrackVolumeRequestDto: { movieId: MOVIE_ID, volumePercentage: VOLUME_PERCENTAGE },
    });
    console.log(`  ${JSON.stringify(setVolumeResp) || 'ok'}`);

    // ---- trigger final render + wait for it to finish ---------------------
    // Wait (not fire-and-forget) so /social/post-movie can read the freshly
    // rendered MP4 off the movie when --post is set.
    console.log('→ POST /workflow/export-render');
    const renderResp = await client.workflow.exportRender(
      { exportRenderDto: { movieId: MOVIE_ID, force: false } });
    console.log(`  ${JSON.stringify(renderResp)}`);

    console.log(`→ Waiting for render to finish (poll every ${RENDER_POLL_INTERVAL}s, up to ${Math.floor(RENDER_POLL_INTERVAL * RENDER_POLL_MAX / 60)} min)…`);
    let renderUrl = '';
    for (let i = 1; i <= RENDER_POLL_MAX; i++) {
      await sleep(RENDER_POLL_INTERVAL);
      let rh;
      try {
        rh = await client.workflow.listRenderHistory({ movieId: MOVIE_ID });
      } catch {
        console.log(`  …poll ${i}/${RENDER_POLL_MAX}: render-history returned empty, retrying`);
        continue;
      }
      const finishedAt = rh?.items?.[0]?.finishedAt || '';
      if (finishedAt) {
        renderUrl = rh?.items?.[0]?.soundtrackedMovieUrl || '';
        console.log(`  finished at ${finishedAt}`);
        console.log(`  ${renderUrl}`);
        break;
      }
      console.log(`  …poll ${i}/${RENDER_POLL_MAX}: still rendering`);
    }

    if (!renderUrl) {
      die('render did not finish within timeout. Skipping --post (if set).');
    }
  } // end !POST_ONLY (skip-upload+render block)

  // ---- optional: post to social --------------------------------------------
  if (POST_TO_SOCIAL) {
    console.log(`→ GET /social/campaign-links/${CAMPAIGN_ID}`);
    const links = await client.social.getCampaignLinks({ campaignId: CAMPAIGN_ID });
    const linkCount = links?.count || 0;
    console.log(`  ${linkCount} linked network(s)`);

    const campaignLinks = links?.campaignLinks || [];
    const networkList = campaignLinks.map((l) => l.socialNetworkName).join(', ');
    console.log('');
    console.log('  ┌─ About to POST to social ──────────────────────────────');
    console.log(`  │ Episode:  S${SEASON}E${EPISODE}  "${TITLE}"`);
    console.log(`  │ Movie:    ${MOVIE_ID}`);
    console.log(`  │ Networks: ${networkList || '<none linked>'}`);
    console.log(`  │ Preview:  https://yakyak.ai/export?movieId=${MOVIE_ID}`);
    console.log('  └────────────────────────────────────────────────────────');

    if (ASSUME_YES) {
      console.log('  --yes given → posting without confirmation');
    } else if (process.stdin.isTTY) {
      const yn = await ask('  Post THIS episode to the networks above? [y/N] ');
      if (/^[Yy]/.test(yn)) console.log('  confirmed; posting');
      else { console.log('  aborted by user — nothing was posted'); process.exit(1); }
    } else {
      console.error('error: refusing to post non-interactively without --yes (episode picker is heuristic).');
      console.error('       Re-run on a TTY to confirm, or pass --yes/-y to post unattended.');
      process.exit(1);
    }

    let postOk = 0;
    let postFail = 0;
    for (const link of campaignLinks) {
      const connId = link.connectedNetworkId;
      const networkName = link.socialNetworkName;
      if (!connId) continue;
      console.log(`→ POST /social/post-movie/${MOVIE_ID}/${connId}  (${networkName})`);
      try {
        await client.social.postMovieToSocial({ movieId: MOVIE_ID, connectedNetworkId: connId });
        postOk++;
        console.log('  ✓ 2xx');
      } catch (e) {
        postFail++;
        const code = e?.response?.status ?? '???';
        let body = '';
        try { body = await e.response.text(); } catch { /* ignore */ }
        console.log(`  ✗ ${code}  ${String(body).slice(0, 240)}`);
      }
    }
    console.log(`  social posting: ${postOk} ok, ${postFail} failed`);
  } else {
    console.log('→ skipping social posting (pass --post to enable)');
  }

  console.log('');
  console.log('✓ Done.');
  console.log(`  Movie:    ${MOVIE_ID}  (S${SEASON}E${EPISODE} - ${TITLE})`);
  if (!POST_ONLY) {
    console.log(`  Story:    ${STORY_FILE}`);
    console.log(`  Volume:   ${VOLUME_PERCENTAGE}%`);
  }
  console.log(`  Preview:  https://yakyak.ai/export?movieId=${MOVIE_ID}`);
}

// EXIT-equivalent trap: restore 'pro' on success OR error, and on Ctrl-C.
let signalled = false;
for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, async () => {
    if (signalled) return;
    signalled = true;
    console.error(`\n→ Received ${sig}`);
    await restoreProMode();
    process.exit(130);
  });
}

try {
  await run();
} catch (err) {
  // SDK throws ResponseError (with .response) on non-2xx; surface a useful line.
  if (err && err.response) {
    let body = '';
    try { body = await err.response.text(); } catch { /* ignore */ }
    console.error(`error: HTTP ${err.response.status} ${String(body).slice(0, 400)}`);
  } else {
    console.error(`error: ${err?.message || err}`);
  }
  process.exitCode = 1;
} finally {
  await restoreProMode();
}

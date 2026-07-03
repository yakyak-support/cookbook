#!/usr/bin/env node
// -----------------------------------------------------------------------------
// regen-from-template.mjs — v2
//
// Reference implementation of the YakYak "resolve a target → patch it or mint a
// new episode → render → post" flow. This is the exact sequence the n8n workflow
// (workflow.import-regen-post.json) runs; use it to validate the pipeline from a
// terminal before (or instead of) wiring the visual nodes. Zero dependencies —
// Node 18+ (global fetch) only.
//
// THE TWO MODES
//   patch    (default) — small, event-driven changes (a GitHub push, a chat
//            message). Edits ONE standing episode in place and re-renders it.
//            Diff-aware: a change whose value already matches is skipped, so
//            re-delivered events cost nothing. Version history = the episode's
//            render-history (every render's URL is immutable).
//   episode  — significant new content per run (showrunner-like). Picks the next
//            unrendered slot in the campaign (minting a new season when full),
//            writes the plot, and lets gen-movie-screenplay write + render every
//            scene server-side (💸). One campaign, N meaningful episodes.
//
// NEVER IMPORTS PER RUN. The campaign is resolved: explicit CAMPAIGN_ID, else
// adopt-by-name from the user's owned campaigns, else import ONCE from
// TEMPLATE_PATH (the next run adopts that import by name).
//
// USAGE
//   YAKYAK_TOKEN=yy_live_...              \   # required; userId is decoded from it
//   MODE=patch|episode                    \   # default patch
//   CAMPAIGN_ID=... | CAMPAIGN_NAME=...   \   # target campaign (or via template name)
//   MOVIE_ID=...                          \   # patch mode: explicit episode (optional)
//   TEMPLATE_PATH=./template.export.json  \   # provision-once fallback (optional)
//   CHANGES_PATH=./changes.json           \   # the change plan
//   CHAT_WEBHOOK_URL=https://hooks.slack.com/services/...  \  # optional
//   node regen-from-template.mjs
//
// See docs/n8n_readme.md for the full walkthrough and the changes.json schema.
// -----------------------------------------------------------------------------

import { readFile } from "node:fs/promises";

// ---- config -----------------------------------------------------------------
const BASE = (process.env.YAKYAK_API_BASE || "https://api.yakyak.ai").replace(/\/$/, "");
const TOKEN = required("YAKYAK_TOKEN");
const MODE = process.env.MODE || "patch";
const CAMPAIGN_ID = process.env.CAMPAIGN_ID || "";
const CAMPAIGN_NAME = process.env.CAMPAIGN_NAME || "";
const MOVIE_ID = process.env.MOVIE_ID || "";
const TEMPLATE_PATH = process.env.TEMPLATE_PATH || "";
const CHANGES_PATH = process.env.CHANGES_PATH || null;
const CHAT_WEBHOOK_URL = process.env.CHAT_WEBHOOK_URL || null;

if (MODE !== "patch" && MODE !== "episode") {
  console.error(`Unknown MODE "${MODE}" (use "patch" or "episode")`); process.exit(1);
}

// The PAT is `yy_live_` + a standard JWT whose payload carries the userId in its
// `id` claim — decode it locally so no separate YAKYAK_USER_ID lookup is needed.
// (YAKYAK_USER_ID still overrides, e.g. for admins acting on another account.)
const USER_ID = process.env.YAKYAK_USER_ID || decodePatUserId(TOKEN);
if (!USER_ID) { console.error("Could not decode a userId from YAKYAK_TOKEN (malformed token?)"); process.exit(1); }

function decodePatUserId(pat) {
  try {
    const payload = pat.replace(/^yy_live_/, "").split(".")[1];
    return JSON.parse(Buffer.from(payload, "base64url").toString("utf8")).id || "";
  } catch { return ""; }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
function required(name) {
  const v = process.env[name];
  if (!v) { console.error(`Missing required env var ${name}`); process.exit(1); }
  return v;
}

// ---- thin YakYak REST client ------------------------------------------------
async function api(method, path, body) {
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers: {
      "Authorization": `Bearer ${TOKEN}`,
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let json;
  try { json = text ? JSON.parse(text) : {}; } catch { json = { raw: text }; }
  if (!res.ok) {
    throw new Error(`${method} ${path} → ${res.status} ${res.statusText}: ${text.slice(0, 400)}`);
  }
  return json;
}
const GET = (p) => api("GET", p);
const POST = (p, b) => api("POST", p, b);

// ---- resolve: which campaign, which movie ------------------------------------
// Reuse before create. This is what stops every run minting a duplicate campaign.
async function resolveCampaign(importData) {
  const { campaigns: owned = [] } = await GET(`/workflow/list-campaign/${USER_ID}`);
  if (CAMPAIGN_ID) {
    const entry = owned.find((c) => c.id === CAMPAIGN_ID);
    if (!entry) throw new Error(`campaign ${CAMPAIGN_ID} is not owned by this token's user`);
    return { campaignId: CAMPAIGN_ID, entry, provisioned: "reused" };
  }
  if (!CAMPAIGN_NAME && !importData && MOVIE_ID) {
    // Movie-id-only call: derive the campaign from the movie itself — the
    // caller shouldn't need to know it.
    const got = await GET(`/workflow/get-movie/${MOVIE_ID}`);
    const cid = (got.movie ?? got).campaignId;
    if (cid) {
      const entry = owned.find((c) => c.id === cid);
      if (!entry) throw new Error(`movie ${MOVIE_ID}'s campaign ${cid} is not owned by this token's user`);
      return { campaignId: cid, entry, provisioned: "reused" };
    }
  }
  const name = CAMPAIGN_NAME || importData?.campaigns?.[0]?.name || "";
  if (!name) throw new Error("need CAMPAIGN_ID, CAMPAIGN_NAME, or TEMPLATE_PATH to resolve a campaign");
  // Oldest name match = the canonical original (later same-name copies are
  // v1-era import duplicates). Deterministic across runs.
  const matches = owned.filter((c) => c.name === name)
    .sort((a, b) => String(a.createdAt).localeCompare(String(b.createdAt)));
  if (matches.length) return { campaignId: matches[0].id, entry: matches[0], provisioned: "reused" };
  if (importData) {
    console.log(`→ no owned campaign named "${name}" — importing once (next run adopts it by name)`);
    const imported = await POST("/workflow/import-campaign", { userId: USER_ID, importData });
    const campaignId = imported.campaigns?.[0]?.id;
    if (!campaignId) throw new Error(`import-campaign returned no campaign: ${JSON.stringify(imported)}`);
    return { campaignId, entry: null, provisioned: "imported" };
  }
  throw new Error(`no owned campaign named "${name}" and no TEMPLATE_PATH to provision one`);
}

async function fetchMovies(campaignId) {
  const got = await GET(`/workflow/get-campaign/${campaignId}`);
  return ((got.campaign || got).movies || [])
    .slice()
    .sort((a, b) => (Number(a.season) - Number(b.season)) || (Number(a.episode) - Number(b.episode)));
}

async function resolveMovie(campaignId, entry) {
  let movies = await fetchMovies(campaignId);
  if (MODE === "patch") {
    // Patch default is the TRAILER/TEMPLATE — the campaign's stable face. Numbered
    // episodes must be pinned via MOVIE_ID (auto-picking S1E1 out of a grid of
    // episodes was a footgun). Note: get-campaign lists only numbered episodes;
    // the trailer comes from list-campaign's entry.template.id.
    const templateId = entry?.template?.id || "";
    if (MOVIE_ID) {
      if (!movies.some((m) => m.id === MOVIE_ID) && MOVIE_ID !== templateId)
        throw new Error(`movie ${MOVIE_ID} not found in campaign ${campaignId} (${movies.length} episode(s); template: ${templateId || "none"})`);
      return MOVIE_ID;
    }
    if (templateId) return templateId;
    if (movies.length === 1) return movies[0].id; // no template, one movie — unambiguous
    if (movies.length === 0) throw new Error(`campaign ${campaignId} has no template movie and no episodes to patch`);
    const list = movies.map((m) => `S${m.season}E${m.episode}=${m.id}`).join(", ");
    throw new Error(`campaign ${campaignId} has no template movie and ${movies.length} episodes — set MOVIE_ID. Candidates: ${list}`);
  }
  // episode mode: generation auto-chains only in basic mode (best-effort; we own it).
  try { await POST("/workflow/switch-campaign-mode", { campaignId, mode: "basic" }); } catch {}
  const nextSlot = (ms) => ms.find((m) => !(m.renderedMovieUrl || ""));
  let slot = nextSlot(movies);
  if (!slot) {
    if (movies.length > 0) {
      console.log("→ every slot rendered — creating the next season");
      await POST("/workflow/create-new-season", { campaignId });
    } else {
      // create-new-season can't bootstrap an empty campaign (it 500s) — seed
      // season 1 from the template movie, like the showrunner does.
      const templateId = entry?.template?.id;
      if (!templateId) throw new Error("campaign has no episode slots and no template movie to bootstrap from");
      console.log("→ campaign has no slots — bootstrapping season 1 from the template");
      await POST("/workflow/gen-movie-season", { movieId: templateId });
    }
    for (let i = 0; i < 36 && !slot; i++) { await sleep(5000); movies = await fetchMovies(campaignId); slot = nextSlot(movies); }
    if (!slot) throw new Error("season creation did not produce a slot within timeout");
  }
  return slot.id;
}

// ---- patch-mode change dispatch ----------------------------------------------
// One action per scene entry, applied via the endpoint that BOTH persists the
// edit and kicks the correct regen cascade. Diff-aware: identical values are
// skipped, so a re-run of the same plan costs nothing.
async function applyPatchChange(scene, ch) {
  const sceneId = scene.id;
  switch (ch.action) {
    case "story": // visual change → image → movie → burn
      if (scene.story === ch.story) return false;
      await POST("/workflow/update-scene-story", { sceneId, story: ch.story }); return true;
    case "dialogue": // narration change → subtitle → burn
      if (scene.dialogue === ch.dialogue) return false;
      await POST("/workflow/update-scene-dialogue", { sceneId, dialogue: ch.dialogue }); return true;
    case "animation": // current prompt isn't exposed by get-scenes; always apply
      await POST("/workflow/update-scene-animation-prompt", { sceneId, prompt: ch.prompt }); return true;
    case "styling": {
      let did = false;
      if (ch.leadCast != null && ch.leadCast !== scene.leadCast) {
        await POST("/workflow/update-scene-lead-cast", { sceneId, leadCast: ch.leadCast }); did = true;
      }
      if (ch.backgroundColor != null) {
        // background colour only persists; force a subtitle re-run so it takes effect.
        await POST("/workflow/update-scene-background-color", { sceneId, backgroundColor: ch.backgroundColor });
        await POST("/workflow/rerun-scene", { sceneId, from: "subtitle" }); did = true;
      }
      return did;
    }
    case "title": // metadata only, no regen
      if (scene.title === ch.title) return false;
      await POST("/workflow/update-scene-title", { sceneId, title: ch.title }); return true;
    case "retry": // re-run same content from a stage (image|movie|subtitle|burn)
      await POST("/workflow/rerun-scene", { sceneId, from: ch.from || "image" }); return true;
    case "regen": // regenerate ONE asset without cascading
      await POST("/workflow/regen-scene-asset", { sceneId, asset: ch.asset || "image" }); return true;
    default:
      throw new Error(`Unknown action "${ch.action}" for scene ${ch.sceneNumber}`);
  }
}

// ---- main -------------------------------------------------------------------
async function main() {
  const importData = TEMPLATE_PATH ? JSON.parse(await readFile(TEMPLATE_PATH, "utf8")) : null;
  const changes = CHANGES_PATH ? JSON.parse(await readFile(CHANGES_PATH, "utf8")) : { scenes: [] };

  // 1. resolve (never import per run) -----------------------------------------
  console.log(`→ resolving target (mode=${MODE})…`);
  const { campaignId, entry, provisioned } = await resolveCampaign(importData);
  const movieId = await resolveMovie(campaignId, entry);
  console.log(`  campaign=${campaignId} (${provisioned}) movie=${movieId}`);

  // 2. apply -------------------------------------------------------------------
  let changed = 0;
  if (changes.movie?.title)
    await POST("/workflow/update-movie-title", { movieId, title: changes.movie.title });

  if (MODE === "episode") {
    if (!changes.movie?.plot) throw new Error("episode mode needs changes.movie.plot (the story text for the new episode)");
    console.log("→ set-movie-metadata + gen-movie-screenplay (writes + renders every scene, 💸)…");
    await POST("/workflow/set-movie-metadata", { movieId, plot: changes.movie.plot });
    await POST("/workflow/gen-movie-screenplay", { movieId });
    changed = 1;
    console.log("→ waiting for screenplay generation…");
    await waitScreenplayDone(movieId);
  } else {
    const { scenes } = await GET(`/workflow/get-scenes/${movieId}`);
    const byNumber = new Map(scenes.map((s) => [s.sceneNumber, s]));
    const sceneChanges = changes.scenes || [];
    console.log(`  ${scenes.length} scenes; ${sceneChanges.length} change(s) requested`);
    for (const ch of sceneChanges) {
      const scene = byNumber.get(ch.sceneNumber);
      if (!scene) { console.warn(`  ! no scene #${ch.sceneNumber}, skipping`); continue; }
      const did = await applyPatchChange(scene, ch);
      console.log(`  · scene #${ch.sceneNumber}: ${ch.action}${did ? "" : " (no-op, skipped)"}`);
      if (did) changed++;
    }
    if (changed) {
      console.log("→ waiting for scene regeneration…");
      await sleep(4000); // let the backend flip the reran stages to processing first
      await waitScenesSettled(movieId);
    }
  }

  // 3. render (concat + soundtrack). force:true guarantees a stitched output. --
  console.log("→ export-render…");
  await POST("/workflow/export-render", { movieId, force: true });

  console.log("→ waiting for concat + soundtrack…");
  await waitRenderDone(movieId);

  // 4. read the URL ------------------------------------------------------------
  const got = await GET(`/workflow/get-movie/${movieId}`);
  const movie = got.movie ?? got;
  const url = movie.finalMovieUrl || movie.soundtrackedMovieUrl || movie.concatMovieUrl;
  console.log(`\n🎬 Finished movie (${MODE}, ${changed} change(s)): ${url}`);

  // 5. output event ------------------------------------------------------------
  if (CHAT_WEBHOOK_URL) {
    console.log("→ posting to chat webhook…");
    await fetch(CHAT_WEBHOOK_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      // Slack/Discord/Teams all accept a { "text": ... } body for incoming webhooks.
      body: JSON.stringify({ text: `New movie ready (${MODE}): ${url}`, movieId, url }),
    });
    console.log("  posted.");
  }
}

// Poll get-movie-scene-progress until nothing is mid-flight. A stage is "settled"
// when done+failed === total (every row that exists has reached a terminal state).
async function waitScenesSettled(movieId, { tries = 120, everyMs = 5000 } = {}) {
  for (let i = 0; i < tries; i++) {
    const p = await GET(`/workflow/get-movie-scene-progress/${movieId}`);
    const steps = Object.values(p.steps || {});
    const settled = steps.every((s) => s.total === 0 || s.done + s.failed >= s.total);
    const failed = steps.reduce((n, s) => n + (s.failed || 0), 0);
    const s = p.steps || {};
    console.log(`  scenes img ${fmt(s.image)} · mov ${fmt(s.movie)} · sub ${fmt(s.subtitlesMovie)} · burn ${fmt(s.burn)}`);
    if (settled) {
      if (failed) console.warn(`  ! ${failed} scene stage(s) failed — render may be incomplete`);
      return;
    }
    await sleep(everyMs);
  }
  throw new Error("scene regeneration timed out");
}
const fmt = (x) => (x ? `${x.done}/${x.total}${x.failed ? ` (${x.failed}✗)` : ""}` : "-");

// Episode mode's completion signal (as the web app does): the movieScreenplay
// execution completing. export-render then drives any per-scene renders still
// in flight to done before concat.
async function waitScreenplayDone(movieId, { tries = 120, everyMs = 5000 } = {}) {
  for (let i = 0; i < tries; i++) {
    const prog = await GET(`/workflow/get-movie-progress/${movieId}`);
    const ex = Object.fromEntries((prog.executions ?? []).map((e) => [e.type, e.status]));
    if (ex.movieScreenplay === "failed") throw new Error("screenplay generation failed");
    console.log(`  screenplay=${ex.movieScreenplay ?? "-"}`);
    if (ex.movieScreenplay === "completed") return;
    await sleep(everyMs);
  }
  throw new Error("screenplay generation timed out");
}

// Poll get-movie-progress until concat done and soundtrack done-or-absent.
async function waitRenderDone(movieId, { tries = 120, everyMs = 5000 } = {}) {
  for (let i = 0; i < tries; i++) {
    const prog = await GET(`/workflow/get-movie-progress/${movieId}`);
    const ex = Object.fromEntries((prog.executions ?? []).map((e) => [e.type, e.status]));
    const concat = ex.movieConcat, sound = ex.movieSoundtrack;
    if ([concat, sound].includes("failed")) throw new Error("render failed");
    const done = concat === "completed" && (sound === undefined || sound === "completed");
    console.log(`  concat=${concat ?? "-"} soundtrack=${sound ?? "-"}`);
    if (done) return;
    await sleep(everyMs);
  }
  throw new Error("render timed out");
}

main().catch((e) => { console.error("\n✗", e.message); process.exit(1); });

#!/usr/bin/env node
// -----------------------------------------------------------------------------
// render-to-telegram.mjs
//
// Render ONE YakYak movie and deliver the finished video to a Telegram chat.
// Runs anywhere Node 18+ runs — a terminal, cron, or any CI step.
// Zero dependencies — Node 18+ (global fetch) only.
//
// WHAT IT DOES
//   1. export-render {movieId, force}   — kick the concat + soundtrack render
//   2. get-movie-progress (poll)        — until movieConcat (+ soundtrack) complete
//   3. get-movie                        — read finalMovieUrl
//   4. Telegram sendVideo               — the bot fetches the mp4 URL server-side,
//                                         so the video lands playable in the chat.
//                                         Falls back to sendMessage with the link
//                                         (sendVideo-by-URL caps at ~20 MB).
//
// The movie must be owned by the PAT's account. The id is the `movieId` query
// param on the IG grid: https://yakyak.ai/ig/<userId>?movieId=<MOVIE_ID>.
//
// USAGE
//   YAKYAK_TOKEN=yy_live_...            \   # required
//   MOVIE_ID=...                        \   # required
//   TELEGRAM_BOT_TOKEN=123456:ABC-...   \   # required (from @BotFather)
//   TELEGRAM_CHAT_ID=...                \   # required (your chat with the bot)
//   FORCE=true                          \   # optional; default true (fresh concat)
//   YAKYAK_API_BASE=https://api.yakyak.ai   # optional
//   node render-to-telegram.mjs
//
// See integrations/telegram/README.md for the bot + secrets setup.
// -----------------------------------------------------------------------------

const BASE = (process.env.YAKYAK_API_BASE || "https://api.yakyak.ai").replace(/\/$/, "");
const TOKEN = required("YAKYAK_TOKEN");
const MOVIE_ID = required("MOVIE_ID");
const BOT_TOKEN = required("TELEGRAM_BOT_TOKEN");
const CHAT_ID = required("TELEGRAM_CHAT_ID");
const FORCE = (process.env.FORCE ?? "true") !== "false";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
function required(name) {
  const v = process.env[name];
  if (!v) { console.error(`Missing required env var ${name}`); process.exit(1); }
  return v;
}

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
  if (!res.ok) throw new Error(`${method} ${path} → ${res.status} ${res.statusText}: ${text.slice(0, 400)}`);
  return json;
}

async function telegram(method, body) {
  const res = await fetch(`https://api.telegram.org/bot${BOT_TOKEN}/${method}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const json = await res.json().catch(() => ({}));
  if (!json.ok) throw new Error(`Telegram ${method} failed: ${JSON.stringify(json).slice(0, 300)}`);
  return json;
}

async function main() {
  // 1. render -----------------------------------------------------------------
  console.log(`→ export-render movie=${MOVIE_ID} force=${FORCE}`);
  await api("POST", "/workflow/export-render", { movieId: MOVIE_ID, force: FORCE });

  // 2. wait for concat + soundtrack -------------------------------------------
  console.log("→ waiting for concat + soundtrack…");
  let done = false;
  for (let i = 0; i < 120 && !done; i++) {
    const prog = await api("GET", `/workflow/get-movie-progress/${MOVIE_ID}`);
    const ex = Object.fromEntries((prog.executions ?? []).map((e) => [e.type, e.status]));
    const concat = ex.movieConcat, sound = ex.movieSoundtrack;
    if ([concat, sound].includes("failed")) throw new Error("render failed");
    done = concat === "completed" && (sound === undefined || sound === "completed");
    console.log(`  concat=${concat ?? "-"} soundtrack=${sound ?? "-"}`);
    if (!done) await sleep(10000);
  }
  if (!done) throw new Error("render timed out (~20 min)");

  // 3. read the URL -------------------------------------------------------------
  const got = await api("GET", `/workflow/get-movie/${MOVIE_ID}`);
  const movie = got.movie ?? got;
  const url = movie.finalMovieUrl || movie.soundtrackedMovieUrl || movie.concatMovieUrl;
  if (!url) throw new Error(`render completed but no movie URL: ${JSON.stringify(movie).slice(0, 300)}`);
  const title = movie.title || "YakYak movie";
  console.log(`\n🎬 ${title}: ${url}`);

  // 4. deliver to Telegram -------------------------------------------------------
  // sendVideo by URL: Telegram downloads the mp4 itself (≤ ~20 MB) and it arrives
  // playable in the chat. If that fails (size, transient fetch error), fall back
  // to a plain message with the link — never lose a finished render.
  const caption = `🎬 ${title}\n${url}`;
  try {
    console.log("→ Telegram sendVideo…");
    await telegram("sendVideo", { chat_id: CHAT_ID, video: url, caption });
    console.log("  delivered as video.");
  } catch (e) {
    console.warn(`  sendVideo failed (${e.message.slice(0, 120)}) — falling back to sendMessage`);
    await telegram("sendMessage", { chat_id: CHAT_ID, text: caption });
    console.log("  delivered as link.");
  }
}

main().catch((e) => { console.error("\n✗", e.message); process.exit(1); });

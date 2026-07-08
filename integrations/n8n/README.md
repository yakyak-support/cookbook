# integrations/n8n

Automate [YakYak](https://yakyak.ai/) visually with **[n8n](https://n8n.io/)**.

This integration is built around one reusable **engine** workflow that does the hard,
stateful part of the media pipeline, plus small **front-end** workflows that feed it —
so you can generate and publish a new episode on a schedule, or trigger a targeted
change + render from any external event.

## What's here

- **[`workflow.yakyak-engine.json`](./workflow.yakyak-engine.json)** — the **engine**:
  give it *what to change* and it resolves the campaign/movie (adopt by name; import a
  template only once, never per run), **patches** a standing movie in place (diff-aware —
  re-running the same change is a free no-op) or mints a **new episode** in the same
  campaign, waits for regeneration, renders, and returns the finished movie URL.
  Callable via webhook (`/webhook/yakyak-engine`, Header-Auth protected) or as a
  **sub-workflow** from other n8n workflows. All secrets live in n8n credentials — no
  environment variables. **📖 Full guide: [`docs/yakyak_engine.md`](./docs/yakyak_engine.md).**
- **[`workflow.patch-dialogue-to-message.json`](./workflow.patch-dialogue-to-message.json)** —
  front-end, patch mode: one `POST` changes a line of dialogue and delivers the rendered
  video to **Telegram, Discord and/or Slack**, chosen per request via a `deliverTo` object.
  Omit `dialogue` for **render-only mode** — no edit, just re-render + deliver.
  Triggerable from a GitHub Action
  ([`.github/workflows/patch-dialogue-to-message.yml`](../../.github/workflows/patch-dialogue-to-message.yml)).
  Full beginner walkthrough (bot setup for all three apps, credentials, import, testing):
  [`docs/workflow_patch_dialogue_to_message.md`](./docs/workflow_patch_dialogue_to_message.md).
- **Show front-ends, episode mode** — every demo show from [`../../show/`](../../show/)
  as an importable scheduled workflow: story sourcing on the canvas, then the engine
  mints + renders the episode and the front-end announces it. Start with
  [`docs/breaking_bricks_news.md`](./docs/breaking_bricks_news.md) — it documents the
  shared architecture once; the other guides cover only what each show does differently.

  | Workflow | Show | Sourcing | Model? | Guide |
  |---|---|---|:---:|---|
  | [`workflow.horoscopes-weekly.json`](./workflow.horoscopes-weekly.json) | Cosmic Brief (weekly) | Computed — deterministic from the ISO week | no | [`docs/horoscopes.md`](./docs/horoscopes.md) |
  | [`workflow.luckyday-daily.json`](./workflow.luckyday-daily.json) | Lucky Day (daily) | Computed — deterministic from the date; Mandarin dialog | no | [`docs/lucky_day.md`](./docs/lucky_day.md) |
  | [`workflow.suntzu-mwf.json`](./workflow.suntzu-mwf.json) | Sun Tzu, Today (Mon/Wed/Fri) | Extracted — corpus walked by a cursor (static data) | yes | [`docs/sun_tzu_today.md`](./docs/sun_tzu_today.md) |
  | [`workflow.onthisday-daily.json`](./workflow.onthisday-daily.json) | On This Day (daily) | Computed date → public-domain corpus | yes | [`docs/on_this_day.md`](./docs/on_this_day.md) |
  | [`workflow.dailypull-daily.json`](./workflow.dailypull-daily.json) | Daily Pull (daily) | Randomized — date-seeded tarot draw, 7-day no-repeat window | yes | [`docs/daily_pull.md`](./docs/daily_pull.md) |
  | [`workflow.marketmayhem-daily.json`](./workflow.marketmayhem-daily.json) | Market Mayhem (daily) | Live data — Binance 24h + Fear & Greed (CoinGecko fallback) | yes | [`docs/market_mayhem.md`](./docs/market_mayhem.md) |
  | [`workflow.pettycourt-daily.json`](./workflow.pettycourt-daily.json) | Petty Court (daily) | Live UGC — Reddit drama listings, paraphrased & SFW-screened | yes | [`docs/petty_court.md`](./docs/petty_court.md) |
  | [`workflow.bbn-daily.json`](./workflow.bbn-daily.json) | Breaking Bricks News (daily) | Live news — BBC / CNN / Al Jazeera headlines | yes | [`docs/breaking_bricks_news.md`](./docs/breaking_bricks_news.md) |

  The two **Computed** shows need no Anthropic credential at all — Cosmic Brief is the
  recommended first import to prove the engine wiring.
- **[`regen-from-template.mjs`](./regen-from-template.mjs)** — a zero-dependency Node script
  that runs the engine's flow from a terminal. Use it to prove your token, template, and
  account before wiring nodes.
- **[`changes.example.json`](./changes.example.json)** — an example "what to regenerate"
  change plan (the schema is in the engine guide, §7).

Prefer no n8n at all? The standalone render-and-deliver-to-Telegram script lives in
[`../telegram/`](../telegram/) — same YakYak calls, zero dependencies.

### Workflow descriptions live in a sticky note, not the Description dialog

n8n's canvas "Description" dialog (double-click the workflow title, or the ⋯ menu) writes
to a DB-only field — it's absent from the exported/imported workflow JSON entirely, so it
never round-trips through git or a fresh import. Every workflow in this folder instead
carries a **`YakYak Description`** sticky note (`n8n-nodes-base.stickyNote`) as the first
node, positioned as a banner above the main canvas row. It's a real node, so it survives
export/import/git like any other step. Keep the name exactly `YakYak Description` so it
stays unambiguous against any other sticky notes added later for step-level annotations.

## Start here

1. **📖 [`docs/yakyak_engine.md`](./docs/yakyak_engine.md)** — the engine from zero:
   the reuse-vs-regenerate model, installing n8n, credentials, the payload + change-plan
   schema, testing with `curl`, endpoint reference, troubleshooting.
2. **📖 [`docs/workflow_patch_dialogue_to_message.md`](./docs/workflow_patch_dialogue_to_message.md)** —
   a gentler on-ramp if you'd rather start from a finished product: chat bots, credentials
   and delivery, click by click with screenshots.

## Reference

- **API docs:** https://api.yakyak.ai/api/docs
- **OpenAPI spec:** https://api.yakyak.ai/api/docs-json

## Usage

Create the two credentials (`YakYak API` Bearer Auth + `YakYak render webhook token`
Header Auth — exact names, the workflows find them by name), import the engine, then
import whichever front-end you want and point its **Execute Workflow** node at the engine.
The model-driven show front-ends need one more credential (`Anthropic API key` Header
Auth — the two Computed shows skip it) and take the rest of their config from a
**Show config** node on the canvas — no environment variables anywhere. Full
walkthrough in [`docs/yakyak_engine.md`](./docs/yakyak_engine.md).

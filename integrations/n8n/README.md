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
  Triggerable from a GitHub Action
  ([`.github/workflows/patch-dialogue-to-message.yml`](../../.github/workflows/patch-dialogue-to-message.yml)).
  Full beginner walkthrough (bot setup for all three apps, credentials, import, testing):
  [`docs/workflow_patch_dialogue_to_message.md`](./docs/workflow_patch_dialogue_to_message.md).
- **[`workflow.bbn-daily.json`](./workflow.bbn-daily.json)** — front-end, episode mode: the
  **Breaking Bricks News** daily show (fetch real headlines → Claude writes the episode →
  engine mints + renders the episode → announce). See
  [`docs/breaking_bricks_news.md`](./docs/breaking_bricks_news.md).
- **[`workflow.render-to-telegram.json`](./workflow.render-to-telegram.json)** — render one
  movie and deliver the finished video to **Telegram**; triggered by a GitHub Action (or any
  `POST`). Self-contained — calls the YakYak API directly, no engine. See
  [`docs/render_to_telegram.md`](./docs/render_to_telegram.md); the same flow without n8n
  is the standalone script in [`../telegram/`](../telegram/).
- **[`regen-from-template.mjs`](./regen-from-template.mjs)** — a zero-dependency Node script
  that runs the engine's flow from a terminal. Use it to prove your token, template, and
  account before wiring nodes.
- **[`changes.example.json`](./changes.example.json)** — an example "what to regenerate"
  change plan (the schema is in the engine guide, §7).

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
Full walkthrough in [`docs/yakyak_engine.md`](./docs/yakyak_engine.md).

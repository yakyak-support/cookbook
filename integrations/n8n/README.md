# integrations/n8n

Automate [YakYak](https://yakyak.ai/) visually with **[n8n](https://n8n.io/)**.

This integration provides n8n nodes and ready-made workflow templates that call the
[YakYak API](https://api.yakyak.ai/api/docs), so you can build no-code/low-code
automations around the media pipeline — for example, generate and publish a new
episode on a schedule, or trigger a render from an external event.

## What's here

- **[`workflow.import-regen-post.json`](./workflow.import-regen-post.json)** — an importable
  workflow: *input event → resolve the target campaign (adopt by name; import a template only
  once, never per run) → **patch** a standing episode in place (diff-aware, small event-driven
  changes) or mint a **new episode** in the same campaign (significant new content) → render →
  post the finished movie to a chat*.
- **[`regen-from-template.mjs`](./regen-from-template.mjs)** — a zero-dependency Node script that
  runs the **same** flow from a terminal. Use it to prove the pipeline before wiring nodes.
- **[`workflow.bbn-daily.json`](./workflow.bbn-daily.json)** — a worked example front-end: the
  **Breaking Bricks News** daily show (fetch real headlines → Claude writes the episode →
  episode mode via the engine → soundtrack + social fields → announce). See
  [`docs/breaking_bricks_news.md`](./docs/breaking_bricks_news.md).
- **[`workflow.render-to-telegram.json`](./workflow.render-to-telegram.json)** — render one
  movie and deliver the finished video to **Telegram**; triggered by a GitHub Action (or any
  `POST`). Self-contained — calls the YakYak API directly. See
  [`docs/render_to_telegram.md`](./docs/render_to_telegram.md); the same flow without n8n
  is the standalone script in [`../telegram/`](../telegram/).
- **[`workflow.patch-dialogue-to-telegram.json`](./workflow.patch-dialogue-to-telegram.json)** —
  the educational sibling: **change** a scene's dialogue first, then render and deliver.
  Only 5 nodes, because it **delegates to the engine** (`/webhook/yakyak-regen`, patch mode)
  instead of talking to YakYak itself — the two side by side show when to call the API
  directly and when to chain workflows.
- **[`workflow.yakyak-engine.json`](./workflow.yakyak-engine.json)** — the reusable **engine**:
  give it *what to change* and it resolves the campaign/movie, patches the scene, regenerates
  only what the change touched (re-running with the same input is a free no-op), renders, and
  returns the finished movie URL. Called as a sub-workflow by the front-ends below.
- **[`workflow.patch-dialogue-to-message.json`](./workflow.patch-dialogue-to-message.json)** —
  the multi-channel front-end: one `POST` changes a line of dialogue and delivers the rendered
  video to **Telegram, Discord and/or Slack**, chosen per request via a `deliverTo` object.
  All secrets live in n8n credentials — no environment variables — so it works on any n8n
  instance. Triggerable from a GitHub Action
  ([`.github/workflows/patch-dialogue-to-message.yml`](../../.github/workflows/patch-dialogue-to-message.yml)).
  Full beginner walkthrough (bot setup for all three apps, credentials, import, testing):
  [`docs/workflow_patch_dialogue_to_message.md`](./docs/workflow_patch_dialogue_to_message.md).
- **[`changes.example.json`](./changes.example.json)** — an example "what to regenerate" plan.

## Start here

**📖 [`docs/n8n_readme.md`](../../docs/n8n_readme.md)** — a from-scratch guide for non-n8n users:
the reuse-vs-regenerate model, installing n8n, importing + configuring this workflow, the change
schema, testing with `curl`, the full endpoint reference, and troubleshooting.

## Reference

- **API docs:** https://api.yakyak.ai/api/docs
- **OpenAPI spec:** https://api.yakyak.ai/api/docs-json

## Usage

Set `YAKYAK_TOKEN` and `YAKYAK_API_BASE` on your n8n instance (or use a Header-Auth
credential), import a workflow from this folder, and run or schedule it. (The `userId` the
import body needs is decoded from the token — no separate env var.) Full walkthrough in
[`docs/n8n_readme.md`](../../docs/n8n_readme.md).

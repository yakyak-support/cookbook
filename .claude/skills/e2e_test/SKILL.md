---
name: e2e_test
description: Run, monitor, and reason about YakYak's headless Playwright e2e test suite — what's covered, what isn't, how to invoke it locally and on CI (GitHub Actions against beta), and where the credentials live. Trigger when the user wants to run the suite, kick off a beta CI run, check coverage, or understand which gaps still need tests.
user_invocable: true
---

# YakYak e2e test suite — operator guide

## When to use

- Running one or more of the 18 e2e scripts locally against `localhost`.
- Triggering the **manual** `E2E (Beta)` GitHub Action that runs the suite against `https://beta.yakyak.ai`.
- Answering "what does our e2e suite cover today?" and "what's still uncovered?".
- Looking up the credentials / env vars / GitHub secrets needed to run the suite.

If the user wants to **build a new test** or **debug an existing one** (selectors, polling, React gotchas), use the `e2e` skill instead.

## Coverage at a glance (18 entry points)

All scripts live in `e2e/src/run-*.ts`. Auth is always `POST /users/login-by-email` → JWT seeded into `localStorage` (Google SSO is never UI-driven; `/users/social-login` is stubbed for fork tests). All reports land in `e2e/.audits/<test>_<ISO_TS>/report.md` with embedded videos, screenshots, and token-transaction tables.

### Core pipeline
| Script | npm | Coverage |
| --- | --- | --- |
| `run.ts` | `test:e2e` | UC-2.2 full pipeline: campaign → cast → screenplay → per-scene (image → animate → subtitle → burn) → concat → soundtrack → final render → token audit (zero duplicate tx groups). |

### Auth / smoke / billing
| Script | npm | Coverage |
| --- | --- | --- |
| `run-smoke.ts` | `test:e2e:smoke` | UC-1.4/1.5/1.6 sign in/out, profile, dashboard, billing render. Localhost or beta. |
| `run-topup.ts` | `test:e2e:topup` | TC1–TC4: $9 / $19 / $29 top-up tiers, Stripe config, GUI. |
| `run-sub-gate.ts` | `test:e2e:sub-gate` | Subscription gate modal triggers when balance < 0; billing page. |
| `run-credits.ts` | `test:e2e:credits` | 7 TCs covering API 402s, UI gate modals, balance mutations. TC1–TC6 auto-skip without local psql (so against beta only TC7 runs). |

### Campaign / movie lifecycle
| Script | npm | Coverage |
| --- | --- | --- |
| `run-new-campaign.ts` | `test:e2e:new-campaign` | UC-2.1 create + list + dashboard visibility. |
| `run-first-movie.ts` | `test:e2e:first-movie` | UC-2.2 full pipeline + dashboard visibility. |
| `run-auto-generate.ts` | `test:e2e:auto-generate` | UC-2.4 basic-mode auto-chain (no manual clicks past start). |
| `run-autogen-ui.ts` | `test:e2e:autogen-ui` | "Autogen Full Movie" dashboard button → 2nd episode. |
| `run-next-episode.ts` | `test:e2e:next-episode` | UC-2.3 manual continue (append to existing campaign). |
| `run-import.ts` | `test:e2e:import` | viral.json multi-campaign import + first-scene render. |

### Pro-mode editing
| Script | npm | Coverage |
| --- | --- | --- |
| `run-cast-edit.ts` | `test:e2e:cast-edit` | UC-2.6 edit cast name/description, regen 1 character image. |
| `run-scene-edit.ts` | `test:e2e:scene-edit` | UC-2.5 edit scene title, re-render image/movie/subtitle/burn. |
| `run-upload.ts` | `test:e2e:upload` | Upload custom scene image (native picker), trigger re-render, verify cycling arrows. |
| `run-cast-cycling.ts` | `test:e2e:cast-cycling` | ◀ N/M ▶ arrows when cast member has ≥2 historical images. |
| `run-export.ts` | `test:e2e:export` | `GET /workflow/export-campaign/:id` JSON shape. |

### Fork / social
| Script | npm | Coverage |
| --- | --- | --- |
| `run-fork-frontpage.ts` | `test:e2e:fork-frontpage` | 3 sub-tests against beta: new user (DB-reset), not-logged-in, logged-in fork from frontpage. |
| `run-ig-fork.ts` | `test:e2e:ig-fork` | 5 UCs: logged-in fork, logged-out preview + auth modal, API public-preview, email-login flow, `/movieEdit` redirect. |

## Gaps (no e2e coverage today)

**High-impact** — chroma-key subtitle overlay (only synthetic unit tests in `serverless/test/`); social auto-posting (`api/src/modules/social/`); scheduler / EventBridge campaign triggers; aspect-ratio variants (9:16 / 16:9 paths through `getCreatomateTemplateId()` + `segmentDialogueIntelligently()`); Kling AI animator alternative.

**Medium** — subtitle text-color picker UI; style picker carousel; custom voice selection; Stripe payment completion + webhook crediting; token refund / partial-rollback on pipeline failure; `/insider`, `/media`, `/create` pages.

**Cross-cutting** — error-recovery / transient failures (`FatalPollError` never deliberately tripped); concurrency / parallel-movie races; large-cast / extreme-input cases.

Full audit lives in `docs/e2e_coverage_audit.md`.

## Running locally

Prereqs: `e2e/.env.test` must exist (template is `.env.test.example`). Local dev servers running on `:3000` / `:3001` for the localhost tests.

```bash
cd e2e
npm ci
npx playwright install chromium

npm run test:e2e                 # core full pipeline (~25 min)
npm run test:e2e:smoke           # auth/dashboard/billing render
npm run test:e2e:fork-frontpage  # beta-only, hits beta DB
# … etc — see package.json for the full list
```

Exit codes: `0` PASS, `1` FAIL (e.g. duplicate token tx detected), `2` setup error.

Default target is `http://localhost:{3000,3001}`. Override per-run:

```bash
YAKYAK_API_URL=https://api.beta.yakyak.ai \
YAKYAK_APP_URL=https://beta.yakyak.ai \
  npm run test:e2e:smoke
```

## Running on CI (against beta)

Manual GitHub Action: `.github/workflows/e2e-beta.yml`. It runs the full 18-test matrix (`max-parallel: 3`, `fail-fast: false`, 45-min timeout per job) against `https://api.beta.yakyak.ai` / `https://beta.yakyak.ai`. Each job uploads its `.audits/` directory as a `report-<name>` artifact (14-day retention).

Trigger via gh CLI:

```bash
# Kick off on the default branch:
gh workflow run e2e-beta.yml

# On a specific branch:
gh workflow run e2e-beta.yml --ref my-branch

# Override input:
gh workflow run e2e-beta.yml -f max_parallel=5

# Watch the latest run:
gh run watch $(gh run list --workflow=e2e-beta.yml --limit 1 --json databaseId -q '.[0].databaseId')

# Download all report-* artifacts after it finishes:
gh run download $(gh run list --workflow=e2e-beta.yml --limit 1 --json databaseId -q '.[0].databaseId') -D ./e2e-artifacts
```

Or from the Actions tab → `E2E (Beta)` → Run workflow.

## Required GitHub secrets

Set under repo → Settings → Secrets and variables → Actions. Canonical values live in the user's local `e2e/.env.test`.

| Secret | Used by | Notes |
| --- | --- | --- |
| `YAKYAK_TEST_EMAIL` | every job | The shared test account. |
| `YAKYAK_TEST_PASSWORD` | every job | Dev-grade password — fine for beta. |
| `YAKYAK_BETA_DATABASE_URL` | `fork-frontpage` (mandatory); `credits` / `sub-gate` (via `DATABASE_URL` when they fall back to pg) | Beta Postgres: `postgresql://postgres:<pwd>@50.112.243.172:8433/yakyak`. |
| `YAKYAK_FORK_TEST_GOOGLE_EMAIL` | `fork-frontpage` | Stub identity for the Google social-login mock. |
| `YAKYAK_FORK_TEST_GOOGLE_SUB` | `fork-frontpage` | Any stable string (e.g. `e2e-fork-sub-<name>-001`); reusing the same value matches the same identity on repeat runs. |

The URLs themselves (`YAKYAK_API_URL`, `YAKYAK_APP_URL`, `YAKYAK_BETA_API_URL`, `YAKYAK_BETA_APP_URL`) are **not** secrets — they're hardcoded in the workflow's top-level `env:` block. To make the target configurable later, either add `workflow_dispatch` inputs or move to GitHub Environments (per-env `vars` + `secrets`).

## Sanity checks

**Beta DB reachable:**

```bash
psql "$YAKYAK_BETA_DATABASE_URL" -c 'select 1, current_database(), current_user;'
# expect: 1 | yakyak | postgres
```

**API reachable:**

```bash
curl -sf https://api.beta.yakyak.ai/health || echo 'API unreachable'
```

## Side effects against beta — be aware

- Every full-pipeline run creates a fresh campaign on the test user → expect campaign sprawl.
- `sub-gate` mutates user state directly via pg.
- `ig-fork` issues `delete-campaign` calls.
- `fork-frontpage` deletes the test user (`YAKYAK_FORK_TEST_GOOGLE_EMAIL`) from beta DB before its first sub-test.
- `topup` exercises the live Stripe publishable key bundled into the beta app build (only creates checkout sessions, doesn't complete payment — but confirm the test user isn't a billable identity before running repeatedly).

## Related

- Skill **`e2e`** — building/debugging individual tests (selectors, polling, gotchas, report shape).
- Slash command **`/test-e2e`** — run the core pipeline locally + open the report.
- Slash command **`/test-e2e-fork-frontpage`** — run the 3 frontpage-fork tests against beta.
- `docs/e2e_coverage_audit.md` — full coverage audit, refreshed 2026-05-18.

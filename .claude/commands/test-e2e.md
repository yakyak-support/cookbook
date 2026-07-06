---
description: Run the headless YakYak E2E pipeline test and open the resulting Markdown report (with embedded videos and screenshots).
---

# /test-e2e — Headless end-to-end pipeline test + double-charge audit

You shell out to the Playwright runner in `e2e/`. Everything user-facing happens in the generated Markdown report, so keep your chat output to a one-line summary and the report path.

## 1. Preconditions

Verify dev servers are listening:

```bash
lsof -nP -iTCP:3000 -sTCP:LISTEN | tail -n +2
lsof -nP -iTCP:3001 -sTCP:LISTEN | tail -n +2
```

If either is missing, invoke the `restartdev` skill first.

Verify `e2e/.env.test` exists. If not, copy from the example and stop:

```bash
test -f e2e/.env.test || cp e2e/.env.test.example e2e/.env.test
```

If the file was just created from the example (it's empty), tell the user to fill in `YAKYAK_TEST_EMAIL` and `YAKYAK_TEST_PASSWORD` in `e2e/.env.test` and stop. Do NOT proceed without those credentials.

## 2. Install (idempotent)

```bash
cd e2e && npm install --silent
```

First-time only — also fetch headless Chromium:

```bash
cd e2e && npx playwright install chromium
```

(Skip if `npx playwright install --dry-run chromium` indicates the browser is already present.)

## 3. Run

```bash
cd e2e && npm run test:e2e
```

The script:
- POSTs `/users/login-by-email` for a fresh JWT (env-driven).
- Launches **headless** Chromium, primes localStorage, drives the full pipeline (campaign → cast → screenplay → render scenes → export → soundtrack → final render).
- Polls `/workflow/get-movie-progress` every ~8 s — total run time ~10 min.
- Captures a screenshot at each milestone and writes `.audits/test-e2e_<ISO_TS>/report.md` with embedded `<video>` players for the cast images, scene clips, and final movie.

Stdout's first line is `PASS` or `FAIL`. Second line is `Report: <absolute path>`. On FAIL, stdout also lists each duplicate group inline.

Exit code: `0` on PASS, `1` on FAIL, `2` on setup error (missing creds, login failed, etc.).

## 4. Surface the result

- Read the first stdout line and surface "PASS ✅" or "FAIL 🚨" in chat.
- Print the report path so the user can click it.
- Open the report in their default app:

```bash
open "$REPORT_PATH"
```

- On FAIL, also paste the duplicate-group list inline so the user doesn't need to open the report to triage.

## What's in the report

- PASS/FAIL banner with movie/campaign IDs, balance delta, transaction count.
- Action totals table (every `movie_*` and `scene_*` action with count + tokens).
- Duplicates table (only on FAIL).
- Cast section — 4 character thumbnails inline.
- Scenes section — per-scene image + `<video>` player for the burned-subtitle clip.
- Final movie — `<video>` player.
- Step screenshots gallery (8 PNGs covering each milestone).
- Token transactions table (all rows for this movie, oldest-first).

## Notes

- The runner is local-only by design. It logs into the user's real dev account; don't run it against beta or prod.
- The .env.test file is gitignored. The runner reads `YAKYAK_TEST_EMAIL`, `YAKYAK_TEST_PASSWORD`, and optionally `YAKYAK_API_URL` / `YAKYAK_APP_URL` / `YAKYAK_TEST_IDEA`.
- If a step times out, the script captures a `99-failure.png` screenshot and still emits a (FAIL) report — useful for post-mortem.

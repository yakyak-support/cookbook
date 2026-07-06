---
description: Run the three frontpage Fork e2e tests against beta and open the Markdown report.
---

# /test-e2e-fork-frontpage — Frontpage Fork flow (3 cases against beta)

Runs three Playwright test cases that exercise the "Fork a sample movie" button on the
beta frontpage. Each case lands on `/movieEdit?movieId=…` and renames the new movie.

| # | Case | Setup |
|---|---|---|
| 1 | New user | DELETE the test user from beta DB first |
| 2 | Existing user, not logged in | Use the user created in case 1 |
| 3 | Existing user, already logged in | JWT pre-injected via /users/social-login |

Google login is stubbed in the browser (`window.google` is replaced before page
scripts run). The real Google IdP is never called — the AuthModal's code path is
exercised end-to-end against the API.

## 1. Preconditions

Verify `e2e/.env.test` has the beta-fork vars:

```bash
test -f e2e/.env.test || { cp e2e/.env.test.example e2e/.env.test; echo "Edit e2e/.env.test and set YAKYAK_BETA_*"; exit 2; }
grep -q '^YAKYAK_BETA_DATABASE_URL=' e2e/.env.test || { echo "Missing YAKYAK_BETA_DATABASE_URL — see .env.test.example"; exit 2; }
```

Required vars in `e2e/.env.test`:
- `YAKYAK_BETA_API_URL` (default `https://api.beta.yakyak.ai`)
- `YAKYAK_BETA_APP_URL` (default `https://beta.yakyak.ai`)
- `YAKYAK_BETA_DATABASE_URL` (**required** — needed for the user reset in Test 1)
- `YAKYAK_FORK_TEST_GOOGLE_EMAIL` (default `danmoto6811@gmail.com`)
- `YAKYAK_FORK_TEST_GOOGLE_SUB` (default `e2e-fork-sub-danmoto-001` — keep stable across runs)

## 2. Install (idempotent)

```bash
cd e2e && npm install --silent
```

First-time only — also fetch headless Chromium:

```bash
cd e2e && npx playwright install chromium
```

## 3. Run

```bash
cd e2e && npm run test:e2e:fork-frontpage
```

The script:
- Picks the first reachable demo campaign id from the hardcoded `DEMO_VIDEOS` list (matching `app/app/page.tsx:42`).
- Test 1: `DELETE FROM "user" WHERE email = …` via `pg` (cascades to campaigns + token_transactions), then runs the new-user fork flow.
- Test 2: fresh browser context (no JWT in localStorage), runs existing-not-logged-in flow.
- Test 3: POSTs `/users/social-login` from Node to mint a real JWT, injects it into localStorage via `addInitScript`, runs the no-modal direct fork.
- All three end on `/movieEdit?movieId=<id>` and rename the movie via `POST /workflow/update-movie-title`. The DB is queried to confirm the title persisted.

Stdout: first line `PASS` or `FAIL`, second `Report: <absolute path>`. Per-test result lines follow. Exit code: `0` if all three pass, `1` if any failed, `2` on setup error.

## 4. Surface the result

- Read the first stdout line and surface "PASS ✅" or "FAIL 🚨" in chat.
- Print the report path so the user can click it.
- Open the report:

```bash
open "$REPORT_PATH"
```

- On FAIL, paste the per-test result lines inline so triage doesn't require opening the report.

## What's in the report

- PASS/FAIL banner with the App/API URLs and the demo campaign id used.
- Summary table — one row per test, with movieId and before/after title.
- One section per test — setup note, screenshots (`t<N>-01-frontpage.png` → `t<N>-04-title-saved.png`, plus `99-failure.png` on FAIL), movieId, campaignId, error message.
- DB delta — campaigns and token_transaction rows newly attached to the test user since run start.

## Notes

- The suite **leaves the forked campaigns in place** for inspection. Test 1 re-running implicitly prunes them via `resetUser()`. To prune manually:
  ```sql
  DELETE FROM "user" WHERE email = 'danmoto6811@gmail.com';
  ```
- `/users/social-login` does not verify the Google id_token — the synthetic credential the stub feeds the modal is accepted as-is. This is what makes the headless flow possible.
- Each test launches a **fresh browser context** so cookies and localStorage are guaranteed isolated.
- If a step times out, a `99-failure.png` is captured and the (FAIL) report is still emitted.

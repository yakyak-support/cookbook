---
name: e2e
description: Add or maintain headless Playwright end-to-end tests for YakYak. Covers the e2e/ package architecture, how to add a new test case, React/Playwright gotchas learned the hard way, the headless auth pattern, and the Markdown report shape. Trigger when the user wants to add a new e2e test, debug a failing one, or extend the existing /test-e2e flow.
user_invocable: true
---

# YakYak headless e2e — playbook

## When to use

- Adding a new headless end-to-end test that drives the YakYak frontend (`localhost:3000`) and audits the API result.
- Debugging a failing run from `e2e/` (timeouts, navigation stalls, mismatched values).
- Extending the existing `/test-e2e` (campaign → cast → screenplay → render → export) with new assertions or a new flow.

If the user just wants to **run** the existing test, use the `/test-e2e` slash command — don't invoke this skill.

## Architecture (already in place)

```
e2e/
├── package.json          # playwright + ts-node + dotenv
├── tsconfig.json
├── .env.test.example     # template for credentials (real .env.test is gitignored)
├── README.md
└── src/
    ├── auth.ts           # POST /users/login-by-email → { token, userId }
    ├── poll.ts           # pollUntil(...), getProgress(...), execStatus(...), FatalPollError
    ├── pipeline.ts       # one async fn per UI step (createCampaign, generateCast, …)
    ├── audit.ts          # paginate token-transactions, group, detect duplicates
    ├── report.ts         # Markdown emitter (embeds <video>/<img>, screenshots, tables)
    └── run.ts            # orchestrator: launch Chromium, drive pipeline, screenshot, audit, report
```

A run produces `.audits/test-e2e_<ISO_TS>/report.md` plus `screenshots/01-*.png … 08-*.png`. Exit code: `0` PASS, `1` FAIL, `2` setup error.

## Adding a new test case (for example, "billing flow" or "media upload")

You have two options:

### Option A — extend `run.ts` with another flow before the audit

Best when the new flow shares state with the existing one (same user, same JWT, same browser context).

1. Add new `async function flowFoo(page, …)` calls in `pipeline.ts`. Each function should:
   - take a `Page` plus what it needs from session/state,
   - drive its UI clicks,
   - return whatever the next step or the report needs.
2. Insert calls in `run.ts` between existing milestones, with `screenshot(page, 'NN-foo', 'Caption')` before/after.
3. Extend the audit: `audit.ts` already groups every transaction; if your new flow creates transactions, they'll appear in the report automatically. If you assert anything else (subscription created, file uploaded, …), add it to `ReportInput` in `report.ts` and surface it in the Markdown.

### Option B — new entry point in `e2e/src/run-foo.ts`

Best when the flow is **independent** (different user, different setup, e.g. a new-signup test).

1. Copy `run.ts` → `run-foo.ts` and trim what you don't need.
2. Add a script alias in `e2e/package.json`: `"test:e2e:foo": "ts-node --transpile-only src/run-foo.ts"`.
3. Optionally add a new slash command `.claude/commands/test-e2e-foo.md` that invokes the new script (mirror `test-e2e.md`).
4. Reuse `auth.ts`, `poll.ts`, `audit.ts`, `report.ts` — they are flow-agnostic.

**Default to Option A** when in doubt; only fork into a new entry point when sharing state actively hurts.

## Gotchas learned the hard way

These are written from first-hand failures during the original `/test-e2e` build. Apply them to every new test.

### 1. React-controlled inputs: use `page.locator(...).fill(...)`, not value-setters

YakYak forms are React-controlled (Chakra UI `<Input>` / `<Textarea>` bound via `useState`). Setting `el.value = '...'` directly is silently ignored: React reads the value from state on next render, not from the DOM.

❌ **Don't** (we tried this — it loses to `useEffect` auto-fill races):
```ts
await page.evaluate(() => {
  const ta = document.querySelector('textarea')!;
  ta.value = '...';            // React ignores this
});
```

❌ **Also don't** (this works in some apps but not when a parallel `useEffect` overwrites state):
```ts
await page.evaluate(() => {
  const ta = document.querySelector('textarea')!;
  const setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value')!.set!;
  setter.call(ta, '...');
  ta.dispatchEvent(new Event('input', { bubbles: true }));
});
```

✅ **Do** — Playwright's `fill()` simulates real keyboard events, which beats every React state-management edge case:
```ts
await page.locator('textarea').first().fill('...');
const confirmed = await page.locator('textarea').first().inputValue();
if (confirmed !== expected) throw new Error('fill did not stick');
```

If the page has a `useEffect` auto-fill (BRAIN STORM in `/newCampaign`), wait for it to finish before you call `fill()`:

```ts
await page.waitForFunction(() => {
  const ta = document.querySelector('textarea') as HTMLTextAreaElement | null;
  return !!ta && ta.value.trim().length > 0;
}, null, { timeout: 10_000 }).catch(() => {});
await page.locator('textarea').first().fill(idea);
```

### 2. Buttons: use `page.locator(..., { hasText })` and `.click()`, not `evaluate(() => btn.click())`

JS `.click()` only dispatches a synthetic click event; it doesn't run the full mousedown/mouseup/click sequence that some Chakra/React components require. Symptoms: the click "succeeds" (no error) but no React handler fires, and you sit timing out on `waitForURL`.

✅ **Do**:
```ts
await page.locator('button', { hasText: /^Generate Screenplay$/ }).first().click({ timeout: 60_000 });
```

The `^…$` regex anchors prevent matching nested buttons (e.g. "Generate" should not match "Generate AI Cast" or "Generate custom soundtrack"). The `first()` keeps it deterministic when the same label exists in multiple places (modal + page).

### 3. Auth: don't drive the SSO flow — bootstrap via `/users/login-by-email`

Driving Google SSO headless is impractical. Don't try.

Instead: the API has `POST /users/login-by-email { email, password }` returning `{ token, userId }`. Mint a fresh JWT once at startup:

```ts
const session = await loginByEmail(API_URL, { email, password });
await page.goto(APP_URL);
await page.evaluate(({ token, userId }) => {
  localStorage.setItem('jwt', token);
  localStorage.setItem('userId', userId);
}, session);
await page.goto(`${APP_URL}/dashboard`);   // now logged in
```

Credentials live in `e2e/.env.test` (gitignored). Always use `dotenv.config({ path: path.join(__dirname, '..', '.env.test') })` at the top of `run.ts` — relative paths matter once the file is invoked from a different CWD.

### 4. Navigation: `page.waitForURL(/regex/)`, not fixed timeouts

The frontend chains multiple API calls before navigating (e.g. `/workflow/create-campaign` → `/workflow/start-campaign` → `router.push('/editCast')`). Network latency varies; sleeping a fixed number of seconds is unreliable.

✅ **Do**:
```ts
await page.waitForURL(/\/editCast\?movieId=/, { timeout: 90_000 });
const movieId = new URL(page.url()).searchParams.get('movieId')!;
```

### 5. Long-running pipeline waits: `pollUntil` against the API, not the page

Generation steps take minutes. Don't poll the DOM ("is the spinner gone?") — poll `/workflow/get-movie-progress/<id>` directly. It's faster, deterministic, and tells you exactly which step is in flight.

✅ **Do**:
```ts
await pollUntil(async () => {
  const p = await getProgress(API_URL, token, movieId);
  return execStatus(p, 'movieCastImage') === 'completed' ? p : null;
}, { intervalMs: 8000, label: 'movieCastImage' });
```

`pollUntil` retries on transient errors. **Default cadence: 8s.** Don't go faster than that — most steps are 30-300 s long, and tighter polling just spams the dev server.

### 6. Fail fast on unrecoverable states — don't burn the timeout

The pipeline doesn't auto-retry failed scene/cast steps (a transient AWS Lambda DNS hiccup leaves them at `failed`). Without a fail-fast, `pollUntil` will burn the entire 25-min timeout waiting for a count that will never tick.

Use `FatalPollError` to bubble out of `pollUntil` immediately:

```ts
import { FatalPollError, pollUntil } from './poll';

await pollUntil(async () => {
  const p = await getProgress(API_URL, token, movieId);
  for (const [stepName, s] of Object.entries(p.sceneProgress?.steps ?? {})) {
    if ((s as any)?.failed > 0) {
      throw new FatalPollError(`scene step "${stepName}" had ${(s as any).failed} failure(s)`);
    }
  }
  return p.sceneProgress?.steps?.burn?.done === p.sceneProgress?.totals?.scenes ? p : null;
}, { intervalMs: 8000, label: 'allScenesBurned' });
```

`FatalPollError` is treated specially by `pollUntil` — it bubbles up; ordinary errors are caught and retried.

### 7. Always emit a report, even on failure

`run.ts` wraps the entire flow in `try/finally`. On failure, take a `99-failure.png` screenshot, then go through the normal report-emission code path. The Markdown report is the single most useful debugging artifact.

```ts
try {
  // … flow …
} catch (e) {
  await screenshot(page, '99-failure', `Failure: ${e.message.slice(0, 80)}`);
  pass = false;
} finally {
  await browser.close();
}
emitReport(reportDir, { pass, /* … */ });   // always
```

### 8. Listen for page-level errors during the run

Add these listeners right after `context.newPage()`. They surface 5xx/4xx responses and uncaught JS errors **as the run is happening**, which makes post-mortems trivial:

```ts
page.on('console', (m) => m.type() === 'error' && console.warn(`[page console.error] ${m.text()}`));
page.on('pageerror', (err) => console.warn(`[page error] ${err.message}`));
page.on('response', (r) => {
  if (r.url().startsWith(API_URL) && r.status() >= 400) {
    console.warn(`[page http ${r.status()}] ${r.request().method()} ${r.url()}`);
  }
});
page.on('requestfailed', (r) => {
  if (r.url().startsWith(API_URL)) console.warn(`[page request failed] ${r.method()} ${r.url()}: ${r.failure()?.errorText}`);
});
```

### 9. Headless Chromium: launch with `headless: true`, period

Don't add `headless: 'new'` — Playwright handles modes internally. Don't add `slowMo` or `devtools: true` to "see what's happening" — that's what the screenshots are for. If you genuinely need to debug visually, run `HEADLESS=false npm run test:e2e` after adding a one-line env switch (already a TODO listed in the plan file).

## Auth setup (first-time, per-test-case)

Whichever flow you build, **never** check credentials into git.

1. The user copies `e2e/.env.test.example` → `e2e/.env.test` and fills in `YAKYAK_TEST_EMAIL` / `YAKYAK_TEST_PASSWORD`.
2. `.env.test` is gitignored at the repo root.
3. Your `run-*.ts` reads `process.env.YAKYAK_TEST_*` after `dotenv.config(...)`.

If the test needs additional secrets (e.g. a Stripe test card token, an admin-scoped JWT), add them to `.env.test.example` with empty values + a comment, document them in the skill's frontmatter, and read them via `process.env.X`.

## Report structure (don't deviate without reason)

The Markdown report uses these sections, top-to-bottom:

1. **Status banner**: `# /test-e2e — ✅ PASS` / `🚨 FAIL` + ISO timestamp.
2. **Identifiers**: movieId, campaignId, balance delta, transaction count, all-execs-completed flag, duplicate group count.
3. **Duplicates table** (FAIL only): action, scene, description, count, total Δ, timestamps.
4. **Action totals**: every action with count + token sum.
5. **Cast / Scenes**: `<img src="..." width="160"/>` for stills, `<video controls width="320" src="..."></video>` for clips. Both render inline on github.com, VS Code Markdown preview, and Obsidian. Include a fallback `[plain link]` next to each `<video>` for renderers that don't support inline video.
6. **Final movie**: `<video controls width="640" src="..."></video>` from `movie.movieSoundtrack.soundtrackedMovieUrl` (fallback `movieSceneConcat.concatenatedMovieUrl`).
7. **Step screenshots**: `![Caption](./screenshots/NN-name.png)` — relative path so the report is portable.
8. **Token transactions table**: oldest-first, `Time | Action | Scene | Description | Δ | Balance`.

When adding a new test case, only add new sections **above** the screenshots gallery, never replace the standard ones — they're the contract that makes reports comparable across runs.

## Debugging a failing run

1. Read the **first line** of stdout: `PASS` or `FAIL`. Second line: report path.
2. On FAIL, the script also prints the duplicate groups inline (if any), and `99-failure.png` is saved.
3. Open the report — embedded `<video>` players show the actual generated assets, often a fast giveaway when something rendered wrong (black frames, wrong character, missing subtitles).
4. Cross-reference the API logs (`/private/tmp/claude-501/.../tasks/<bg-task-id>.output` for the dev server, or `docker logs api` if running in Docker) for the exact server-side error.
5. **Don't** rerun blindly. If a transient infra error (Lambda DNS, Creatomate timeout) caused the failure, the existing campaign is poisoned (failed scene_movie rows don't auto-retry). Either delete the campaign and rerun, or just accept that each `/test-e2e` invocation creates a brand-new campaign — leftover failed campaigns don't pollute the next assertion (the audit filters by the new movieId).

## What we tried and abandoned (don't reintroduce)

- **MCP `claude-in-chrome` for click-driving** — works while a Claude conversation is open and a real Chrome tab is visible, but doesn't go headless and produces no shareable artifact. Left in git history at the original `/test-e2e` command file (commit before `a320eff6`) for reference.
- **`computer.left_click` on `find` refs** — the click sometimes fired before React's handler attached, with no error. We swapped to JS `.click()`, then to Playwright `locator.click()` (the final answer).
- **Prototype `.value` setter for textareas** — works against unmanaged inputs, races against `useEffect` auto-fills (BRAIN STORM was the canonical case).
- **Polling with sub-5s intervals** — wastes API resources, no faster end-to-end since each step takes 30-300 s. Stick to 8s.
- **Catching all errors in `pollUntil` and retrying** — masked unrecoverable failures (failed scene movies). Use `FatalPollError` to short-circuit known-fatal conditions.
- **Trying to drive Google SSO headless** — bootstrap via `/users/login-by-email` instead.

## Verification before declaring a new test "done"

After you've added a new flow:

1. `cd e2e && npx tsc --noEmit` — must exit 0.
2. `npm run test:e2e:<your-script>` (or `npm run test:e2e` if extending) — exit 0.
3. Open the generated report; confirm the new section renders with images/videos as expected.
4. **Inject a regression**: temporarily break the assertion (e.g. comment out the idempotency flag, add `idempotent: false`), restart the API, rerun. Confirm exit code 1, FAIL banner, and the offending detail listed in the report. This proves the assertion isn't a false positive.
5. Revert the regression, rerun once more for clean PASS, commit.

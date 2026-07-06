---
name: restartdev
description: Restart YakYak local dev servers (api + app)
user_invocable: true
---

# Restart YakYak local dev servers

Restart the local dev servers:

- **API** — NestJS at `/Users/johan/Projects/121/repos/yakyak/api`, port 3001, started via `npm run start:dev` (which runs `nest start --watch`).
- **App** — Next.js at `/Users/johan/Projects/121/repos/yakyak/app`, port 3000, started via `npm run dev` (turbopack).

## Procedure

1. **Kill the running servers.** Match by command pattern, not PID, so the skill is repeatable across sessions:

   ```bash
   pkill -f "nest start --watch" 2>/dev/null
   pkill -f "next dev" 2>/dev/null
   pkill -f "node.*api/dist/main" 2>/dev/null
   true
   ```

   (Trailing `true` keeps the chain succeeding even if no matching process exists.)

2. **Wait briefly** for processes to exit:

   ```bash
   sleep 1
   ```

3. **Start API in the background** with `Bash` (`run_in_background: true`):

   ```bash
   cd /Users/johan/Projects/121/repos/yakyak/api && npm run start:dev
   ```

4. **Start App in the background** with `Bash` (`run_in_background: true`):

   ```bash
   cd /Users/johan/Projects/121/repos/yakyak/app && npm run dev
   ```

5. **Confirm they came up** — check that ports 3001 and 3000 are listening:

   ```bash
   lsof -nP -iTCP:3001 -sTCP:LISTEN | tail -n +2
   lsof -nP -iTCP:3000 -sTCP:LISTEN | tail -n +2
   ```

   Nest can take a few seconds to compile; Next a bit longer on first boot. If a port isn't listening yet, wait a couple of seconds and re-check (do **not** poll in a tight loop — give each check 2–3 seconds).

## Notes

- Both `npm run` commands MUST be launched with `run_in_background: true`, otherwise they will block and the skill will never finish.
- Do not pass `--no-watch` to `nest`, and do not strip `--turbopack` from the app — both are project defaults.
- The app's `dev` script computes `NEXT_PUBLIC_API_URL` from the local network IP via `ipconfig getifaddr en0`. Don't override it.
- If `pkill` reports nothing was killed, that's fine — proceed to start.
- Do **not** start a third process if one is already running. The `pkill` step ensures a clean slate.

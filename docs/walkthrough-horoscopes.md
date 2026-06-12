# Screen walk-through: Horoscopes

A click-by-click tour of running the **[`Horoscopes`](../show/Horoscopes/)** show end
to end — fork the repo, add your YakYak PAT, enable Actions, and watch the episode
render. Horoscopes is the **no-model** show (its story is computed offline from the ISO
week), so the only secret you need is a YakYak PAT.

← back to [How to run a show](../show/README.md#how-to-run-a-show)

---

## a) Fork the repo

Open the cookbook on GitHub. A **fork** is your own copy — it comes with the shows, the
showrunner engine, and the workflows that drive them.

![GitHub landing page for the yakyak-support/cookbook repository](assets/github-cookbook-repo.png)

Sign in to GitHub first (you can't fork while signed out).

![GitHub sign-in page](assets/github-sign-in.png)

Click **Fork** (top right).

![Cursor hovering the Fork button on the cookbook repo](assets/github-fork-button.png)

Pick the owner, keep the repo name, and tick **Copy the `main` branch only**, then
**Create fork**.

![GitHub "Create a new fork" dialog with owner, repo name, and "Copy the main branch only" checked](assets/github-create-fork-dialog.png)

Your fork is ready — note the *"forked from yakyak-support/cookbook"* line.

![The newly created fork, showing "forked from yakyak-support/cookbook"](assets/github-fork-created.png)

## b) Add your YakYak PAT

Before you run anything, give the fork the secret it renders with. The run
authenticates to the YakYak API with a personal access token. First create a
YakYak account at [yakyak.ai](https://yakyak.ai/).

![YakYak.ai sign-up modal](assets/yakyak-signup.png)

A new account lands on an empty dashboard (note your starting token balance).

![Empty YakYak dashboard with a 350-token balance and "No campaigns found"](assets/yakyak-dashboard-empty.png)

Go to **Profile** — the **Personal Access Tokens** section is empty. Click **+ New token**.

![YakYak profile page, Personal Access Tokens section with no tokens yet](assets/yakyak-profile-no-tokens.png)

Name the token, keep the scopes you need (Video creation is enough to render), and
**Create token**.

![New access token modal with a name and scopes selected](assets/yakyak-new-token-modal.png)

The token is now **Active** (a `yy_live_…` value). Copy it.

![Token created and listed as Active on the profile page](assets/yakyak-token-created.png)

Back in your fork, go to **Settings → Secrets and variables → Actions**. It's empty —
click **New repository secret**.

![GitHub Actions secrets page with no secrets yet](assets/github-secrets-empty.png)

Name it exactly **`YAKYAK_PAT`** and paste the token, then **Add secret**.

![Adding a repository secret named YAKYAK_PAT with the yy_live_ token pasted in](assets/github-add-yakyak-pat-secret.png)

The secret is saved.

![Repository secrets list showing YAKYAK_PAT added](assets/github-yakyak-pat-secret-added.png)

## c) Enable Actions and run it

New forks have Actions **disabled**. Open the fork's **Actions** tab and click
**I understand my workflows, go ahead and enable them**.

![GitHub Actions tab on the fork with the "I understand my workflows, go ahead and enable them" button](assets/github-enable-actions.png)

Actions are now enabled and the workflow list appears.

![Actions enabled banner with the workflow list (Render Shows, Post Episode, …)](assets/github-actions-enabled.png)

Scheduled workflows are **disabled by default on forks**, so the **Render Shows**
workflow shows a yellow notice — click **Enable workflow** to allow manual dispatch.

![Render Shows workflow page showing the "scheduled workflows are disabled in forks" notice and Enable workflow button](assets/github-render-shows-disabled.png)

![Render Shows workflow enabled, ready to dispatch](assets/github-render-shows-enabled.png)

Open **Run workflow**, type `Horoscopes` to force just that show now, leave **post**
unchecked (render only), and **Run workflow**.

![Run workflow dispatch form with "Horoscopes" entered in the show field](assets/github-run-workflow-horoscopes.png)

## d) What a missing PAT looks like

Skip step b — or use a token that can't authenticate — and the render job fails fast.
This is what that looks like, so you can recognise it: the annotation spells it out,
`set $YAKYAK_PAT …` with **exit code 1**, and the `plan` step succeeds while the `run`
job fails.

![Failed Render Shows run with annotation "set $YAKYAK_PAT" and exit code 1](assets/github-run-failed-missing-pat.png)

Once the secret is in place, recover from the same run: open the **⋯** menu and choose
**Re-run failed jobs**.

![Re-run menu open on the failed run](assets/github-rerun-menu.png)

![Re-run failed jobs confirmation dialog](assets/github-rerun-confirm-dialog.png)

The job restarts and goes green through `plan` while the render job runs.

![Re-run in progress](assets/github-rerun-in-progress.png)

## e) Your rendered movie on yakyak.ai

With the PAT in place, the render job runs to completion. `plan` succeeds and the
Horoscopes render job churns through scene generation.

![Horoscopes render job in progress in the Actions console](assets/github-horoscopes-in-progress.png)

Watch it live on **yakyak.ai/profile** — the **Active Jobs** panel streams each scene,
soundtrack, and subtitle-overlay job with an ETA.

![YakYak profile Active Jobs streaming the Weekly Horoscopes scenes](assets/yakyak-profile-horoscopes-rendering.png)

The campaign appears on your dashboard as it fills with episodes.

![YakYak campaign card for the Horoscopes campaign](assets/yakyak-campaign-horoscopes.png)

The Actions run finishes **green** with an artifact attached.

![Render Shows run completed successfully](assets/github-horoscopes-run-success.png)

…and the finished episode plays back on yakyak.ai. That's your first rendered movie.

![The completed Horoscopes episode playing on the YakYak dashboard](assets/yakyak-horoscopes-final-movie.png)

---

Next: try the **[DailyPull walk-through](walkthrough-dailypull.md)** to add your own AI
model (a Claude OAuth token) and render a show whose story is written by a model.

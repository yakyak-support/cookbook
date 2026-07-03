# Patch a movie line and send the video to Telegram, Discord and Slack

This guide sets up two n8n workflows that work together like a kitchen:

- **`workflow.yakyak-engine.json` — the kitchen.** You tell it *what to change* in a YakYak movie, and it does all the hard work: it finds the right campaign and movie, changes the scene (for example, one line of dialogue), waits for YakYak to regenerate everything the change touched, renders the finished movie, and hands back a link to the final mp4. It never changes anything that didn't need changing — sending the same dialogue twice costs nothing.

- **`workflow.patch-dialogue-to-message.json` — the waiter.** It takes a small order ("change scene 1's dialogue to *this*, and deliver the result *there*"), passes it to the kitchen, and then delivers the finished video to the chat apps you asked for: **Telegram** (as a playable video), **Discord** (as a message with an auto-playing link) and **Slack** (as a real uploaded video file). You choose per request which of the three get the video — one, two, or all three.

One HTTP request does the whole thing:

```
you (curl / GitHub Action)
   │  POST { movieId, dialogue, sceneNumber, deliverTo: {…} }
   ▼
patch-dialogue-to-message  ──calls──▶  yakyak-engine  ──talks to──▶  YakYak API
   │                                        │
   │   ◀── finished movie URL ──────────────┘
   ├──▶ Telegram   (playable video)
   ├──▶ Discord    (message, link auto-embeds)
   └──▶ Slack      (uploaded video file)
```

This is what the waiter looks like on the n8n canvas — one straight line into the engine, then three parallel delivery lanes that meet again before answering you:

![The patch-dialogue-to-message workflow](../assets/patch-dialogue-to-message-workflow-canvas.jpeg)

And the engine — bigger, but you never need to touch its insides:

![The yakyak-engine workflow](../assets/yakyak-engine-workflow-canvas.jpeg)

**No environment variables anywhere.** Every secret lives in an n8n **credential** (an encrypted little safe inside n8n), and every *destination* (which chat, which channel) travels inside the request. That means these workflows work on any n8n — your laptop's Docker, a shared team instance, or n8n Cloud.

---

## What you'll create, at a glance

| # | Thing | Where you get it |
|---|---|---|
| 1 | A **Telegram bot** + your chat id | BotFather, inside Telegram |
| 2 | A **Discord bot** + a channel id | discord.com/developers |
| 3 | A **Slack bot** + a channel id | api.slack.com/apps |
| 4 | **5 credentials** in n8n | you type them in |
| 5 | The **2 workflows**, imported and switched on | the JSON files in this folder |

Nothing here costs money. Free Telegram, free Discord server, free Slack workspace, free bot accounts.

> **Golden rule for the whole guide:** whenever this guide says *name it exactly* `Like This`, use that exact name, capital letters and spaces included. The imported workflows find their credentials **by name**.

---

## Part 1 — Make a Telegram bot

A "bot" is just a robot account that our workflow will use to send you messages. Telegram bots are created by talking to another bot called **BotFather**.

1. Open Telegram and search for **`@BotFather`** (it has a blue checkmark). Press **Start**.
2. Send it the message: `/newbot`
3. It asks for a display name — answer anything, e.g. `YakYak`.
4. It asks for a username ending in `bot` — e.g. `my_yakyak_bot`.
5. BotFather replies with a **token** that looks like `8123456789:AAG1V2Zs…`. **Copy it and keep it somewhere safe** — this is Secret #1. The whole conversation takes under a minute (token blurred here — never share yours):

   ![The /newbot conversation with BotFather](../assets/telegram-botfather-newbot.jpeg)

6. Now find *your own* chat id (the "address" the bot will deliver to): search for **`@userinfobot`**, press Start, and it replies with your **id**, a number like `1759916870`. Write it down — this is Address #1.

   ![@userinfobot replies with your id](../assets/telegram-userinfobot-chat-id.jpeg)

7. Finally, open a chat with **your new bot** and press **Start** once. (Bots are polite: they can't message you until you've messaged them first.)

   ![The new bot's chat after pressing Start](../assets/telegram-start-new-bot.jpeg)

---

## Part 2 — Make a Discord bot

You need a Discord **server** (that's just Discord's word for a free chat space — you're not running any computers). If you don't have one: click the **+** at the bottom of the server list on Discord's left edge → **Create My Own** → give it a name.

### 2a. Create the bot

1. Go to **https://discord.com/developers/applications** and sign in.

   ![The Discord developer portal](../assets/discord-developer-portal-applications.jpeg)

2. Click **New Application**, name it `YakYak`, and click **Create**.

   ![Creating the application](../assets/discord-create-app-dialog.jpeg)

3. In the left sidebar click **Bot**. Your app already has a bot user. Click **Reset Token**, confirm, and **copy the token** (it's shown only once!). It looks like `MTUyMjQ3…`. This is Secret #2. You do **not** need to switch on any of the "Privileged Gateway Intents" toggles — sending messages doesn't need them.

   ![The Bot page with the token](../assets/discord-bot-settings.jpeg)

### 2b. Invite the bot into your server

1. In the left sidebar click **OAuth2**, then scroll down to **URL Generator**.
2. Under **Scopes** tick exactly one box: **`bot`**.
3. A second panel appears: **Bot Permissions**. Tick **View Channels**, **Send Messages** and **Embed Links**.

   ![Picking the bot scope and permissions](../assets/discord-oauth2-url-generator-scopes.jpeg)

4. At the very bottom, copy the **Generated URL**.

   ![The generated invite URL](../assets/discord-oauth2-generated-url.jpeg)

5. Open that URL in your browser, choose your server, and click **Authorize**.

   ![Authorizing the bot into the server](../assets/discord-authorize-bot-add-to-server.jpeg)

The bot now appears in your server's member list, offline and harmless. That's normal — it never needs to be "online" to post.

### 2c. Get the channel id

Discord hides ids until you switch on Developer Mode:

1. In Discord, click the ⚙ gear next to your username (bottom left) → **Advanced** → switch **Developer Mode** on.

   ![Turning on Developer Mode](../assets/discord-developer-mode.jpeg)

2. Right-click the channel you want the videos in → **Copy Channel ID** (bottom of the menu). You get a long number like `1522438174092169228`. Write it down — this is Address #2.

   ![Copying the channel id](../assets/discord-copy-channel-id.jpeg)

---

## Part 3 — Make a Slack bot

You need a Slack **workspace** (also free — like the Discord server, it's just a chat space). Create one at slack.com if needed.

### 3a. Create the app and give it permissions

1. Go to **https://api.slack.com/apps** and click **Create New App** → **From scratch**.

   ![Your Slack apps page](../assets/slack-api-your-apps.jpeg)

2. Name it `YakYak`, pick your workspace, click **Create App**.

   ![Creating the Slack app](../assets/slack-create-app-dialog.jpeg)

3. In the app's left sidebar click **OAuth & Permissions**, scroll to **Scopes → Bot Token Scopes**, click **Add an OAuth Scope**, and add **two** scopes: **`chat:write`** and **`files:write`**.

   ![Adding the two bot token scopes](../assets/slack-bot-token-scopes.jpeg)

4. Scroll back up on the same page and click **Install to Workspace**, then **Allow**. (This one click is the entire "OAuth flow" — no servers, no code.)

   ![Installing the app to the workspace](../assets/slack-install-to-workspace.jpeg)

5. After installing, the page shows a **Bot User OAuth Token** starting with `xoxb-`. Copy it — this is Secret #3.

   ![The bot user OAuth token](../assets/slack-bot-user-oauth-token.jpeg)

### 3b. Invite the bot and get the channel id

1. In Slack, go to the channel where videos should arrive (make one if you like).

   ![A fresh channel](../assets/slack-new-channel-header.jpeg)

2. Type `/invite @YakYak` in the channel and send it (or use "Add apps" from the channel menu). Slack confirms the bot joined.

   ![Inviting the bot](../assets/slack-invite-yakyak-bot.jpeg)

   ![The bot is in the channel](../assets/slack-bot-added-to-channel.jpeg)

3. Click the **channel name** at the top → a details window opens → at the very bottom you'll find the **Channel ID**, like `C0BFRTFMDDW`, with a copy button. Write it down — this is Address #3.

   ![Finding the Slack channel id](../assets/slack-channel-id.jpeg)

---

## Part 4 — Create the five credentials in n8n

A credential is n8n's encrypted safe for one secret. We create five. In n8n, open **Credentials** in the overview and click **Create Credential** for each one.

![The credentials area in n8n](../assets/n8n-overview-credentials.jpeg)

For each credential below: search for the **Type** in the picker, fill the fields, then **click the title at the top left to rename it** — the names must match *exactly*, because the imported workflows look their credentials up by name.

**Credential 1 — the YakYak API token**
- Type: **Bearer Auth**
- Field "Bearer Token": your YakYak personal access token (starts with `yy_live_`)
- Name it exactly: **`YakYak API`**

![The Bearer Auth form](../assets/add-credential-bearer-auth.jpeg)
![Renamed and saved](../assets/yakyak-api-bearer-credential.jpeg)

**Credential 2 — the door key for the webhook**
- Type: **Header Auth**
- Field "Name": `x-render-token`
- Field "Value": a random password you invent. Terminal trick: `openssl rand -hex 24`. **Keep a copy** — every request must show this key at the door.
- Name it exactly: **`YakYak render webhook token`**

![The Header Auth form](../assets/add-credential-header-auth.jpeg)
![Renamed and saved](../assets/yakyak-render-webhook-token-credential.jpeg)

**Credential 3 — Telegram**
- Type: **Telegram API**
- Field "Access Token": Secret #1 (from BotFather)
- Name it exactly: **`YakYak Telegram bot`**

![The Telegram API form](../assets/add-credential-telegram-api.jpeg)
![Renamed and saved](../assets/yakyak-telegram-bot-credential.jpeg)

**Credential 4 — Discord**
- Type: **Discord Bot API**
- Field "Bot Token": Secret #2 (from the developer portal)
- Name it exactly: **`YakYak Discord bot`**

![The Discord Bot API credential, renamed and saved](../assets/yakyak-discord-bot-credential.jpeg)

**Credential 5 — Slack**
- Type: **Slack API**
- Field "Access Token": Secret #3 (the `xoxb-…` token)
- Name it exactly: **`YakYak Slack bot`**

![The Slack API form](../assets/add-credential-slack-api.jpeg)
![Renamed and saved](../assets/yakyak-slack-bot-credential.jpeg)

When you're done, your credentials list should look like this — five entries, no duplicates:

![All five credentials](../assets/credentials-list.jpeg)

---

## Part 5 — Import the two workflows

Import the **engine first**, then the messenger.

1. In n8n click **Create Workflow**.

   ![Create Workflow button](../assets/create-workflow-button.jpeg)

2. Open the **⋯ menu** (top right of the editor) → **Import from File…** → pick **`workflow.yakyak-engine.json`**.

   ![Import from File in the menu](../assets/workflow-menu-import-from-file.jpeg)

3. **Save** it (Ctrl/Cmd-S). If any node shows a red warning triangle, open that node and re-pick the credential from its dropdown — because you created the credentials *first* with the exact names, this is usually zero clicks. A good node's credential box looks like this:

   ![An engine node with the YakYak API credential attached](../assets/get-movie-http-node-bearer-auth.jpeg)

4. Repeat steps 1–3 for **`workflow.patch-dialogue-to-message.json`**.

5. **Connect the waiter to the kitchen.** In the messenger workflow, find the **Call engine** node:

   ![The Call engine node on the canvas](../assets/call-engine-node-on-canvas.jpeg)

   If it shows a warning, that's expected — it doesn't know which workflow is the engine on *your* n8n yet:

   ![The warning before selecting](../assets/call-engine-workflow-warning.jpeg)

   Open the node and pick the engine from the workflow dropdown:

   ![Picking the engine workflow](../assets/call-engine-workflow-picker.jpeg)
   ![Engine selected](../assets/call-engine-workflow-selected.jpeg)

6. **Switch both workflows on.** Use the **Publish/Activate** control (top right) on each workflow — the messenger *must* be active for its web address to exist; activating the engine too doesn't hurt.

   ![The publish menu](../assets/publish-dropdown-menu.jpeg)
   ![Confirming](../assets/publish-workflow-dialog.jpeg)

7. Double-check the webhook door key: the **Patch request** node should show the `YakYak render webhook token` credential:

   ![The webhook trigger with Header Auth](../assets/patch-webhook-trigger-header-auth.jpeg)

---

## Part 6 — Send your first request 🎉

You need four things you collected along the way:

- your n8n's address (e.g. `https://your-n8n.example.com`)
- the **door key** (Credential 2's random value)
- a YakYak **movieId** (the `?movieId=…` part of a YakYak grid link)
- the **addresses**: Telegram chat id, Discord channel id, Slack channel id

Then run (one line, fill in your own values):

```bash
curl -sS -X POST https://YOUR-N8N/webhook/yakyak-patch-message \
  -H "Content-Type: application/json" \
  -H "x-render-token: YOUR-DOOR-KEY" \
  -d '{
    "movieId":   "YOUR-MOVIE-ID",
    "dialogue":  "The force is strong young Padawan!",
    "sceneNumber": 1,
    "deliverTo": {
      "telegram": "1759916870",
      "discord":  "1522438174092169228",
      "slack":    "C0BFRTFMDDW"
    }
  }'
```

**`deliverTo` is the whole routing system.** Include a key → that app gets the video. Leave a key out → that app is skipped. Only Slack today? Send only `"slack": "C0…"`.

Now **wait a few minutes** — changing a line makes YakYak regenerate that scene's subtitles and re-render the whole movie. You can watch it cook in n8n under **Executions** (the engine shows up as its own run):

![A run in progress](../assets/executions-list-running.jpeg)

When it finishes: Telegram gets a playable video, Discord gets the message with an embedded player, Slack gets an uploaded file — and your curl prints the receipt:

```json
{
  "url": "https://cdn.yakyak.ai/…/movie.mp4",
  "movieId": "…", "sceneNumber": 1,
  "dialogue": "The force is strong young Padawan!",
  "changed": 1,
  "deliveries": { "telegram": "video", "discord": "sent", "slack": "sent" }
}
```

Fun fact: run the exact same command again and `changed` becomes `0` — the engine notices nothing changed and skips the expensive work. Re-running is free.

---

## When something goes wrong

The run almost never "crashes" — deliveries are designed to fail *politely*, so **always read the `deliveries` part of the answer first.**

| What you see | What it means | The fix |
|---|---|---|
| `Authorization data is wrong!` (instant) | Door key mismatch | Header must be `x-render-token: <value>` and match Credential 2 exactly |
| HTTP 404 from the webhook | The messenger workflow isn't active | Switch it on (Part 5, step 6) |
| Error mentioning **Call engine** | The engine isn't selected | Part 5, step 5 |
| `"telegram": "failed"` | Bot can't reach you | Did you press **Start** on your bot? Is the chat id right? |
| `"telegram": "link"` | Video was over ~20 MB, Telegram got a link instead | Nothing — that's the built-in fallback |
| `"discord": "failed"` | Bot not in server, wrong channel id, or credential missing | Re-check Part 2b/2c; open the node and confirm the `YakYak Discord bot` credential |
| `"slack": "failed"` | Bot not in the channel, or wrong id | `/invite @YakYak` in the channel; id must start with `C` |
| `"…": "skipped"` | You didn't put that key in `deliverTo` | Intentional — add the key if you wanted it |
| Slack says sent but you see nothing | The upload had no channel to be shared into | Make sure `deliverTo.slack` is a channel **ID** (`C…`), not a name |
| Everything failed after a re-import | Credential links get dropped by importing | Open each red node, re-pick its credential, Save |

That last row is the most common trap: **importing a workflow again disconnects its credentials.** Prefer editing the existing workflow over re-importing; if you do re-import, walk through every node with a red triangle.

---

## Bonus — trigger it from GitHub

`.github/workflows/patch-dialogue-to-message.yml` in this repo runs the same request from a GitHub Actions button. Set these repository secrets (Settings → Secrets and variables → Actions):

| Secret | Value |
|---|---|
| `N8N_PATCH_MESSAGE_WEBHOOK_URL` | `https://YOUR-N8N/webhook/yakyak-patch-message` |
| `N8N_RENDER_TOKEN` | the door key |
| `TELEGRAM_CHANNEL_ID` | your chat id *(optional)* |
| `DISCORD_CHANNEL_ID` | your channel id *(optional)* |
| `SLACK_CHANNEL_ID` | your `C…` id *(optional)* |

Each destination secret is optional — leave one empty to skip that app by default; the workflow's run form can also override any of them per run. Then: **Actions → "Patch dialogue → render → message" → Run workflow**, type a new line of dialogue, and the video lands in your chats a few minutes later.

---

## How it works under the hood (for the curious)

- **Why two workflows?** The engine is reusable: this messenger calls it as a *sub-workflow*, but other automations (scheduled shows, other triggers) can call the very same engine. One kitchen, many waiters.
- **Why bots everywhere?** A bot token is one secret that can post to *any* chat — so the secret lives in a credential and the destination travels with each request. (Discord also offers simpler "incoming webhooks", but their URL hard-wires the destination, which is why this setup uses a bot there too.)
- **The delivery lanes are independent.** Each app's sender is set to "continue on error", so one broken app can't stop the others — failures just show up in the `deliveries` receipt.
- **Adding your own channel** (Teams, Mattermost, email…): open the messenger workflow and copy the Discord lane — an IF node checking your new `deliverTo` key, your app's node, both wired into a new input on **Merge deliveries** — and add one line in **Finalize delivery**. The message text already ends with the movie URL, so any plain-text channel works as-is.

---
description: One-time setup — install deps, paste your Cortex OAuth credentials, and we wire them in (~30 seconds, no terminal).
---

You are walking the user through one-time setup for `second-brain-capture`. They have installed the plugin; now they need (a) `jq` + `curl` on PATH so the hook scripts can run at all, and (b) OAuth credentials (shared with them in Slack) so the plugin can push notes to Cortex.

**Goal:** confirm `jq` + `curl` are installed, then write `~/.config/second-brain-capture/auth.json` with valid `client_id` + `client_secret`, perms `600`, with a confirmed token mint against Cortex staging.

**Why the dep check matters:** the hook scripts silently `exit 0` if `jq` or `curl` is missing (fail-open: never block the user's tool). That looks like "setup worked but nothing pushes" — the most common pilot failure mode. So we check deps **first**, install them on the spot if needed, and only then ask for credentials.

## Steps

1. **Greet briefly** (one sentence). Example: *"Hi — let's wire in your Cortex setup. Takes ~30 seconds."*

2. **Check `jq` and `curl` are on PATH.** Run this single Bash command and read the output:

    ```bash
    {
      command -v jq    >/dev/null 2>&1 && echo "jq: OK"    || echo "jq: MISSING"
      command -v curl  >/dev/null 2>&1 && echo "curl: OK"  || echo "curl: MISSING"
      command -v brew  >/dev/null 2>&1 && echo "brew: OK"  || echo "brew: MISSING"
      command -v apt-get >/dev/null 2>&1 && echo "apt: OK" || echo "apt: MISSING"
      uname -s
    }
    ```

3. **If anything reports `MISSING`,** install the missing deps before going further. Pick the right command for the platform from step 2 and run it. **Ask the user once before running an installer**, especially when it needs `sudo` — show them the exact command and wait for them to say go (or to install it themselves and re-run `/second-brain-capture:setup`).

    - **macOS with `brew: OK`** → `brew install jq curl` (covers either or both)
    - **macOS with `brew: MISSING`** → tell them to install Homebrew first (`/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`), then re-run setup. Do not try to install Homebrew yourself.
    - **Linux with `apt: OK`** → `sudo apt-get update && sudo apt-get install -y jq curl` (will prompt for password in their terminal)
    - **Linux without `apt`** → tell them to install via their distro's package manager (`dnf install jq curl`, `pacman -S jq curl`, etc.) and re-run setup.
    - **Anything else (Windows native, exotic OS)** → stop and tell them to install `jq` and `curl` manually, then re-run setup.

    After the install, **re-run the check command from step 2** and confirm both report `OK` before continuing. If still missing, stop and report — do not proceed.

4. **Ask the user (in chat) to paste their credentials.** Be explicit that any of these formats works:
   - Just the two values on separate lines (`client_id` first, then `client_secret`)
   - `client_id=... client_secret=...`
   - The JSON blob: `{"client_id":"...","client_secret":"..."}`

5. **Wait for their reply, then parse** into two variables. Strip whitespace, surrounding quotes, and any `client_id=`/`client_secret=` prefixes. If only one value is detectable or it's ambiguous, ask once more — politely — for clarification. Do not guess.

6. **Write the auth file** with one Bash command. Substitute the parsed values literally for `<CLIENT_ID>` and `<CLIENT_SECRET>`. The `printf` format string MUST be single-quoted so the secret is not subject to shell expansion. **Do not echo the secret back in chat.**

    ```bash
    mkdir -p ~/.config/second-brain-capture \
      && printf '{"client_id":"%s","client_secret":"%s"}' '<CLIENT_ID>' '<CLIENT_SECRET>' \
         > ~/.config/second-brain-capture/auth.json \
      && chmod 600 ~/.config/second-brain-capture/auth.json \
      && echo "auth file written"
    ```

7. **Verify the creds work** by minting a Cortex token. Again, the values are substituted in literally, not exported via `echo`:

    ```bash
    curl -s -m 15 -u '<CLIENT_ID>:<CLIENT_SECRET>' \
      -X POST https://cortex-stg.bukuwarung.com/api/v1/oauth2/token \
      --data-urlencode grant_type=client_credentials \
      --data-urlencode 'scope=kb:read kb:write kb:upload' \
      | jq -r 'if .access_token then "AUTH OK" else "AUTH FAILED: " + (.error_description // tostring) end'
    ```

8. **Report the result.**
    - **`AUTH OK`** → *"✅ You're set up. Now **restart Claude Code** (quit and reopen). Make sure you're on the **VPN**, then use Claude Code normally — your sessions will save redacted notes to the team KB automatically. No need to end the session."*
    - **`AUTH FAILED`** → *"❌ Those credentials didn't work — Cortex rejected them. Double-check the two values from the Slack thread (no extra spaces, no trailing quotes, full secret pasted). Run `/second-brain-capture:setup` again to retry."*

## Rules

- **Never echo the `client_secret`** in chat output, code blocks, or summaries. Refer to it as "the secret" or "your credentials."
- **Never run a `sudo` or package-installer command without asking first.** Show the command, wait for explicit go-ahead.
- **Don't run extra diagnostics** beyond the dep check, auth write, and token mint. No probing the agent, no listing files, no checking other config.
- If the auth file already exists, **overwrite silently** in step 6 — they ran `setup` explicitly.
- Keep the interaction tight: ~3–5 messages total (dep check → optional install → ask creds → write+verify → report).

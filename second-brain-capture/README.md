# second-brain-capture

A companion Claude Code plugin that turns each working session into **one curated, PII-redacted note** in a [Cortex](https://github.com/bukuwarung) knowledge base — a governed "second brain" of what your team is building.

Redaction is proxied through Cortex (OAuth) to a private AxonFlow agent, so capture works **off-VPN**, and only redaction-verified content is ever pushed. The hooks are fail-open for you (they never block a tool) and fail-closed for content (if redaction can't be verified, the event is dropped, never sent raw).

## How it works

```
UserPromptSubmit ──▶ redact via Cortex /redact proxy ──▶ per-session buffer (clean content only)
PostToolUse      ──▶ redact via Cortex /redact proxy ──▶ same buffer
Stop             ──▶ summarize the buffer ──▶ upsert ONE note per session into the Cortex KB (OAuth)
SessionEnd       ──▶ final flush of the same note
```

- **One note per session.** The first flush creates a record; later flushes update it in place, so a session maps to a single, growing note (not a pile of duplicates).
- **Redact at source.** Every captured event is sent to Cortex's `/redact` proxy (which forwards to an in-VPC AxonFlow agent and returns only the redacted text). A per-session canary probe confirms redaction is actually on before anything is trusted; if not, capture drops for that session.
- **Prompts captured too.** The user's own requests (UserPromptSubmit) are buffered through the same redact-first pipeline, so notes record what was *asked*, not just what tools ran — the digest gets a "What was asked" section and the LLM summary grounds intent in the real prompts. Toggle off with `SECOND_BRAIN_CAPTURE_PROMPTS=0`.
- **Token usage per session.** Each note ends with a deterministic "Token usage" section computed from the session transcript — request count, input/output totals, cache read/write, per-model breakdown when several models were used. Numbers only, refreshed on every flush. Toggle off with `SECOND_BRAIN_TOKEN_USAGE=0`.
- **Secret scrubbing.** High-confidence secret tokens (`sk_…`, `AKIA…`, `gh*_…`, `xox*-…`, JWTs) are scrubbed client-side before buffering, on top of the PII redaction.

## Commands

- **`/second-brain-capture:setup`** — one-time credential setup (single-machine installs; fleet installs skip this).
- **`/second-brain-capture:save`** — save something from the current conversation into the team KB on demand: a summary you just produced, a Slack thread or email digest, a meeting transcript, a decision. Claude curates it into one self-contained note, the same redact→scrub pipeline runs (fail-closed), and the note is upserted by slug — re-saving the same topic updates one record, and byte-identical content is deduped client-side and never re-uploaded. Notes land in the org-visible Team Second Brain KB by default, so the command confirms with you before saving anything that looks personal or sensitive.

## Install

### Fleet (recommended, zero-touch)

Provision via **managed settings** — no `/plugin install`, no `/setup`:

```jsonc
{
  "extraKnownMarketplaces": {
    "bukuwarung-second-brain": { "source": { "source": "github", "repo": "bukuwarung/second-brain-capture" } }
  },
  "enabledPlugins": { "second-brain-capture@bukuwarung-second-brain": true },
  "env": {
    "SECOND_BRAIN_OAUTH_CLIENT_ID": "…",
    "SECOND_BRAIN_OAUTH_CLIENT_SECRET": "…"
  }
}
```

The plugin reads the OAuth credentials from `env` at highest precedence, so once they're set the capture loop just runs. Everything else (Cortex URL, target KB, off-VPN redaction) ships as sensible defaults.

### Single machine (fallback)

```
/plugin marketplace add bukuwarung/second-brain-capture
/plugin install second-brain-capture@bukuwarung-second-brain
/second-brain-capture:setup      # walks you through pasting the OAuth creds
```

### Requirements

`jq` and `curl` on `PATH`. Without them the hooks silently no-op (fail-open) — the #1 reason notes don't appear. macOS: `brew install jq curl`. Debian/Ubuntu: `sudo apt-get install -y jq curl`.

## Configuration

All optional except the OAuth credentials. Explicit `SECOND_BRAIN_*` env wins over the baked defaults.

| Env var | Default | Purpose |
|---|---|---|
| `SECOND_BRAIN_OAUTH_CLIENT_ID` | — | Cortex OAuth client id (**required**). |
| `SECOND_BRAIN_OAUTH_CLIENT_SECRET` | — | Cortex OAuth client secret (**required**; keep it in settings `env`, not in code). |
| `SECOND_BRAIN_ENABLED` | `1` | Opt-in gate. Set `0` to pause. |
| `SECOND_BRAIN_CORTEX_URL` | Cortex staging | Cortex base URL (token + upload + `/redact`). |
| `SECOND_BRAIN_KB_ID` | Team KB | Target knowledge base for session notes. |
| `SECOND_BRAIN_OFFLINE` | `0` | `1` forces the deterministic digest (no LLM summarization). |
| `SECOND_BRAIN_SUMMARIZER_MODEL` | `claude-haiku-4-5` | Model used for the `claude -p` summary upgrade. |
| `SECOND_BRAIN_AUTHOR` | git email / `$USER` | Author attribution stamped on each note and included in structured metadata when accepted. |
| `SECOND_BRAIN_EXCLUDE_TOOLS` | — | Comma-separated tool names to skip. |
| `SECOND_BRAIN_CAPTURE_PROMPTS` | `1` | `0` stops capturing the user's prompts (tool events still captured). |
| `SECOND_BRAIN_PROMPT_MAX_CHARS` | `1500` | Per-prompt capture cap (a pasted log can't balloon the note). |
| `SECOND_BRAIN_TOKEN_USAGE` | `1` | `0` omits the per-session "Token usage" section from notes. |
| `SECOND_BRAIN_LOG` | — | `1` writes a tailable log to `~/.local/state/second-brain-capture/second-brain.log`. |

When Cortex accepts file metadata, uploaded records include structured metadata for filtering and provenance: `author`, `author_email`, `username`, `created_at`, `updated_at`, `source`, `plugin_version`, `note_type`, plus `session_id` for session notes or `save_slug` for manual saves. Human-readable author/date provenance stays in the markdown body for KB browsing.

## Privacy

- One shared KB; each note is tagged with the configured author (usually git email); `author_email` is included when available. Anyone with KB access can read the notes — including the redacted text of your prompts (disable with `SECOND_BRAIN_CAPTURE_PROMPTS=0`).
- Redaction is proxied over OAuth + TLS; raw event text transits to Cortex only to be redacted, and is not persisted there. If Cortex is unreachable, capture fails closed (drops — nothing leaks).
- Opt-in and pausable at any time (`SECOND_BRAIN_ENABLED=0`).

## License

MIT

# second-brain-capture

A companion Claude Code plugin that turns each working session into **one curated, PII-redacted note** in a [Cortex](https://github.com/bukuwarung) knowledge base — a governed "second brain" of what your team is building.

Redaction is proxied through Cortex (OAuth) to a private AxonFlow agent, so capture works **off-VPN**, and only redaction-verified content is ever pushed. The hooks are fail-open for you (they never block a tool) and fail-closed for content (if redaction can't be verified, the event is dropped, never sent raw).

## How it works

```
PostToolUse  ──▶  redact via Cortex /redact proxy  ──▶  per-session buffer (clean content only)
Stop         ──▶  summarize the buffer  ──▶  upsert ONE note per session into the Cortex KB (OAuth)
SessionEnd   ──▶  final flush of the same note
```

- **One note per session.** The first flush creates a record; later flushes update it in place, so a session maps to a single, growing note (not a pile of duplicates).
- **Redact at source.** Every captured event is sent to Cortex's `/redact` proxy (which forwards to an in-VPC AxonFlow agent and returns only the redacted text). A per-session canary probe confirms redaction is actually on before anything is trusted; if not, capture drops for that session.
- **Secret scrubbing.** High-confidence secret tokens (`sk_…`, `AKIA…`, `gh*_…`, `xox*-…`, JWTs) are scrubbed client-side before buffering, on top of the PII redaction.

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
| `SECOND_BRAIN_AUTHOR` | git email / `$USER` | Author attribution stamped on each note. |
| `SECOND_BRAIN_EXCLUDE_TOOLS` | — | Comma-separated tool names to skip. |
| `SECOND_BRAIN_LOG` | — | `1` writes a tailable log to `~/.local/state/second-brain-capture/second-brain.log`. |

## Privacy

- One shared KB; each note is tagged with the author's git email. Anyone with KB access can read the notes.
- Redaction is proxied over OAuth + TLS; raw event text transits to Cortex only to be redacted, and is not persisted there. If Cortex is unreachable, capture fails closed (drops — nothing leaks).
- Opt-in and pausable at any time (`SECOND_BRAIN_ENABLED=0`).

## License

MIT

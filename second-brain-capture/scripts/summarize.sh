#!/usr/bin/env bash
# Summarize a redacted session buffer into a curated markdown note body.
# Sourced by session-flush.sh. Exposes sb_summarize <buffer_file>.
#
# Priority chain (first that returns content wins):
#   1. `claude -p` headless — uses the user's Claude Code subscription (or API
#      auth — whatever Claude Code itself runs on). No new secret on the laptop,
#      same vendor + trust boundary the user is already using. Default path.
#   2. Direct Anthropic API — only fires when ANTHROPIC_API_KEY is explicitly
#      set. Kept for API-only users who don't have the Claude Code CLI.
#   3. Deterministic offline digest — final fallback. Always available; runs
#      with no LLM at all. Forced by SECOND_BRAIN_OFFLINE=1.
#
# The buffer is already PII-redacted upstream, so passing it to any LLM is safe.

# Default model for the cloud paths. Haiku because session notes are short
# markdown and cheap-fast > smart-slow for this workload; users can override.
SB_SUMMARIZER_MODEL="${SECOND_BRAIN_SUMMARIZER_MODEL:-claude-haiku-4-5}"

# Tools the `claude -p` summarizer subprocess is allowed to invoke. Empty by
# design: it only needs to read its prompt and stdin and emit markdown. Blocking
# Bash/Read/Write/Edit/Web/Task also makes recursion impossible.
SB_SUMMARIZER_DISALLOWED_TOOLS="${SECOND_BRAIN_SUMMARIZER_DISALLOWED_TOOLS:-Bash Read Write Edit MultiEdit NotebookEdit WebFetch WebSearch Task Agent}"

# Normalize one buffered event to {tool,input,output}, tolerating both the
# current split format ({tool,input,output}) and the pre-v0.5 single-blob format
# ({tool,text}) so an in-flight buffer from before an upgrade still summarizes.
SB__NORM='def norm: { tool: (.tool // "?"), input: (.input // ""), output: (.output // (.text // "")) };'

# Build a plain-text transcript from the JSONL buffer (one line per event).
sb__transcript() {
  jq -r "$SB__NORM"'
    norm
    | "- [" + .tool + "] "
      + ((.input
          + (if (.output|length) > 0
             then (if (.input|length) > 0 then " => " else "" end) + .output
             else "" end)) | gsub("\n"; " ") | .[0:600])
  ' "$1" 2>/dev/null
}

# Shared prompt for both LLM paths. Frame it so the model knows the input is
# already redacted and should preserve placeholders verbatim. The requested
# sections mirror the deterministic digest (Summary / What happened / Files
# touched / Commands run / Capabilities) so the SessionEnd upgrade reads as a
# richer, synthesized version of the same note rather than a different shape.
sb__summary_prompt() {
  printf 'You are writing ONE concise knowledge-base note from a Claude Code developer session. The events below are already PII-redacted: preserve any [REDACTED:...] placeholders verbatim and never invent values. Output GitHub-flavored markdown with the sections below, omitting any that would be empty. Do NOT add a top-level # heading (the note already has one).\n\n## Summary\nOne or two sentences: what this session set out to do and what came of it.\n\n## What happened\n3-6 bullets on what was built, changed, debugged, decided, or learned. Synthesize across events; do not just relist them.\n\n### Files touched\nThe files created or modified, each with a few words on what changed.\n\n### Commands run\nThe notable shell commands and what they accomplished (skip trivial or duplicate ones).\n\n**Capabilities:** a comma-separated list of skills/tools demonstrated, for a team capability directory.\n\nKeep it factual and skimmable.'
}

# Accept an LLM reply as a real note ONLY if it contains one of the sections the
# prompt asked for. A thin/empty transcript makes the model reply with a
# clarification/refusal ("I don't see any events, please provide…") instead of a
# note — that has none of these headers, so we reject it and let the deterministic
# digest stand rather than overwrite a good note with a refusal. 0 = looks valid.
sb__looks_like_summary() {
  printf '%s' "$1" | grep -qiE '(^|\n)#{1,3}[[:space:]]+(Summary|What happened|Files touched|Commands run)([[:space:]]|$)|(^|\n)\*\*Capabilities'
}

# Deterministic, LLM-free digest. Used as the per-turn instant note and the final
# fallback (and when SECOND_BRAIN_OFFLINE=1 forces it). Produces a COMPACT, BOUNDED,
# uniform note: a one-line overview + tool tally, then "Files touched" and
# "Commands run" sections derived from the captured input descriptors, then a short
# "Activity" list of tool + input one-liners. Every section is capped AND it never
# inlines event OUTPUT — so a long session yields a small note (a few KB) instead of
# a tens-of-KB raw transcript dump (the old numbered timeline paired each event's
# input with a 240-char output excerpt, which ballooned long sessions to ~50 KB and
# made notes wildly non-uniform). The curated LLM upgrade (sb_summarize_llm) layers
# the narrative on top. All instant, no LLM.
sb__fallback_summary() {
  local buffer="$1"
  jq -rs \
     --argjson maxact "${SECOND_BRAIN_DIGEST_MAX_EVENTS:-12}" \
     --argjson maxfiles "${SECOND_BRAIN_DIGEST_MAX_FILES:-25}" \
     --argjson maxcmds "${SECOND_BRAIN_DIGEST_MAX_COMMANDS:-20}" \
     "$SB__NORM"'
    def oneline($n): gsub("\\s+"; " ") | gsub("^ +| +$"; "")
                     | (if length > $n then .[0:$n] + "…" else . end);
    def isfile($t): (["Edit","MultiEdit","Write","Read","NotebookEdit"] | index($t)) != null;
    def plural($n): if $n == 1 then "" else "s" end;

    map(norm) as $ev
    | ($ev | length) as $n
    | ($ev | group_by(.tool) | map({t: .[0].tool, c: length}) | sort_by(-.c)
        | map("\(.t) ×\(.c)") | join(" · ")) as $tally
    | ($ev | map(select(isfile(.tool) and (.input | length) > 0))
        | group_by(.input)
        | map("- `\(.[0].input)` — " + ((map(.tool) | unique) | join(", ")))) as $files
    | ($ev | map(select(.tool == "Bash" and (.input | length) > 0) | .input) | unique
        | map("- `\(. | oneline(160))`")) as $cmds
    | ($ev | map(select((.input | length) > 0)
        | "- **\(.tool)** `\(.input | oneline(120))`")) as $act
    | ($files | length) as $nf | ($cmds | length) as $nc | ($act | length) as $na
    | "## Session activity (auto-digest)\n"
      + "\n**\($n) event\(plural($n))** · " + $tally + "\n"
      + (if $nf > 0 then "\n### Files touched\n" + ($files[0:$maxfiles] | join("\n"))
           + (if $nf > $maxfiles then "\n- _… \($nf - $maxfiles) more_" else "" end) + "\n" else "" end)
      + (if $nc > 0 then "\n### Commands run\n" + ($cmds[0:$maxcmds] | join("\n"))
           + (if $nc > $maxcmds then "\n- _… \($nc - $maxcmds) more_" else "" end) + "\n" else "" end)
      + (if $na > 0 then "\n### Activity\n" + ($act[0:$maxact] | join("\n"))
           + (if $na > $maxact then "\n- _… \($na - $maxact) more event\(plural($na - $maxact))_" else "" end) + "\n" else "" end)
  ' "$buffer" 2>/dev/null
}

# `claude -p` headless. Sets SECOND_BRAIN_SUMMARIZING=1 so the recursion guard
# in capture-event.sh and session-flush.sh keeps the inner session from
# re-capturing itself. --disallowedTools blocks every code-using tool — the
# summarizer should only read stdin and emit text. --no-session-persistence
# keeps these one-shot calls out of the user's saved session history.
#
# Resolve the `claude` binary. Hooks launched by Claude Code from a GUI/IDE (the
# VS Code extension, the Dock) inherit a MINIMAL PATH that usually omits
# ~/.local/bin and /opt/homebrew/bin, so a bare `command -v claude` fails there
# and the LLM upgrade is silently skipped — the note lands digest-only (observed
# on staging: the summary upgrade worked on exactly 1 of 5 teammates' machines,
# the terminal-launched one; the other four got digest-only every time). Probe
# PATH first, then the known install locations, honoring an explicit
# SECOND_BRAIN_CLAUDE_BIN override. Prints the path (return 0) or nothing (1).
sb__claude_bin() {
  if [ -n "${SECOND_BRAIN_CLAUDE_BIN:-}" ] && [ -x "${SECOND_BRAIN_CLAUDE_BIN}" ]; then
    printf '%s' "${SECOND_BRAIN_CLAUDE_BIN}"; return 0
  fi
  if command -v claude >/dev/null 2>&1; then command -v claude; return 0; fi
  local c
  for c in "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" \
           "/opt/homebrew/bin/claude" "/usr/local/bin/claude" \
           "$HOME/.claude/local/node_modules/.bin/claude"; do
    [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# Returns 0 + summary on stdout when successful, 1 otherwise.
sb__claude_p_summary() {
  local buffer="$1" transcript prompt full_prompt result max claude_bin
  claude_bin="$(sb__claude_bin)" || return 1

  transcript="$(sb__transcript "$buffer")"
  [ -n "$transcript" ] || return 1
  # Cap the transcript we feed the model: the events now ride INSIDE the prompt
  # argument (see below), so a huge session must not overflow the argv length
  # limit. Keep the TAIL (most recent events matter most) — bounded, not
  # exhaustive, by design; the deterministic digest already caps its sections.
  max="${SECOND_BRAIN_SUMMARIZER_TRANSCRIPT_MAX_CHARS:-60000}"
  if [ "${#transcript}" -gt "$max" ]; then
    transcript="$(printf '…(older events omitted)…\n%s' "${transcript:$(( ${#transcript} - max ))}")"
  fi
  # Pass the events INSIDE the prompt argument, NOT on stdin. Piping the
  # transcript to `claude -p "$instruction"` (the old approach) did not reliably
  # reach the model in the hook exec context — the model saw only the instruction
  # and replied "I don't see any events, please provide…", which the weak length
  # gate then let overwrite the good digest. Embedding the events in the prompt
  # (as the Anthropic-API path already does) makes the model always see them.
  prompt="$(sb__summary_prompt)"
  full_prompt="$(printf '%s\n\nSession events (already PII-redacted):\n%s' "$prompt" "$transcript")"

  # Hard cap via background-kill in case the CLI hangs (no `timeout` on stock
  # macOS, so we roll our own). The killer SIGKILLs the claude process AND its
  # children: claude spawns node/MCP helpers that otherwise orphan and keep the
  # hook's stdout pipe open — that is what stretched a 60s cap into multi-minute
  # Stop hangs. Default 45s leaves headroom under the SessionEnd hook timeout for
  # the in-place PUT that follows. Stdin is closed (events ride in the prompt).
  result="$(
    ( export SECOND_BRAIN_SUMMARIZING=1; \
        export PATH="$(dirname "$claude_bin"):$PATH"; \
        "$claude_bin" -p \
          --model "$SB_SUMMARIZER_MODEL" \
          --disallowedTools $SB_SUMMARIZER_DISALLOWED_TOOLS \
          --no-session-persistence \
          "$full_prompt" </dev/null 2>/dev/null & \
       _pid=$!; \
       (sleep "${SECOND_BRAIN_SUMMARIZER_TIMEOUT_SECONDS:-45}" && { pkill -9 -P "$_pid" 2>/dev/null; kill -9 "$_pid" 2>/dev/null; }) >/dev/null 2>&1 & _killer=$!; \
       wait "$_pid" 2>/dev/null; _rc=$?; \
       kill -9 "$_killer" 2>/dev/null; pkill -9 -P "$_pid" 2>/dev/null; \
       exit "$_rc")
  )" || result=""

  # Accept only if the reply looks like the requested note (has a real section
  # header). A clarification/refusal reply has none, so it is rejected and the
  # deterministic digest stands — a refusal can never overwrite a good note.
  if [ -n "$result" ] && sb__looks_like_summary "$result"; then
    printf '%s\n' "$result"
    return 0
  fi
  sb_log "summarize-llm: claude -p reply rejected (empty / no note sections / refusal)"
  return 1
}

# Direct Anthropic API path. Kept for API-only users who don't have the Claude
# Code CLI installed but do have ANTHROPIC_API_KEY in their environment.
# Returns 0 + summary on stdout when successful, 1 otherwise.
sb__anthropic_api_summary() {
  local buffer="$1" transcript prompt body_file http text
  [ -n "${ANTHROPIC_API_KEY:-}" ] || return 1

  transcript="$(sb__transcript "$buffer")"
  [ -n "$transcript" ] || return 1
  prompt="$(printf '%s\n\nSession events:\n%s' "$(sb__summary_prompt)" "$transcript")"

  body_file="$(mktemp 2>/dev/null)" || return 1
  http="$(curl -sS --max-time 30 \
    -o "$body_file" -w '%{http_code}' \
    -X POST "https://api.anthropic.com/v1/messages" \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "$(jq -n --arg model "$SB_SUMMARIZER_MODEL" --arg prompt "$prompt" \
      '{model:$model, max_tokens:1024, messages:[{role:"user", content:$prompt}]}')" \
    2>/dev/null)" || http=""

  if [ "$http" = "200" ]; then
    text="$(jq -r '.content[0].text // empty' "$body_file" 2>/dev/null)"
  fi
  rm -f "$body_file"

  if [ -n "${text:-}" ] && sb__looks_like_summary "$text"; then
    printf '%s\n' "$text"
    return 0
  fi
  return 1
}

# THE note body that every flush pushes (markdown on stdout). Deterministic and
# instant — it never calls an LLM, so it cannot blow the hook timeout and the
# note ALWAYS lands. This is the reliability guarantee: capture -> digest -> push
# runs in well under a second. The LLM nicety is layered on top, off the push's
# critical path (sb_summarize_llm), and only at SessionEnd.
sb_summarize() {
  local buffer="$1" body
  [ -s "$buffer" ] || return 1
  body="$(sb__fallback_summary "$buffer")"
  # Never emit an empty note body: if the structured digest fails (e.g. a jq
  # quirk), fall back to the flat transcript under the same header.
  if [ -z "$body" ]; then
    body="$(printf '## Session activity (auto-digest)\n\n%s' "$(sb__transcript "$buffer")")"
  fi
  printf '%s\n' "$body"
  return 0
}

# Best-effort LLM upgrade of the FINAL (SessionEnd) note. Echoes an improved body
# on stdout and returns 0, or returns non-zero if no LLM path is usable. The
# caller MUST have already pushed the digest note, so a failure/timeout here just
# leaves that digest in place — the LLM call is never in the push's critical path.
# Honours SECOND_BRAIN_OFFLINE=1 (skips entirely) and no-ops inside the
# summarizer's own subprocess (recursion guard).
sb_summarize_llm() {
  local buffer="$1"
  [ -s "$buffer" ] || return 1
  [ "${SECOND_BRAIN_OFFLINE:-}" = "1" ] && return 1
  [ "${SECOND_BRAIN_SUMMARIZING:-}" = "1" ] && return 1

  # 1) Preferred: `claude -p` subscription path. No new secret; same vendor +
  # trust boundary the user is already using for their Claude Code session.
  # sb__claude_bin (not a bare `command -v claude`) so it's found even when the
  # hook's PATH is the minimal GUI/IDE-launch one that omits ~/.local/bin etc.
  if sb__claude_bin >/dev/null 2>&1; then
    if sb__claude_p_summary "$buffer"; then
      return 0
    fi
    sb_log "summarize-llm: claude -p produced nothing; trying next path"
  fi

  # 2) Compatibility: direct Anthropic API for users with a key but no CLI.
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    if sb__anthropic_api_summary "$buffer"; then
      return 0
    fi
    sb_log "summarize-llm: anthropic API produced nothing"
  fi

  return 1
}

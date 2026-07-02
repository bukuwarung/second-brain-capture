#!/usr/bin/env bash
# UserPromptSubmit hook — capture the user's prompt, redacted at source, so the
# session note records what was ASKED, not just what tools ran. Same contract as
# capture-event.sh: fail-CLOSED for content (unverified redaction → drop, never
# buffer raw), fail-OPEN for the user (always exit 0).
#
# IMPORTANT: for UserPromptSubmit hooks Claude Code injects stdout into the
# conversation context, so this script must never print to stdout (sb_log goes
# to stderr + file only).

[ "${SECOND_BRAIN_SUMMARIZING:-}" = "1" ] && exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/config.sh"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/cortex-auth.sh"

sb_enabled || exit 0
# Prompt capture is separately toggleable: prompts are the user's own words and
# carry more incidental PII than tool events, so give operators a dedicated off
# switch without disabling capture entirely.
case "${SECOND_BRAIN_CAPTURE_PROMPTS:-1}" in
  0 | false | FALSE | no | off) exit 0 ;;
esac
if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  exit 0
fi

INPUT="$(cat)"
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
PROMPT_TEXT="$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)"
[ -z "$SESSION_ID" ] && SESSION_ID="no-session"
[ -z "$PROMPT_TEXT" ] && exit 0

# Bound it: one pasted log file must not balloon the note. The digest and the
# LLM transcript both re-cap downstream; this is the at-capture guard.
SB_PROMPT_MAX="${SECOND_BRAIN_PROMPT_MAX_CHARS:-1500}"
[ "${#PROMPT_TEXT}" -gt "$SB_PROMPT_MAX" ] && PROMPT_TEXT="${PROMPT_TEXT:0:$SB_PROMPT_MAX}…"

# Same fail-closed redaction as tool events: confirmed redact mode, then redact,
# then client-side secret scrub. Drops are counted so the note can disclose them.
if ! sb_redact_mode_ok "$SESSION_ID"; then
  sb_ensure_buffer_dir && { c=$(cat "$(sb_dropped_file "$SESSION_ID")" 2>/dev/null || echo 0); echo $((c + 1)) > "$(sb_dropped_file "$SESSION_ID")"; }
  sb_log "drop (redact mode unconfirmed) prompt"
  exit 0
fi
CLEAN_TEXT="$(sb_redact_message "$(sb_connector_type UserPrompt)" "$PROMPT_TEXT")"
if [ $? -ne 0 ]; then
  sb_ensure_buffer_dir && { c=$(cat "$(sb_dropped_file "$SESSION_ID")" 2>/dev/null || echo 0); echo $((c + 1)) > "$(sb_dropped_file "$SESSION_ID")"; }
  sb_log "drop (redaction unverified) prompt"
  exit 0
fi
CLEAN_TEXT="$(sb_scrub_secrets "$CLEAN_TEXT")"
CLEAN_TEXT="$(sb_trim "$CLEAN_TEXT")"
[ -z "$CLEAN_TEXT" ] && exit 0

# Buffer as a pseudo-tool event ({tool:"UserPrompt", input:<text>}) so the
# existing transcript/digest/summary machinery sees prompts in chronological
# order with the turn's tool events, no schema change.
sb_ensure_buffer_dir || exit 0
SB_TS="$(date -u +%FT%TZ)"
SB_LINE="$(jq -nc --arg ts "$SB_TS" --arg input "$CLEAN_TEXT" \
  '{ts:$ts, tool:"UserPrompt", input:$input, output:""}' 2>/dev/null)"
SB_FILE="$(sb_buffer_file "$SESSION_ID")"
[ -n "$SB_LINE" ] && printf '%s\n' "$SB_LINE" >> "$SB_FILE" 2>/dev/null
sb_log "capture: buffered prompt len=${#CLEAN_TEXT}"

exit 0

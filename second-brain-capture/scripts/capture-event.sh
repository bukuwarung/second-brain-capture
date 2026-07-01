#!/usr/bin/env bash
# PostToolUse hook — capture one tool event, redacted at source.
#
# Flow: build a compact event text (tool + input + output) -> redact it via the
# LOCAL AxonFlow agent's check_output -> append the redacted text to the
# per-session buffer. Redaction is fail-CLOSED for content: if the agent call
# cannot be verified, the event is dropped (never written raw). The hook itself
# is fail-OPEN for the user: it always exits 0 and never blocks the tool.

# Recursion guard. summarize.sh's `claude -p` path sets SECOND_BRAIN_SUMMARIZING=1
# before invoking the inner headless Claude session. The plugin's hooks fire
# inside that inner session too, so without this guard the summarizer would
# re-capture its own (non-)tool calls and the buffer could grow during
# summarization. Bail out cheaply before sourcing anything.
[ "${SECOND_BRAIN_SUMMARIZING:-}" = "1" ] && exit 0

# Locate and load shared config.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/config.sh"
# cortex-auth.sh provides sb_cortex_token, used by the Cortex redaction proxy
# (sb_redact_message) so per-event redaction can authenticate. Token is cached.
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/cortex-auth.sh"

# Opt-in gate + dependency check. Silent no-op otherwise (fail-open).
sb_enabled || exit 0
if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  exit 0
fi

INPUT="$(cat)"
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)"
TOOL_INPUT="$(printf '%s' "$INPUT" | jq -c '.tool_input // {}' 2>/dev/null || echo '{}')"
TOOL_RESPONSE="$(printf '%s' "$INPUT" | jq -c '.tool_response // {}' 2>/dev/null || echo '{}')"

[ -z "$SESSION_ID" ] && SESSION_ID="no-session"
[ -z "$TOOL_NAME" ] && exit 0
sb_excluded_tool "$TOOL_NAME" && exit 0

# Salient, human-meaningful INPUT per tool (the command, file, url, ...). This
# one field is what identifies the action, so it drives the digest's "Commands
# run" / "Files touched" sections and the per-event timeline — far more useful
# than a raw key=value dump of every argument.
sb_input_descriptor() {
  case "$1" in
    Bash)         printf '%s' "$TOOL_INPUT" | jq -r '.command // ""' 2>/dev/null ;;
    Edit|MultiEdit|Write|Read)
                  printf '%s' "$TOOL_INPUT" | jq -r '.file_path // ""' 2>/dev/null ;;
    NotebookEdit) printf '%s' "$TOOL_INPUT" | jq -r '.notebook_path // .file_path // ""' 2>/dev/null ;;
    Grep)         printf '%s' "$TOOL_INPUT" | jq -r '(.pattern // "") + (if .path then " in " + (.path|tostring) else "" end)' 2>/dev/null ;;
    Glob)         printf '%s' "$TOOL_INPUT" | jq -r '.pattern // ""' 2>/dev/null ;;
    WebFetch)     printf '%s' "$TOOL_INPUT" | jq -r '.url // ""' 2>/dev/null ;;
    WebSearch)    printf '%s' "$TOOL_INPUT" | jq -r '.query // ""' 2>/dev/null ;;
    Task)         printf '%s' "$TOOL_INPUT" | jq -r '.description // .subagent_type // ""' 2>/dev/null ;;
    *)            printf '%s' "$TOOL_INPUT" | jq -rc 'to_entries | map("\(.key)=\(.value|tostring)") | join(" ")' 2>/dev/null ;;
  esac
}

# Build the per-tool OUTPUT text, mirroring the AxonFlow plugin's extraction.
OUTPUT_TEXT=""
case "$TOOL_NAME" in
  Bash)
    OUTPUT_TEXT="$(printf '%s' "$TOOL_RESPONSE" | jq -r '.stdout // empty' 2>/dev/null)"
    if [ -z "$OUTPUT_TEXT" ]; then
      OUTPUT_TEXT="$(printf '%s' "$TOOL_INPUT" | jq -r '.command // empty' 2>/dev/null)"
    fi
    ;;
  Write)        OUTPUT_TEXT="$(printf '%s' "$TOOL_INPUT" | jq -r '.content // empty' 2>/dev/null)" ;;
  Edit)         OUTPUT_TEXT="$(printf '%s' "$TOOL_INPUT" | jq -r '.new_string // empty' 2>/dev/null)" ;;
  NotebookEdit) OUTPUT_TEXT="$(printf '%s' "$TOOL_INPUT" | jq -r '.cell_content // .content // empty' 2>/dev/null)" ;;
  mcp__*)       OUTPUT_TEXT="$(printf '%s' "$TOOL_RESPONSE" | jq -c '.' 2>/dev/null)" ;;
  *)            OUTPUT_TEXT="$(printf '%s' "$TOOL_RESPONSE" | jq -c '.' 2>/dev/null)" ;;
esac

INPUT_DESC="$(sb_input_descriptor "$TOOL_NAME")"

# Bound each part so one chatty tool call can't bloat the note (the digest only
# ever shows an excerpt anyway). The buffer is redacted, so this is purely a
# size guard, not a redaction concern.
SB_OUTPUT_MAX="${SECOND_BRAIN_EVENT_OUTPUT_MAX_CHARS:-2000}"
SB_INPUT_MAX="${SECOND_BRAIN_EVENT_INPUT_MAX_CHARS:-600}"
[ "${#OUTPUT_TEXT}" -gt "$SB_OUTPUT_MAX" ] && OUTPUT_TEXT="${OUTPUT_TEXT:0:$SB_OUTPUT_MAX}…"
[ "${#INPUT_DESC}"  -gt "$SB_INPUT_MAX" ]  && INPUT_DESC="${INPUT_DESC:0:$SB_INPUT_MAX}…"

# Nothing meaningful to capture.
if [ -z "$OUTPUT_TEXT" ] && [ -z "$INPUT_DESC" ]; then
  exit 0
fi

# Compose ONE event for redaction, with sentinels around each part so the
# redacted result can be split back into input/output. The agent masks PII
# inline but leaves these ASCII sentinels intact, so a single redaction call
# (not two) still yields cleanly separated fields. Both parts are redacted.
SB_SENT_IN='<<<SB:IN>>>'
SB_SENT_OUT='<<<SB:OUT>>>'
EVENT_TEXT="$(printf 'tool: %s\n%s\n%s\n%s\n%s' "$TOOL_NAME" "$SB_SENT_IN" "$INPUT_DESC" "$SB_SENT_OUT" "$OUTPUT_TEXT")"

# Fail-closed safety: only trust per-event redaction if the agent is confirmed
# to be in redact mode for this session. In warn/observe mode check_output
# passes PII through unmodified, which would otherwise be buffered raw.
if ! sb_redact_mode_ok "$SESSION_ID"; then
  sb_ensure_buffer_dir && { c=$(cat "$(sb_dropped_file "$SESSION_ID")" 2>/dev/null || echo 0); echo $((c + 1)) > "$(sb_dropped_file "$SESSION_ID")"; }
  sb_log "drop (redact mode unconfirmed) tool=$TOOL_NAME"
  exit 0
fi

# Redact at source. sb_redact_message prefers Cortex's /redact proxy (so this
# works off-VPN: only the public, OAuth-gated Cortex is contacted and the agent
# stays in-VPC) and falls back to a direct agent call when Cortex creds are
# absent. Fail-CLOSED for content: a non-zero return (no token, non-200,
# unparseable response, or policy block) means the event is dropped, never
# written raw. Track the drop.
CONNECTOR_TYPE="$(sb_connector_type "$TOOL_NAME")"
CLEAN_TEXT="$(sb_redact_message "$CONNECTOR_TYPE" "$EVENT_TEXT")"
SB_REDACT_RC=$?
if [ "$SB_REDACT_RC" -ne 0 ]; then
  sb_ensure_buffer_dir && { c=$(cat "$(sb_dropped_file "$SESSION_ID")" 2>/dev/null || echo 0); echo $((c + 1)) > "$(sb_dropped_file "$SESSION_ID")"; }
  sb_log "drop (redaction unverified) tool=$TOOL_NAME"
  exit 0
fi

# Defense in depth: scrub secret tokens that the agent's PII redaction misses.
CLEAN_TEXT="$(sb_scrub_secrets "$CLEAN_TEXT")"

# Split the redacted blob back into its input/output parts on the sentinels. If
# they didn't survive (unexpected — the agent shouldn't touch ASCII markers),
# fall back to storing the whole thing as output so nothing is lost.
SB_IN_CLEAN=""
SB_OUT_CLEAN="$CLEAN_TEXT"
case "$CLEAN_TEXT" in
  *"$SB_SENT_OUT"*)
    SB_IN_CLEAN="${CLEAN_TEXT#*"$SB_SENT_IN"}"; SB_IN_CLEAN="${SB_IN_CLEAN%%"$SB_SENT_OUT"*}"
    SB_OUT_CLEAN="${CLEAN_TEXT#*"$SB_SENT_OUT"}"
    ;;
esac
SB_IN_CLEAN="$(sb_trim "$SB_IN_CLEAN")"
SB_OUT_CLEAN="$(sb_trim "$SB_OUT_CLEAN")"

# Append one redaction-verified event to the session buffer. Materialize the
# JSON line and the target path into variables first, then append — avoids a
# command-substitution-in-redirect quirk seen under some hook exec contexts.
sb_ensure_buffer_dir || exit 0
SB_TS="$(date -u +%FT%TZ)"
SB_LINE="$(jq -nc --arg ts "$SB_TS" --arg tool "$TOOL_NAME" --arg input "$SB_IN_CLEAN" --arg output "$SB_OUT_CLEAN" \
  '{ts:$ts, tool:$tool, input:$input, output:$output}' 2>/dev/null)"
SB_FILE="$(sb_buffer_file "$SESSION_ID")"
[ -n "$SB_LINE" ] && printf '%s\n' "$SB_LINE" >> "$SB_FILE" 2>/dev/null
sb_log "capture: buffered tool=$TOOL_NAME in=${#SB_IN_CLEAN} out=${#SB_OUT_CLEAN}"

exit 0

#!/usr/bin/env bash
# SessionEnd hook — turn the redacted session buffer into ONE curated note and
# push it to the Cortex KB. Append-only history; idempotent in-place updates via
# a stable externalRecordId (session id) + externalRevisionId (content hash).
#
# Fail-CLOSED for the push: never POST without a verified auth token, and only
# ever sends buffer content (which is already redaction-verified by capture).
# Fail-OPEN for the user: always exits 0.

# Recursion guard. When summarize.sh invokes `claude -p`, the inner Claude Code
# session also fires Stop/SessionEnd hooks at the end of its single turn. If we
# didn't short-circuit here, every summary call would trigger another flush
# attempt for an unrelated session id and burn a Cortex round-trip.
[ "${SECOND_BRAIN_SUMMARIZING:-}" = "1" ] && exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/config.sh"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/cortex-auth.sh"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/summarize.sh"

sb_enabled || exit 0
if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  exit 0
fi

# Reclaim state from sessions that ended and were never resumed. We keep per-
# session state across SessionEnd now (so a resumed session_id upserts ONE record
# instead of duplicating), so this age-based sweep is what bounds disk. Cheap,
# best-effort, and safe to run on every flush.
sb_gc_stale_state

INPUT="$(cat 2>/dev/null)"
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
[ -z "$SESSION_ID" ] && SESSION_ID="no-session"
TRANSCRIPT_PATH="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)"

# Runs on BOTH Stop (end of every turn, incremental — buffer kept) and SessionEnd
# (final — buffer cleared). Relying on SessionEnd alone would mean notes never
# appear, since sessions are rarely ended cleanly.
HOOK_EVENT="$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)"
# SessionEnd carries a `reason`; Stop does not. Treat either signal as final so
# the buffer still clears if a Claude Code build omits hook_event_name.
HOOK_REASON="$(printf '%s' "$INPUT" | jq -r '.reason // empty' 2>/dev/null)"
FINAL=0
if [ "$HOOK_EVENT" = "SessionEnd" ] || { [ -z "$HOOK_EVENT" ] && [ -n "$HOOK_REASON" ]; }; then
  FINAL=1
fi

BUFFER="$(sb_buffer_file "$SESSION_ID")"
sb_log "flush: enter session=$SESSION_ID event=${HOOK_EVENT:-?} final=$FINAL"
[ -s "$BUFFER" ] || { sb_log "flush: empty buffer for $SESSION_ID"; exit 0; }

# Need Cortex config to push. If absent, keep the buffer (nothing lost) and exit.
if [ -z "$SB_CORTEX_URL" ] || [ -z "$SB_KB_ID" ]; then
  sb_log "flush: Cortex URL / KB id not configured; keeping buffer"
  exit 0
fi

# Incremental (Stop) flushes are debounced and only run when there are new events
# since the last flush; the final (SessionEnd) flush always runs. Either way the
# note upserts in place, so repeated flushes update ONE record.
# Quick pre-check before taking the lock: in the common debounced case we skip
# without touching the lock at all.
if ! sb_should_flush_now "$FINAL" "$SESSION_ID"; then
  sb_log "flush: skip (debounced / no new events) session=$SESSION_ID event=${HOOK_EVENT:-?}"
  exit 0
fi

# Serialize concurrent flushes for this session. Stop and SessionEnd can fire
# near-simultaneously (and globally-registered hooks can double-fire); without
# this, two flushes could BOTH find no record id yet and BOTH create a record —
# the exact duplicate bug. The loser of a Stop race just exits (the winner does
# the work). A final (SessionEnd) flush proceeds even if it can't grab the lock,
# so the buffer still gets cleared (fail-open).
SB_HAVE_LOCK=0
if sb_acquire_flush_lock "$SESSION_ID"; then
  SB_HAVE_LOCK=1
elif [ "$FINAL" != "1" ]; then
  sb_log "flush: another flush in progress for $SESSION_ID; skipping"
  exit 0
else
  sb_log "flush: proceeding without lock (final flush) for $SESSION_ID"
fi

# Re-check under the lock: another flush may have just completed the work.
if [ "$SB_HAVE_LOCK" = "1" ] && ! sb_should_flush_now "$FINAL" "$SESSION_ID"; then
  sb_release_flush_lock "$SESSION_ID"
  sb_log "flush: skip after lock (already flushed) session=$SESSION_ID"
  exit 0
fi

# Build the note body. Once this session has produced an LLM summary it is the
# body (so a plain Stop flush or the final SessionEnd can NEVER overwrite the
# curated summary back to a raw digest); otherwise the body is the INSTANT
# deterministic digest. Either way the push runs fast and the note always lands;
# the LLM upgrade (Stop only, gated) refreshes the stored summary out of band.
AUTHOR="$(sb_author)"
DAY="$(date -u +%F)"
DROPPED="$(cat "$(sb_dropped_file "$SESSION_ID")" 2>/dev/null || echo 0)"
SB_SUMMARY_F="$(sb_summary_file "$SESSION_ID")"
if [ -s "$SB_SUMMARY_F" ]; then
  BODY="$(cat "$SB_SUMMARY_F" 2>/dev/null)"
else
  BODY="$(sb_summarize "$BUFFER")"
fi

# Per-session token totals from the Claude Code transcript. Computed once per
# flush and appended to every render; refreshed on each upsert so the note ends
# with the session's final numbers. Pure numbers, deterministic (never touches
# the LLM body), best-effort — an unreadable transcript just omits the section.
USAGE_MD=""
if [ "${SECOND_BRAIN_TOKEN_USAGE:-1}" != "0" ]; then
  USAGE_MD="$(sb_token_usage "$TRANSCRIPT_PATH")"
fi

# Render a note file from a body. Reused for the digest push and the in-place
# LLM upgrade so both carry the same header/provenance.
sb_render_note() {  # $1=outfile  $2=body
  {
    printf '# Session note — %s — %s\n\n' "$AUTHOR" "$DAY"
    printf '_session: %s_\n\n' "$SESSION_ID"
    [ "$DROPPED" != "0" ] && printf '> Note: %s event(s) omitted because redaction could not be verified.\n\n' "$DROPPED"
    printf '%s\n' "$2"
    [ -n "$USAGE_MD" ] && printf '\n%s\n' "$USAGE_MD"
  } > "$1"
}

# Best-effort LLM upgrade of the note IN PLACE, on the LIVE session (a Stop
# flush). The digest has already been pushed, so a slow/failed/killed `claude -p`
# here just leaves that digest standing — the upgrade is never on the push's
# critical path. The refresh marker is stamped UP FRONT (before the model call),
# so even if `claude -p` hangs and the hook is killed here, the once-per-window
# gate still holds and a persistently slow/unavailable summarizer can never
# reintroduce a per-turn model call. A transient failure simply refreshes on the
# next window instead of retrying every turn.
sb_try_llm_upgrade() {  # $1 = record id to update in place
  local rid="$1" upbody uphttp up_updated_at up_last_modified_ms up_files_meta
  sb_ensure_buffer_dir && date +%s > "$(sb_summary_marker "$SESSION_ID")" 2>/dev/null
  upbody="$(sb_summarize_llm "$BUFFER")"
  if [ -z "$upbody" ]; then
    sb_log "flush: no LLM upgrade (offline/unavailable); digest note stands for $SESSION_ID"
    return 0
  fi
  up_updated_at="$(sb_utc_now)"
  up_last_modified_ms="$(sb_epoch_ms_now)"
  up_files_meta="$(sb_note_files_metadata "$NOTE_FILE_PATH" "$up_last_modified_ms" "$AUTHOR" "$CREATED_AT" "$up_updated_at" "session-note" "session_id" "$SESSION_ID")"
  if [ -z "$up_files_meta" ]; then
    sb_log "flush: could not build LLM upgrade metadata for $SESSION_ID; digest note stands"
    return 0
  fi
  # Persist the summary so every later flush (incl. SessionEnd) pushes IT, not a
  # fresh digest — this is what keeps the curated note from being overwritten.
  sb_ensure_buffer_dir && printf '%s' "$upbody" > "$(sb_summary_file "$SESSION_ID")" 2>/dev/null
  NOTE_FILE2="$(mktemp 2>/dev/null)" || return 0
  sb_render_note "$NOTE_FILE2" "$upbody"
  uphttp="$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}' \
    -X PUT "$(sb_record_update_url "$rid")" \
    -H "Authorization: Bearer ${TOKEN}" \
    -F "file=@${NOTE_FILE2};type=text/markdown;filename=${NOTE_FILE_PATH}" \
    -F "recordName=${RECORD_NAME}" \
    -F "files_metadata=${up_files_meta}" \
    2>/dev/null)" || uphttp=""
  if [ "$uphttp" = "400" ] || [ "$uphttp" = "422" ]; then
    sb_log "flush: LLM upgrade rejected files_metadata (http=$uphttp) for $SESSION_ID; retrying without metadata"
    uphttp="$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}' \
      -X PUT "$(sb_record_update_url "$rid")" \
      -H "Authorization: Bearer ${TOKEN}" \
      -F "file=@${NOTE_FILE2};type=text/markdown;filename=${NOTE_FILE_PATH}" \
      -F "recordName=${RECORD_NAME}" \
      2>/dev/null)" || uphttp=""
  fi
  if [ "$uphttp" = "200" ] || [ "$uphttp" = "201" ]; then
    sb_log "flush: LLM summary upgrade pushed (http=$uphttp) for $SESSION_ID"
  else
    sb_log "flush: LLM upgrade PUT failed (http=${uphttp:-none}) for $SESSION_ID; digest stands"
  fi
  return 0
}

# Emit ONE structured per-session usage row to Cortex (analytics: token totals,
# redacted inputs, summary, author). Best-effort and fail-OPEN: any error — incl.
# a 404 against a Cortex that predates the /usage route — is logged and ignored,
# so it can NEVER block or fail the note flush. Content is built only from the
# redaction-verified buffer ($BODY, UserPrompt inputs) plus numeric token totals,
# so it inherits the same fail-closed guarantee as the note. Server upserts by
# session id (one row per session, updated each flush).
sb_emit_usage() {  # $1 = note record id (may be empty)
  local rid="$1" tokens_json inputs_json payload http
  [ -n "$SB_CORTEX_URL" ] || return 0
  tokens_json="$(sb_token_usage_json "$TRANSCRIPT_PATH")"; [ -n "$tokens_json" ] || tokens_json='{}'
  inputs_json="$(jq -rs '[ .[] | select(.tool=="UserPrompt") | .input ]' "$BUFFER" 2>/dev/null)"
  [ -n "$inputs_json" ] || inputs_json='[]'
  payload="$(jq -nc \
    --arg sid "$SESSION_ID" \
    --arg author "$AUTHOR" \
    --arg author_email "$(sb_author_email "$AUTHOR")" \
    --arg username "$(sb_username "$AUTHOR")" \
    --argjson tokens "$tokens_json" \
    --argjson inputs "$inputs_json" \
    --arg summary "$BODY" \
    --arg source "second-brain-capture" \
    --arg plugin_version "$(sb_plugin_version)" \
    --arg note_id "$rid" \
    '{sessionId:$sid, author:$author, authorEmail:$author_email, username:$username,
      tokens:$tokens, inputs:$inputs, summary:$summary, source:$source,
      pluginVersion:$plugin_version, noteRecordId:$note_id}' 2>/dev/null)"
  [ -n "$payload" ] || { sb_log "flush: could not build usage payload for $SESSION_ID"; return 0; }
  http="$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' \
    -X POST "$(sb_usage_url)" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/dev/null)" || http=""
  case "$http" in
    200 | 201) sb_log "flush: usage row upserted for $SESSION_ID" ;;
    *) sb_log "flush: usage upsert skipped (http=${http:-none}) for $SESSION_ID" ;;
  esac
  return 0
}

NOTE_FILE="$(mktemp 2>/dev/null)" || { [ "$SB_HAVE_LOCK" = "1" ] && sb_release_flush_lock "$SESSION_ID"; exit 0; }
RESP_FILE=""
NOTE_FILE2=""
sb_flush_cleanup() {
  rm -f "$NOTE_FILE" "${RESP_FILE:-}" "${NOTE_FILE2:-}"
  [ "${SB_HAVE_LOCK:-0}" = "1" ] && sb_release_flush_lock "$SESSION_ID"
}
trap sb_flush_cleanup EXIT
sb_render_note "$NOTE_FILE" "$BODY"

RECORD_NAME="Session note - ${AUTHOR} - ${DAY} - ${SESSION_ID:0:8}"
# Cortex names the record after the uploaded FILENAME, NOT the recordName field
# (confirmed on staging), so the note's KB title comes from this slug. Keep it
# stable per session (session id only — NOT the date, which would roll mid-session
# and rename the record) and uniform, so the KB shows "session-note-<id8>" instead
# of a raw session UUID. Author + date still ride in the note's in-body H1 header.
NOTE_SLUG="session-note-${SESSION_ID:0:8}"
NOTE_FILE_PATH="${NOTE_SLUG}.md"
CREATED_AT_FILE="$(sb_session_created_at_file "$SESSION_ID")"
CREATED_AT="$(sb_existing_created_at_or_now "$CREATED_AT_FILE")"
UPDATED_AT="$(sb_utc_now)"
LAST_MODIFIED_MS="$(sb_epoch_ms_now)"
FILES_META="$(sb_note_files_metadata "$NOTE_FILE_PATH" "$LAST_MODIFIED_MS" "$AUTHOR" "$CREATED_AT" "$UPDATED_AT" "session-note" "session_id" "$SESSION_ID")"
[ -n "$FILES_META" ] || { sb_log "flush: could not build upload metadata for $SESSION_ID; keeping buffer"; exit 0; }

# Fail-closed: no token, no push.
TOKEN="$(sb_cortex_token)" || { sb_log "flush: no token; keeping buffer for $SESSION_ID"; exit 0; }

RESP_FILE="$(mktemp 2>/dev/null)"
RID_FILE="$(sb_recordid_file "$SESSION_ID")"
RID="$(cat "$RID_FILE" 2>/dev/null)"
HTTP=""
MODE="create"

# UPSERT. The KB upload route ALWAYS creates a new record (Cortex assigns its
# own record id; the client can't supply one), so we create ONCE per session and
# remember that id. Every later flush PUTs an in-place update to /record/:id —
# same record, new file version. This is what keeps it to ONE note per session;
# the previous "POST with a stable file_path versions in place" assumption was
# wrong and is what produced duplicate notes.
if [ -n "$RID" ]; then
  MODE="update"
  HTTP="$(curl -sS --max-time 30 -o "$RESP_FILE" -w '%{http_code}' \
    -X PUT "$(sb_record_update_url "$RID")" \
    -H "Authorization: Bearer ${TOKEN}" \
    -F "file=@${NOTE_FILE};type=text/markdown;filename=${NOTE_FILE_PATH}" \
    -F "recordName=${RECORD_NAME}" \
    -F "files_metadata=${FILES_META}" \
    2>/dev/null)" || HTTP=""
  if [ "$HTTP" = "400" ] || [ "$HTTP" = "422" ]; then
    sb_log "flush: update rejected files_metadata (http=$HTTP) for $SESSION_ID; retrying without metadata"
    HTTP="$(curl -sS --max-time 30 -o "$RESP_FILE" -w '%{http_code}' \
      -X PUT "$(sb_record_update_url "$RID")" \
      -H "Authorization: Bearer ${TOKEN}" \
      -F "file=@${NOTE_FILE};type=text/markdown;filename=${NOTE_FILE_PATH}" \
      -F "recordName=${RECORD_NAME}" \
      2>/dev/null)" || HTTP=""
  fi
  # If the record was deleted upstream, drop the stale id and recreate below.
  if [ "$HTTP" = "404" ]; then
    sb_log "flush: record $RID gone (404) for $SESSION_ID; recreating"
    rm -f "$RID_FILE"; RID=""; MODE="create"
  fi
fi

if [ -z "$RID" ]; then
  # First flush of the session — CREATE the record. file_path/isVersioned drive
  # storage-level blob versioning; recordName is for display.
  HTTP="$(curl -sS --max-time 30 -o "$RESP_FILE" -w '%{http_code}' \
    -X POST "$(sb_upload_url)" \
    -H "Authorization: Bearer ${TOKEN}" \
    -F "files=@${NOTE_FILE};type=text/markdown;filename=${NOTE_FILE_PATH}" \
    -F "recordName=${RECORD_NAME}" \
    -F "recordType=FILE" \
    -F "origin=UPLOAD" \
    -F "isVersioned=true" \
    -F "files_metadata=${FILES_META}" \
    2>/dev/null)" || HTTP=""
  if [ "$HTTP" = "400" ] || [ "$HTTP" = "422" ]; then
    sb_log "flush: create rejected files_metadata (http=$HTTP) for $SESSION_ID; retrying without metadata"
    HTTP="$(curl -sS --max-time 30 -o "$RESP_FILE" -w '%{http_code}' \
      -X POST "$(sb_upload_url)" \
      -H "Authorization: Bearer ${TOKEN}" \
      -F "files=@${NOTE_FILE};type=text/markdown;filename=${NOTE_FILE_PATH}" \
      -F "recordName=${RECORD_NAME}" \
      -F "recordType=FILE" \
      -F "origin=UPLOAD" \
      -F "isVersioned=true" \
      2>/dev/null)" || HTTP=""
  fi
  if [ "$HTTP" = "200" ] || [ "$HTTP" = "201" ]; then
    # Persist the new record id so the NEXT flush updates it in place instead of
    # creating a duplicate. Without this id we'd be back to one-record-per-flush.
    NEW_RID="$(jq -r '.records[0]._key // .records[0].id // empty' "$RESP_FILE" 2>/dev/null)"
    if [ -n "$NEW_RID" ]; then
      sb_ensure_buffer_dir && printf '%s' "$NEW_RID" > "$RID_FILE" 2>/dev/null
    else
      sb_log "flush: created record but no id in response for $SESSION_ID (next flush may duplicate)"
    fi
  fi
fi

if [ "$HTTP" = "200" ] || [ "$HTTP" = "201" ]; then
  sb_log "flush: pushed session $SESSION_ID (http=$HTTP event=${HOOK_EVENT:-?} final=$FINAL mode=$MODE)"
  sb_persist_created_at "$CREATED_AT_FILE" "$CREATED_AT"

  # Layer the curated LLM summary ON TOP of the digest that just landed — but
  # only on the LIVE session (a Stop flush), NEVER at SessionEnd. SessionEnd is
  # teardown: the parent session is exiting and kills the nested `claude -p`
  # before it can PUT, so the upgrade silently never lands there (the original
  # "logs but no summary" bug — the digest survived, the summary didn't). Gated
  # to at most once per refresh window so it can't reintroduce the per-turn
  # timeout disaster, and always AFTER the digest push so it's off the critical
  # path. The digest above has already landed regardless of what happens here.
  EFF_RID="${RID:-${NEW_RID:-}}"

  # Structured per-session usage row (analytics). Best-effort; never blocks flush.
  sb_emit_usage "$EFF_RID"

  if [ "$FINAL" != "1" ] && [ -n "$EFF_RID" ] && sb_should_upgrade_now "$SESSION_ID"; then
    sb_try_llm_upgrade "$EFF_RID"
  fi

  # Stamp the flush time so the next Stop debounces and only re-pushes when there
  # is something new. We deliberately DO NOT wipe this session's state (buffer,
  # record id, stored summary, markers) on a FINAL (SessionEnd) flush any more:
  # Claude Code reuses the same session_id when a session is resumed (`claude
  # --resume`/`-c`, or reopening a conversation in the VS Code extension — where
  # SessionEnd also fires far less predictably). Wiping the record id here is what
  # let a resumed session find no id and CREATE a second record — the duplicate-
  # note bug (two records sharing one session-note-<id8> name). Keeping the id
  # means a resume PUT-updates the SAME record; keeping the buffer keeps that
  # note's digest CUMULATIVE across the resume instead of shrinking to only the
  # post-resume events. State for sessions never resumed is reclaimed by the
  # age-based sb_gc_stale_state sweep at the top of this hook.
  sb_ensure_buffer_dir && date +%s > "$(sb_flush_marker "$SESSION_ID")" 2>/dev/null
else
  sb_log "flush: push failed (http=$HTTP mode=$MODE) for $SESSION_ID; keeping buffer"
fi

exit 0

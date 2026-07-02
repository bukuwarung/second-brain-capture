#!/usr/bin/env bash
# save-to-cortex.sh — user-invoked uploader behind the /second-brain-capture:save
# command. Takes a curated markdown file, redacts it (fail-closed), dedups by
# content hash, and creates-or-updates ONE record per slug in a Cortex KB.
#
# Contract (differs from the hook scripts): this script is invoked BY Claude on
# an explicit user request, so it REPORTS failures — non-zero exit + a reason on
# stderr — instead of silently exiting 0. Success prints one JSON line on stdout:
#   {"status":"created|updated|duplicate","recordId":"...","slug":"...","kbId":"..."}
#
# Usage:
#   save-to-cortex.sh --file <note.md> --slug <kebab-slug> [--title <display>] [--kb <kbId>] [--dry-run]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/config.sh"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/cortex-auth.sh"

# Manual saves can be much larger than per-event hook payloads, so widen the
# request timeout locally (config.sh defaults it to 5s for per-turn hooks).
SB_REQUEST_TIMEOUT="${SECOND_BRAIN_SAVE_TIMEOUT_SECONDS:-30}"

sb_save_die() { printf 'save-to-cortex: %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || sb_save_die "jq is required (run /second-brain-capture:setup)"
command -v curl >/dev/null 2>&1 || sb_save_die "curl is required (run /second-brain-capture:setup)"

# --------------------------------------------------------------------------
# Args
# --------------------------------------------------------------------------
SAVE_FILE="" SAVE_SLUG="" SAVE_TITLE="" SAVE_KB="" DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --file)    SAVE_FILE="$2"; shift 2 ;;
    --slug)    SAVE_SLUG="$2"; shift 2 ;;
    --title)   SAVE_TITLE="$2"; shift 2 ;;
    --kb)      SAVE_KB="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) sb_save_die "unknown argument: $1" ;;
  esac
done

[ -n "$SAVE_FILE" ] || sb_save_die "--file is required"
[ -s "$SAVE_FILE" ] || sb_save_die "content file missing or empty: $SAVE_FILE"
[ -n "$SAVE_SLUG" ] || sb_save_die "--slug is required"
case "$SAVE_SLUG" in
  *[!a-z0-9-]* | -* | *-) sb_save_die "slug must be kebab-case ([a-z0-9-], no leading/trailing dash): $SAVE_SLUG" ;;
esac
SB_KB_ID="${SAVE_KB:-$SB_KB_ID}"
[ -n "$SB_CORTEX_URL" ] && [ -n "$SB_KB_ID" ] || sb_save_die "Cortex URL / KB id not configured"
[ -n "$SAVE_TITLE" ] || SAVE_TITLE="$(printf '%s' "$SAVE_SLUG" | tr '-' ' ')"

# Size guard. The KB upload route takes far more, but the redaction proxy and
# the "curated note, not a dump" contract both want a bound.
SB_SAVE_MAX_BYTES="${SECOND_BRAIN_SAVE_MAX_BYTES:-262144}"
SAVE_BYTES="$(wc -c < "$SAVE_FILE" | tr -d ' ')"
[ "$SAVE_BYTES" -le "$SB_SAVE_MAX_BYTES" ] || \
  sb_save_die "content is ${SAVE_BYTES} bytes (max ${SB_SAVE_MAX_BYTES}); split it into smaller notes"

# --------------------------------------------------------------------------
# Redaction — same fail-closed contract as capture: nothing unverified is ever
# uploaded. The content is redacted in line-boundary chunks (the proxy is sized
# for per-event payloads, not whole documents); PII spanning a chunk boundary
# is the accepted trade-off since the patterns are line-local in practice.
# SECOND_BRAIN_SAVE_ASSUME_CLEAN=1 is an operator/CI escape hatch only.
# --------------------------------------------------------------------------
SB_SAVE_CHUNK_CHARS="${SECOND_BRAIN_SAVE_REDACT_CHUNK_CHARS:-16000}"

sb_save_redact_file() {  # $1=infile $2=outfile ; returns non-zero on any chunk failure
  local ct chunk="" line out
  ct="$(sb_connector_type save)"
  : > "$2" || return 1
  # NUL-safe enough for markdown; read line-by-line, accumulate into chunks.
  while IFS= read -r line || [ -n "$line" ]; do
    if [ $(( ${#chunk} + ${#line} + 1 )) -gt "$SB_SAVE_CHUNK_CHARS" ] && [ -n "$chunk" ]; then
      out="$(sb_redact_message "$ct" "$chunk")" || return 1
      printf '%s\n' "$out" >> "$2"
      chunk=""
    fi
    chunk="${chunk}${chunk:+
}${line}"
  done < "$1"
  if [ -n "$chunk" ]; then
    out="$(sb_redact_message "$ct" "$chunk")" || return 1
    printf '%s\n' "$out" >> "$2"
  fi
  return 0
}

CLEAN_FILE="$(mktemp 2>/dev/null)" || sb_save_die "mktemp failed"
RESP_FILE=""
NOTE_FILE=""
sb_save_cleanup() { rm -f "$CLEAN_FILE" "${RESP_FILE:-}" "${NOTE_FILE:-}"; }
trap sb_save_cleanup EXIT

if [ "${SECOND_BRAIN_SAVE_ASSUME_CLEAN:-}" = "1" ]; then
  cp "$SAVE_FILE" "$CLEAN_FILE" || sb_save_die "copy failed"
else
  # Probe once that the agent is actually redacting (warn/observe mode passes
  # PII through unmodified and is indistinguishable per-response — see config.sh).
  sb_redact_mode_ok "manual-save" || \
    sb_save_die "redaction could not be verified (no creds / agent unreachable / not in redact mode); nothing was uploaded"
  sb_save_redact_file "$SAVE_FILE" "$CLEAN_FILE" || \
    sb_save_die "redaction failed mid-document; nothing was uploaded"
fi

# Defense in depth: scrub secret tokens PII redaction doesn't cover.
SCRUBBED="$(sb_scrub_secrets "$(cat "$CLEAN_FILE")")"
printf '%s\n' "$SCRUBBED" > "$CLEAN_FILE"

# --------------------------------------------------------------------------
# Dedup ledger. Hash the REDACTED CONTENT (not the rendered note — its header
# carries the save date, which would defeat exact-duplicate detection). An
# identical body already uploaded under ANY slug is a no-op; a known slug with
# new content updates that record in place. This is the guard that keeps
# "everyone dumps freely" from re-creating the re-capture flood.
# --------------------------------------------------------------------------
SB_SAVES_DIR="${SB_STATE_DIR}/saves"
SB_SAVE_LEDGER="${SB_SAVES_DIR}/ledger.tsv"   # <sha256>\t<recordId>\t<slug>\t<utc-ts>
mkdir -p "$SB_SAVES_DIR" 2>/dev/null || sb_save_die "cannot create state dir $SB_SAVES_DIR"

sb_save_hash() {
  shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1 || sha256sum "$1" 2>/dev/null | cut -d' ' -f1
}
CONTENT_HASH="$(sb_save_hash "$CLEAN_FILE")"
[ -n "$CONTENT_HASH" ] || sb_save_die "could not hash content"

if [ -f "$SB_SAVE_LEDGER" ]; then
  DUP_LINE="$(grep -m1 "^${CONTENT_HASH}	" "$SB_SAVE_LEDGER" 2>/dev/null)"
  if [ -n "$DUP_LINE" ]; then
    DUP_RID="$(printf '%s' "$DUP_LINE" | cut -f2)"
    DUP_SLUG="$(printf '%s' "$DUP_LINE" | cut -f3)"
    sb_log "save: duplicate content (record $DUP_RID slug $DUP_SLUG); skipping upload"
    jq -nc --arg rid "$DUP_RID" --arg slug "$DUP_SLUG" --arg kb "$SB_KB_ID" \
      '{status:"duplicate", recordId:$rid, slug:$slug, kbId:$kb}'
    exit 0
  fi
fi

# --------------------------------------------------------------------------
# Render the note: provenance header + redacted body. The KB record title comes
# from the uploaded FILENAME (slug), so the display title rides in the H1.
# --------------------------------------------------------------------------
AUTHOR="$(sb_author)"
DAY="$(date -u +%F)"
NOTE_FILE="$(mktemp 2>/dev/null)" || sb_save_die "mktemp failed"
{
  printf '# %s\n\n' "$SAVE_TITLE"
  printf '_saved by %s on %s via second-brain-capture /save_\n\n' "$AUTHOR" "$DAY"
  cat "$CLEAN_FILE"
} > "$NOTE_FILE"

RECORD_NAME="${SAVE_TITLE} - ${AUTHOR} - ${DAY}"
RID_FILE="${SB_SAVES_DIR}/${SAVE_SLUG}.recordid"
RID="$(cat "$RID_FILE" 2>/dev/null)"

if [ "$DRY_RUN" = "1" ]; then
  jq -nc --arg slug "$SAVE_SLUG" --arg kb "$SB_KB_ID" --arg rid "${RID:-}" \
    --argjson bytes "$(wc -c < "$NOTE_FILE" | tr -d ' ')" \
    '{status:"dry-run", wouldBe:(if $rid=="" then "created" else "updated" end), slug:$slug, kbId:$kb, noteBytes:$bytes}'
  exit 0
fi

# Fail-closed: no token, no push.
TOKEN="$(sb_cortex_token)" || sb_save_die "could not mint a Cortex token (run /second-brain-capture:setup)"

RESP_FILE="$(mktemp 2>/dev/null)" || sb_save_die "mktemp failed"
HTTP="" STATUS=""

# Same upsert shape as session-flush.sh: the upload route always CREATES, so a
# known slug PUT-updates its remembered record; a 404 (deleted upstream) falls
# through to recreate.
if [ -n "$RID" ]; then
  HTTP="$(curl -sS --max-time 60 -o "$RESP_FILE" -w '%{http_code}' \
    -X PUT "$(sb_record_update_url "$RID")" \
    -H "Authorization: Bearer ${TOKEN}" \
    -F "file=@${NOTE_FILE};type=text/markdown;filename=${SAVE_SLUG}.md" \
    -F "recordName=${RECORD_NAME}" \
    2>/dev/null)" || HTTP=""
  if [ "$HTTP" = "404" ]; then
    sb_log "save: record $RID gone (404) for slug $SAVE_SLUG; recreating"
    rm -f "$RID_FILE"; RID=""
  elif [ "$HTTP" = "200" ] || [ "$HTTP" = "201" ]; then
    STATUS="updated"
  fi
fi

if [ -z "$RID" ]; then
  FILES_META="$(jq -nc --arg fp "${SAVE_SLUG}.md" --argjson lm "$(( $(date +%s) * 1000 ))" \
    '[{file_path:$fp, last_modified:$lm}]')"
  HTTP="$(curl -sS --max-time 60 -o "$RESP_FILE" -w '%{http_code}' \
    -X POST "$(sb_upload_url)" \
    -H "Authorization: Bearer ${TOKEN}" \
    -F "files=@${NOTE_FILE};type=text/markdown;filename=${SAVE_SLUG}.md" \
    -F "recordName=${RECORD_NAME}" \
    -F "recordType=FILE" \
    -F "origin=UPLOAD" \
    -F "isVersioned=true" \
    -F "files_metadata=${FILES_META}" \
    2>/dev/null)" || HTTP=""
  if [ "$HTTP" = "200" ] || [ "$HTTP" = "201" ]; then
    RID="$(jq -r '.records[0]._key // .records[0].id // empty' "$RESP_FILE" 2>/dev/null)"
    [ -n "$RID" ] && printf '%s' "$RID" > "$RID_FILE" 2>/dev/null
    STATUS="created"
  fi
fi

if [ -z "$STATUS" ]; then
  ERR="$(jq -r '.message // .error // empty' "$RESP_FILE" 2>/dev/null | head -c 300)"
  sb_save_die "upload failed (http=${HTTP:-none}${ERR:+: $ERR})"
fi

printf '%s\t%s\t%s\t%s\n' "$CONTENT_HASH" "${RID:-unknown}" "$SAVE_SLUG" "$(date -u +%FT%TZ)" >> "$SB_SAVE_LEDGER" 2>/dev/null
sb_log "save: $STATUS record ${RID:-?} slug=$SAVE_SLUG kb=$SB_KB_ID bytes=$SAVE_BYTES"
jq -nc --arg st "$STATUS" --arg rid "${RID:-}" --arg slug "$SAVE_SLUG" --arg kb "$SB_KB_ID" \
  '{status:$st, recordId:$rid, slug:$slug, kbId:$kb}'
exit 0

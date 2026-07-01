#!/usr/bin/env bash
# second-brain-capture — shared configuration and helpers.
# Sourced by capture-event.sh and session-flush.sh. No `set -e`: this plugin is
# best-effort and must never block or break a user's Claude Code session.

# ---------------------------------------------------------------------------
# Plugin userConfig bridge. When installed via `claude plugin install`, the
# user's answers are exposed to hooks as CLAUDE_PLUGIN_OPTION_<key>. Fold them
# into the SECOND_BRAIN_* vars the rest of the plugin already uses, so an
# installed plugin needs ZERO settings.json env. Explicit SECOND_BRAIN_* wins
# (power users, tests, CI), then the plugin option, then built-in defaults.
# ---------------------------------------------------------------------------
# Resolution order per value: explicit SECOND_BRAIN_* env (power users / CI) wins,
# then the plugin userConfig option (set via /plugin configure), then the baked
# pilot default below. The pilot defaults are deliberately on so a teammate who
# just installs the plugin + runs /second-brain-capture:setup gets a working
# loop without ever touching settings.json or /plugin configure.
: "${SECOND_BRAIN_ENABLED:=${CLAUDE_PLUGIN_OPTION_enabled:-1}}"
: "${SECOND_BRAIN_AXON_ENDPOINT:=${CLAUDE_PLUGIN_OPTION_axon_endpoint:-}}"
: "${SECOND_BRAIN_CORTEX_URL:=${CLAUDE_PLUGIN_OPTION_cortex_url:-https://cortex-stg.bukuwarung.com}}"
: "${SECOND_BRAIN_KB_ID:=${CLAUDE_PLUGIN_OPTION_kb_id:-a73aa2eb-bfa4-4204-93df-e06cb0bbf8a9}}"
# Default off: when claude or ANTHROPIC_API_KEY is available, summarize.sh
# uses an LLM. Set SECOND_BRAIN_OFFLINE=1 to force the deterministic digest
# (useful for CI, tests, network-isolated environments, or any operator who
# wants to skip the LLM step entirely).
: "${SECOND_BRAIN_OFFLINE:=${CLAUDE_PLUGIN_OPTION_offline:-0}}"
# OAuth credentials stay blank by default; the auth file (or env, or option) supplies them.
: "${SECOND_BRAIN_OAUTH_CLIENT_ID:=${CLAUDE_PLUGIN_OPTION_oauth_client_id:-}}"
: "${SECOND_BRAIN_OAUTH_CLIENT_SECRET:=${CLAUDE_PLUGIN_OPTION_oauth_client_secret:-}}"

# Secret fallback: a small auth file kept OUT of settings.json and git (mirrors
# the AxonFlow plugin's self-hosted-auth.json pattern). JSON: {client_id, client_secret}.
# Used when the secret wasn't provided via env or the install prompt.
if [ -z "${SECOND_BRAIN_OAUTH_CLIENT_SECRET:-}" ] && command -v jq >/dev/null 2>&1; then
  _sb_authf="${SECOND_BRAIN_AUTH_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/second-brain-capture/auth.json}"
  if [ -f "$_sb_authf" ]; then
    SECOND_BRAIN_OAUTH_CLIENT_SECRET="$(jq -r '.client_secret // empty' "$_sb_authf" 2>/dev/null)"
    : "${SECOND_BRAIN_OAUTH_CLIENT_ID:=$(jq -r '.client_id // empty' "$_sb_authf" 2>/dev/null)}"
  fi
fi

# ---------------------------------------------------------------------------
# Enable gate (opt-in). The plugin no-ops unless this is explicitly turned on.
# ---------------------------------------------------------------------------
sb_enabled() {
  case "${SECOND_BRAIN_ENABLED:-}" in
    1 | true | TRUE | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Logging. Off by default. SECOND_BRAIN_DEBUG=1 (or SECOND_BRAIN_LOG=1) turns it
# on: each line is appended to a persistent, tailable log FILE and also echoed to
# stderr. The file is what makes the plugin monitorable — Claude Code discards
# hook-subprocess stderr, so without a file there is nothing to watch turn to
# turn. Fail-open: any logging failure is swallowed and never breaks a hook.
# ---------------------------------------------------------------------------
# All plugin state lives under one tree; the log sits beside buffers/.
SB_STATE_DIR="${SECOND_BRAIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/second-brain-capture}"
SB_LOG_FILE="${SECOND_BRAIN_LOG_FILE:-$SB_STATE_DIR/second-brain.log}"
SB_LOG_MAX_BYTES="${SECOND_BRAIN_LOG_MAX_BYTES:-5242880}"   # ~5 MB, then roll once

sb_log_on() {
  [ "${SECOND_BRAIN_DEBUG:-}" = "1" ] || [ "${SECOND_BRAIN_LOG:-}" = "1" ]
}

# Roll the log once when it crosses the size cap, so per-turn capture can't grow
# it without bound across a pilot. Cheap stat; best-effort (BSD + GNU stat).
sb_log_rotate() {
  local sz
  sz="$(stat -f %z "$SB_LOG_FILE" 2>/dev/null || stat -c %s "$SB_LOG_FILE" 2>/dev/null || echo 0)"
  [ "${sz:-0}" -gt "${SB_LOG_MAX_BYTES:-5242880}" ] 2>/dev/null && mv -f "$SB_LOG_FILE" "$SB_LOG_FILE.1" 2>/dev/null
  return 0
}

# Timestamped, session-tagged line -> stderr + the log file. SESSION_ID is a
# hook-script global (functions share the script's scope), so lines group per
# session even though each hook fires in its own subprocess (disambiguated by pid).
sb_log() {
  sb_log_on || return 0
  local ts line
  ts="$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || printf '?')"
  line="$(printf 'second-brain %s [%s pid:%s] %s' "$ts" "${SESSION_ID:-?}" "$$" "$*")"
  printf '%s\n' "$line" >&2
  if [ -n "${SB_LOG_FILE:-}" ]; then
    mkdir -p "${SB_LOG_FILE%/*}" 2>/dev/null && {
      [ -f "$SB_LOG_FILE" ] && sb_log_rotate
      printf '%s\n' "$line" >> "$SB_LOG_FILE" 2>/dev/null
    }
  fi
  return 0
}

# ---------------------------------------------------------------------------
# AxonFlow agent — the redaction backbone (FALLBACK path). Primary redaction now
# goes through Cortex's /redact proxy (see sb_redact_message below), so off-VPN
# clients work and the agent stays in-VPC. This direct path is the fallback for
# local/CI runs against a mock agent. Mirrors the AxonFlow plugin's endpoint
# resolution so both agree on which agent they talk to.
# ---------------------------------------------------------------------------
# Our endpoint var is DISTINCT from the AxonFlow plugin's AXONFLOW_ENDPOINT on
# purpose. That plugin pins `AXONFLOW_ENDPOINT=http://localhost:8080` via Claude
# Code settings `env`, which OVERRIDES the inherited shell value for hook
# subprocesses — so reusing it silently points capture at a dead localhost and
# drops everything. SECOND_BRAIN_AXON_ENDPOINT wins; AXONFLOW_ENDPOINT is only a
# fallback for standalone use without the AxonFlow plugin installed.
SB_AXON_ENDPOINT="${SECOND_BRAIN_AXON_ENDPOINT:-${AXONFLOW_ENDPOINT:-http://localhost:8080}}"
SB_REQUEST_TIMEOUT="${SECOND_BRAIN_TIMEOUT_SECONDS:-${AXONFLOW_TIMEOUT_SECONDS:-5}}"

# Populate the global array SB_AXON_HEADERS with curl -H args, reusing the
# AxonFlow plugin's credential env (AXONFLOW_AUTH = base64(org_id:license_key),
# optional X-License-Token). The companion does not hold its own credentials.
sb_build_axonflow_headers() {
  SB_AXON_HEADERS=(-H "Content-Type: application/json" -H "Accept: application/json")
  local auth="${AXONFLOW_AUTH:-}"
  # Fall back to the AxonFlow plugin's saved self-hosted/Enterprise credential
  # when AXONFLOW_AUTH is not in the environment (matches the AxonFlow plugin).
  if [ -z "$auth" ]; then
    local shf="${AXONFLOW_CONFIG_DIR:-$HOME/.config/axonflow}/self-hosted-auth.json"
    if [ -f "$shf" ] && command -v jq >/dev/null 2>&1; then
      auth="$(jq -r '.auth // empty' "$shf" 2>/dev/null)"
    fi
  fi
  [ -n "$auth" ] && SB_AXON_HEADERS+=(-H "Authorization: Basic ${auth}")
  SB_AXON_HEADERS+=(-H "X-Axonflow-Client: second-brain-capture")
  if [ -n "${AXONFLOW_LICENSE_TOKEN:-}" ]; then
    SB_AXON_HEADERS+=(-H "X-License-Token: ${AXONFLOW_LICENSE_TOKEN}")
  fi
}

# The connector_type label scopes the AxonFlow capture redaction profile (U7).
sb_connector_type() {
  printf 'second_brain.%s' "${1:-unknown}"
}

# ---------------------------------------------------------------------------
# Redact-mode verification (fail-closed safety).
#
# check_output returns no redacted_message both for clean content AND for
# warn/observe mode (where PII is passed through unmodified). We cannot tell
# those apart from a single response, so before trusting capture we PROBE the
# agent once per session with a synthetic PII canary. If the canary does not
# come back redacted, the agent is not redacting and capture must fail closed.
# Override with SECOND_BRAIN_ASSUME_REDACT=1 only if you have verified the
# capture surface is in redact mode out of band.
# ---------------------------------------------------------------------------
# Email canary: pii-global, always redacted in redact mode (no jurisdiction
# check-digit validation like KTP/NIK, which would false-negative the probe).
SB_REDACT_CANARY="${SECOND_BRAIN_REDACT_CANARY:-redact-probe@axonflow-canary.invalid}"

sb_redact_marker() { printf '%s/%s.redact' "${SB_BUFFER_DIR}" "${1:-unknown}"; }

# ---------------------------------------------------------------------------
# Redaction dispatch. The AxonFlow agent does the redaction, but it only listens
# inside the VPC. To let off-VPN clients capture, we PREFER Cortex's /redact
# proxy: the public, OAuth-gated Cortex forwards the text to the in-VPC agent and
# returns only the redacted result, so the agent is never exposed. We fall back
# to calling the agent directly when Cortex creds are absent (local/CI runs
# against a mock agent).
#
# NOTE: in the proxy path the raw (pre-redaction) event text travels to Cortex
# over TLS to be redacted — the trade-off for not requiring the VPN. Cortex
# forwards it to the agent and does not persist it.
#
# Both helpers share one contract: echo redacted-or-original text on stdout and
# return 0 to KEEP, non-zero to DROP (no token / non-200 / unparseable / policy
# block). sb_redact_message picks the path.
# ---------------------------------------------------------------------------
# True when we can authenticate to Cortex, so the proxy path is usable.
sb_have_cortex_creds() {
  [ -n "${SB_CORTEX_URL:-}" ] && [ -n "${SB_OAUTH_CLIENT_ID:-}" ] && [ -n "${SB_OAUTH_CLIENT_SECRET:-}" ]
}

# Redact via Cortex's /redact proxy. Needs sb_cortex_token (cortex-auth.sh).
sb_redact_via_cortex() {
  local ct="$1" msg="$2" token body http allowed red
  command -v sb_cortex_token >/dev/null 2>&1 || return 1
  token="$(sb_cortex_token)" || { sb_log "redact(cortex): no token"; return 1; }
  body="$(mktemp 2>/dev/null)" || return 1
  http="$(curl -sS --max-time "$SB_REQUEST_TIMEOUT" -o "$body" -w '%{http_code}' \
    -X POST "${SB_CORTEX_URL}/api/v1/knowledgeBase/redact" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" -H "Accept: application/json" \
    -d "$(jq -nc --arg ct "$ct" --arg msg "$msg" '{connectorType:$ct, message:$msg}')" \
    2>/dev/null)" || http=""
  if [ "$http" != "200" ]; then rm -f "$body"; sb_log "redact(cortex): http=$http"; return 1; fi
  allowed="$(jq -r 'if .allowed == false then "false" else "true" end' "$body" 2>/dev/null)"
  red="$(jq -r '.redactedMessage // empty' "$body" 2>/dev/null)"
  rm -f "$body"
  [ "$allowed" = "false" ] && { sb_log "redact(cortex): policy-blocked"; return 1; }
  if [ -n "$red" ]; then printf '%s' "$red"; else printf '%s' "$msg"; fi
}

# Redact by calling the AxonFlow agent directly (fallback for local/CI/mock).
sb_redact_via_axonflow() {
  local ct="$1" msg="$2" body http inner allowed red
  sb_build_axonflow_headers
  body="$(mktemp 2>/dev/null)" || return 1
  http="$(curl -sS --max-time "$SB_REQUEST_TIMEOUT" -o "$body" -w '%{http_code}' \
    -X POST "${SB_AXON_ENDPOINT}/api/v1/mcp-server" "${SB_AXON_HEADERS[@]}" \
    -d "$(jq -n --arg ct "$ct" --arg msg "$msg" \
      '{jsonrpc:"2.0",id:"sb-redact",method:"tools/call",params:{name:"check_output",arguments:{connector_type:$ct,message:$msg}}}')" \
    2>/dev/null)" || http=""
  if [ "$http" != "200" ]; then rm -f "$body"; sb_log "redact(axon): http=$http"; return 1; fi
  inner="$(jq -r '.result.content[0].text // empty' "$body" 2>/dev/null)"
  rm -f "$body"
  [ -z "$inner" ] && { sb_log "redact(axon): no scan result"; return 1; }
  allowed="$(printf '%s' "$inner" | jq -r 'if .allowed == false then "false" else "true" end' 2>/dev/null)"
  red="$(printf '%s' "$inner" | jq -r '.redacted_message // empty' 2>/dev/null)"
  [ "$allowed" = "false" ] && { sb_log "redact(axon): policy-blocked"; return 1; }
  if [ -n "$red" ]; then printf '%s' "$red"; else printf '%s' "$msg"; fi
}

# Unified entry point: Cortex proxy when creds exist, else direct AxonFlow.
sb_redact_message() {
  if sb_have_cortex_creds; then
    sb_redact_via_cortex "$1" "$2"
  else
    sb_redact_via_axonflow "$1" "$2"
  fi
}

# Return 0 if redaction is confirmed working for this session, else 1. Probes
# once per session with an email canary: if the canary comes back masked,
# redaction is live; if it survives (clean passthrough / warn mode / failure),
# fail closed. Verdict cached per session.
sb_redact_mode_ok() {
  [ "${SECOND_BRAIN_ASSUME_REDACT:-}" = "1" ] && return 0
  local sid="${1:-unknown}" marker out rc verdict="bad"
  marker="$(sb_redact_marker "$sid")"
  if [ -f "$marker" ]; then
    [ "$(cat "$marker" 2>/dev/null)" = "ok" ] && return 0 || return 1
  fi
  out="$(sb_redact_message "$(sb_connector_type probe)" "redaction self-test ${SB_REDACT_CANARY}")"
  rc=$?
  # Confirmed only if the call succeeded AND the canary came back masked.
  if [ "$rc" -eq 0 ] && [ -n "$out" ] && ! printf '%s' "$out" | grep -qF "$SB_REDACT_CANARY"; then
    verdict="ok"
  fi
  mkdir -p "$SB_BUFFER_DIR" 2>/dev/null
  printf '%s' "$verdict" > "$marker" 2>/dev/null
  [ "$verdict" = "ok" ] && return 0 || return 1
}

# Trim leading/trailing whitespace (including newlines). Pure-bash, no
# subprocess — used to clean the input/output parts after the redacted event is
# split back apart on its sentinels.
sb_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Plugin-side secret scrub (defense in depth). AxonFlow's check_output redacts
# PII categories (email/phone/card/SSN/NIK...) but NOT the sensitive-data
# (secrets) category, so high-confidence secret tokens are scrubbed here before
# anything is buffered. Echoes the scrubbed text.
sb_scrub_secrets() {
  printf '%s' "$1" | sed -E \
    -e 's/sk_(live|test)_[A-Za-z0-9]{6,}/[REDACTED:secret]/g' \
    -e 's/AKIA[0-9A-Z]{16}/[REDACTED:secret]/g' \
    -e 's/gh[pousr]_[A-Za-z0-9]{20,}/[REDACTED:secret]/g' \
    -e 's/xox[baprs]-[A-Za-z0-9-]{10,}/[REDACTED:secret]/g' \
    -e 's/eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+/[REDACTED:jwt]/g'
}

# ---------------------------------------------------------------------------
# Cortex — the knowledge pipeline. Push target for one note per session.
# ---------------------------------------------------------------------------
SB_CORTEX_URL="${SECOND_BRAIN_CORTEX_URL:-}"
SB_KB_ID="${SECOND_BRAIN_KB_ID:-}"
SB_OAUTH_CLIENT_ID="${SECOND_BRAIN_OAUTH_CLIENT_ID:-}"
SB_OAUTH_CLIENT_SECRET="${SECOND_BRAIN_OAUTH_CLIENT_SECRET:-}"
SB_OAUTH_SCOPE="${SECOND_BRAIN_OAUTH_SCOPE:-kb:read kb:write kb:upload}"
# Token endpoint. Cortex/PipesHub serves it at /api/v1/oauth2/token (confirmed
# via the deployment's /.well-known/openid-configuration). Override if your
# deployment differs; the discovery doc's token_endpoint is authoritative.
SB_TOKEN_URL="${SECOND_BRAIN_OAUTH_TOKEN_URL:-${SB_CORTEX_URL}/api/v1/oauth2/token}"
# Upload route — CREATES a new record. Each POST mints a fresh record (Cortex
# assigns its own externalRecordId from the placeholder documentId; the client
# cannot supply one), so this is used ONCE per session to create the note.
sb_upload_url() {
  printf '%s/api/v1/knowledgeBase/%s/upload' "${SB_CORTEX_URL}" "${SB_KB_ID}"
}
# Update route — updates an existing record IN PLACE (new file version, same
# record id). This is the real upsert key: after the first POST we remember the
# record id and PUT here on every later flush, so one session == one record.
# Needs kb:write (the upload route needs kb:upload). Multipart field is `file`.
sb_record_update_url() {
  printf '%s/api/v1/knowledgeBase/record/%s' "${SB_CORTEX_URL}" "${1}"
}

# ---------------------------------------------------------------------------
# Author attribution. A client-credentials principal is single-identity, so the
# real author rides in the record name + metadata.
# ---------------------------------------------------------------------------
sb_author() {
  if [ -n "${SECOND_BRAIN_AUTHOR:-}" ]; then
    printf '%s' "${SECOND_BRAIN_AUTHOR}"
    return 0
  fi
  local email
  email="$(git config user.email 2>/dev/null)"
  printf '%s' "${email:-${USER:-unknown}}"
}

# ---------------------------------------------------------------------------
# Session buffer. One JSONL file per session; each line is a redaction-verified
# event. The buffer only ever holds clean content (capture drops events whose
# redaction could not be verified — fail-closed for content).
# ---------------------------------------------------------------------------
SB_BUFFER_DIR="${SECOND_BRAIN_BUFFER_DIR:-$SB_STATE_DIR/buffers}"

sb_buffer_file() {
  printf '%s/%s.jsonl' "${SB_BUFFER_DIR}" "${1:-unknown}"
}
sb_dropped_file() {
  printf '%s/%s.dropped' "${SB_BUFFER_DIR}" "${1:-unknown}"
}
# Remembers the Cortex record id created for this session on the first flush, so
# every later flush PUTs an in-place update to the SAME record instead of POSTing
# a new one (which is what caused duplicate notes). KEPT across SessionEnd too:
# Claude Code reuses the session_id when a session is resumed, so this id must
# survive to update the same record instead of creating a duplicate. Reclaimed by
# sb_gc_stale_state (age-based) once a session has been idle past the TTL.
sb_recordid_file() {
  printf '%s/%s.recordid' "${SB_BUFFER_DIR}" "${1:-unknown}"
}

sb_ensure_buffer_dir() {
  mkdir -p "${SB_BUFFER_DIR}" 2>/dev/null || return 1
  return 0
}

# Age-based GC of per-session state. We no longer wipe a session's state on
# SessionEnd (so a resumed session_id keeps updating ONE record instead of
# creating duplicates), so without this, buffers / record-ids / markers would
# accumulate forever. Reclaim any session artifact not modified in the last
# SB_STATE_TTL_DAYS days. Best-effort and cheap (one `find`); a missing dir or a
# missing `find` is a silent no-op. Called from the flush hook (not per-event).
SB_STATE_TTL_DAYS="${SECOND_BRAIN_STATE_TTL_DAYS:-14}"
sb_gc_stale_state() {
  [ -d "$SB_BUFFER_DIR" ] || return 0
  command -v find >/dev/null 2>&1 || return 0
  find "$SB_BUFFER_DIR" -maxdepth 1 -type f -mtime "+${SB_STATE_TTL_DAYS}" -delete 2>/dev/null
  find "$SB_BUFFER_DIR" -maxdepth 1 -type d -name '*.flushlock' -mtime "+${SB_STATE_TTL_DAYS}" -exec rmdir {} + 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------------
# Incremental flush (Stop hook). People rarely END a Claude Code session, so a
# SessionEnd-only push would mean notes never appear. The Stop hook fires at the
# end of every turn; we flush there too, debounced, and upsert the SAME note in
# place (stable <session_id>.md filename → Cortex versions one record, confirmed
# on staging). The final SessionEnd flush clears the buffer; Stop flushes keep
# it so the note keeps growing across the session.
# ---------------------------------------------------------------------------
SB_FLUSH_DEBOUNCE_SECS="${SECOND_BRAIN_FLUSH_DEBOUNCE_SECONDS:-120}"

sb_flush_marker() { printf '%s/%s.flushed' "${SB_BUFFER_DIR}" "${1:-unknown}"; }

# ---------------------------------------------------------------------------
# Per-session flush lock. Stop and SessionEnd can both fire near-simultaneously
# (and globally-registered hooks can double-fire), so two flushes could race
# before the first has recorded its record id — each would POST and create a
# duplicate. An atomic mkdir lock serializes flushes per session: the loser just
# exits (the winner covers the work). Fail-open: a lock left behind by a crashed
# flush goes stale and is reclaimed, so it can never wedge a session forever.
sb_flush_lock_dir() { printf '%s/%s.flushlock' "${SB_BUFFER_DIR}" "${1:-unknown}"; }

# True (0) if $1 exists and is older than $2 seconds. Handles BSD (mac) and GNU stat.
sb_path_older_than() {
  local p="$1" max="${2:-90}" mtime now
  [ -e "$p" ] || return 1
  mtime="$(stat -f %m "$p" 2>/dev/null || stat -c %Y "$p" 2>/dev/null || echo 0)"
  now="$(date +%s 2>/dev/null || echo 0)"
  [ "$(( now - mtime ))" -ge "$max" ]
}

# Acquire the per-session flush lock. Returns 0 if acquired, 1 if another flush
# holds a fresh lock. Reclaims a stale lock (default >90s old) before giving up.
sb_acquire_flush_lock() {
  local lock; lock="$(sb_flush_lock_dir "${1:-unknown}")"
  sb_ensure_buffer_dir
  if mkdir "$lock" 2>/dev/null; then return 0; fi
  if sb_path_older_than "$lock" "${SECOND_BRAIN_FLUSH_LOCK_STALE_SECONDS:-90}"; then
    rmdir "$lock" 2>/dev/null
    mkdir "$lock" 2>/dev/null && return 0
  fi
  return 1
}
sb_release_flush_lock() { rmdir "$(sb_flush_lock_dir "${1:-unknown}")" 2>/dev/null; return 0; }

# Decide whether a flush should run now.
#   $1 = final flag (1 = SessionEnd → always flush), $2 = session id
# For incremental (Stop) flushes: require NEW events since the last flush AND the
# debounce window to have elapsed. Returns 0 to flush, 1 to skip.
sb_should_flush_now() {
  local final="${1:-0}" sid="${2:-unknown}" marker buffer last now
  [ "$final" = "1" ] && return 0
  marker="$(sb_flush_marker "$sid")"
  buffer="$(sb_buffer_file "$sid")"
  [ -f "$marker" ] || return 0                 # never flushed this session → flush now
  [ "$buffer" -nt "$marker" ] || return 1      # no new events since last flush → skip
  last="$(cat "$marker" 2>/dev/null || echo 0)"
  now="$(date +%s 2>/dev/null || echo 0)"
  [ $(( now - last )) -ge "$SB_FLUSH_DEBOUNCE_SECS" ] && return 0 || return 1
}

# ---------------------------------------------------------------------------
# LLM summary-upgrade gate. The curated `claude -p` summary is layered ON TOP of
# the instant digest, and it runs on the LIVE session (a Stop flush) — NEVER at
# SessionEnd. SessionEnd is session teardown: the parent Claude Code process is
# exiting and kills the nested `claude -p` mid-call before it can PUT, so the
# upgrade never lands there (the digest, pushed first, always survives). Running
# the LLM on EVERY turn was the v0.4.x timeout disaster, so the upgrade is gated
# to run at most once per SB_SUMMARY_REFRESH_SECS within a session: the first
# eligible flush upgrades, then it refreshes only after the window elapses — so a
# long session's summary stays current without paying a model call per turn.
# ---------------------------------------------------------------------------
SB_SUMMARY_REFRESH_SECS="${SECOND_BRAIN_SUMMARY_REFRESH_SECONDS:-900}"

sb_summary_marker() { printf '%s/%s.summarized' "${SB_BUFFER_DIR}" "${1:-unknown}"; }
# Holds the last LLM summary body produced this session. Once it exists, flushes
# push IT (not a fresh digest) so a plain Stop or the final SessionEnd can't
# overwrite the curated summary back to a digest. Cleared on SessionEnd.
sb_summary_file() { printf '%s/%s.summary' "${SB_BUFFER_DIR}" "${1:-unknown}"; }

# Decide whether to run the LLM summary upgrade on this flush. Returns 0 to
# upgrade, 1 to skip. Skips when the LLM is disabled (OFFLINE) or we are inside
# the summarizer's own subprocess (recursion guard). Otherwise upgrade if we have
# never upgraded this session, or the refresh window has elapsed since the last
# attempt. The marker is stamped up front when an upgrade is attempted (see
# sb_try_llm_upgrade), so the once-per-window bound holds even if that attempt
# hangs or is killed — a slow summarizer can't degrade into a per-turn cost.
sb_should_upgrade_now() {
  [ "${SECOND_BRAIN_OFFLINE:-}" = "1" ] && return 1
  [ "${SECOND_BRAIN_SUMMARIZING:-}" = "1" ] && return 1
  local sid="${1:-unknown}" marker last now
  marker="$(sb_summary_marker "$sid")"
  [ -f "$marker" ] || return 0                 # never upgraded this session → upgrade now
  last="$(cat "$marker" 2>/dev/null || echo 0)"
  now="$(date +%s 2>/dev/null || echo 0)"
  [ $(( now - last )) -ge "$SB_SUMMARY_REFRESH_SECS" ] && return 0 || return 1
}

# ---------------------------------------------------------------------------
# Source/content filters (U9 expands these). For the slice, allow excluding a
# session by repo path or tool via env, comma-separated.
# ---------------------------------------------------------------------------
sb_excluded_tool() {
  case ",${SECOND_BRAIN_EXCLUDE_TOOLS:-}," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}

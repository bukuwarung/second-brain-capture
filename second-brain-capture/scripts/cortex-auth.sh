#!/usr/bin/env bash
# Cortex OAuth — mint and cache a client-credentials bearer token.
# Sourced by session-flush.sh. Exposes sb_cortex_token, which echoes a valid
# access token (refreshing when missing or near expiry) or returns non-zero.

SB_TOKEN_CACHE="${SECOND_BRAIN_TOKEN_CACHE:-${SB_BUFFER_DIR%/buffers}/.token-cache.json}"

# Echo a valid bearer token on stdout; return non-zero if one cannot be obtained.
sb_cortex_token() {
  if [ -z "$SB_OAUTH_CLIENT_ID" ] || [ -z "$SB_OAUTH_CLIENT_SECRET" ] || [ -z "$SB_TOKEN_URL" ]; then
    sb_log "cortex auth: missing client id/secret/token-url"
    return 1
  fi

  # Reuse a cached token with >60s of life left.
  if [ -f "$SB_TOKEN_CACHE" ]; then
    local now exp tok
    now="$(date +%s)"
    exp="$(jq -r '.expires_at // 0' "$SB_TOKEN_CACHE" 2>/dev/null || echo 0)"
    tok="$(jq -r '.access_token // empty' "$SB_TOKEN_CACHE" 2>/dev/null)"
    if [ -n "$tok" ] && [ "$((exp - now))" -gt 60 ]; then
      printf '%s' "$tok"
      return 0
    fi
  fi

  local body_file http now
  body_file="$(mktemp 2>/dev/null)" || return 1
  # client_secret_basic (Authorization: Basic) is what Cortex expects; the
  # client id/secret go in the header, not the body (RFC 6749 forbids both).
  http="$(curl -sS --max-time "$SB_REQUEST_TIMEOUT" \
    -o "$body_file" -w '%{http_code}' \
    -u "${SB_OAUTH_CLIENT_ID}:${SB_OAUTH_CLIENT_SECRET}" \
    -X POST "$SB_TOKEN_URL" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -H "Accept: application/json" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "scope=${SB_OAUTH_SCOPE}" \
    2>/dev/null)" || http=""

  if [ "$http" != "200" ]; then
    sb_log "cortex auth: token request failed http=$http"
    rm -f "$body_file"
    return 1
  fi

  local tok ttl
  tok="$(jq -r '.access_token // empty' "$body_file" 2>/dev/null)"
  ttl="$(jq -r '.expires_in // 3600' "$body_file" 2>/dev/null)"
  rm -f "$body_file"
  [ -z "$tok" ] && { sb_log "cortex auth: no access_token in response"; return 1; }

  now="$(date +%s)"
  mkdir -p "$(dirname "$SB_TOKEN_CACHE")" 2>/dev/null
  jq -nc --arg t "$tok" --argjson exp "$((now + ttl))" \
    '{access_token:$t, expires_at:$exp}' > "$SB_TOKEN_CACHE" 2>/dev/null
  chmod 600 "$SB_TOKEN_CACHE" 2>/dev/null
  printf '%s' "$tok"
  return 0
}

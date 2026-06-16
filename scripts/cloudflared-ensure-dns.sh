#!/usr/bin/env bash
#
# Idempotently upsert CNAME records pointing at the in-cluster cloudflared tunnel.
#
# Reads credentials from ./.env or ENV_FILE (override). The token used must
# have Zone:DNS:Edit on the target zone.
#
# Usage:
#   scripts/cloudflared-ensure-dns.sh                 # default dev-preview set
#   scripts/cloudflared-ensure-dns.sh host1 host2 ... # explicit list
#   DRY_RUN=1 scripts/cloudflared-ensure-dns.sh       # plan only
#
# Required env (from ENV_FILE):
#   CF_ZONE_ID
#   CF_TUNNEL_ID
#   One of CF_DNS_API_TOKEN or CF_API_TOKEN
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/../.env}"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; . "$ENV_FILE"; set +a
fi

TOKEN="${CF_DNS_API_TOKEN:-${CF_API_TOKEN:-}}"
: "${CF_ZONE_ID:?CF_ZONE_ID is required}"
: "${CF_TUNNEL_ID:?CF_TUNNEL_ID is required}"
: "${TOKEN:?CF_DNS_API_TOKEN or CF_API_TOKEN is required}"

TARGET="${CF_TUNNEL_ID}.cfargotunnel.com"

DEFAULT_HOSTS=(
  dev-dealmatch.yagamin.net
  dev-seller-dealmatch.yagamin.net
  dev-buyer-dealmatch.yagamin.net
  dev-pairs.yagamin.net
  dev-mensbar.yagamin.net
  dev-lilies.yagamin.net
  tv.yagamin.net
  dev-tv.yagamin.net
  dev-studio.yagamin.net
  deliver.yagamin.net
  dev-deliver.yagamin.net
  gitea.yagamin.net
)

if [[ $# -gt 0 ]]; then
  HOSTS=("$@")
else
  HOSTS=("${DEFAULT_HOSTS[@]}")
fi

api() {
  local method="$1" path="$2"
  shift 2
  curl -sS -X "$method" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4${path}" "$@"
}

for host in "${HOSTS[@]}"; do
  existing=$(api GET "/zones/${CF_ZONE_ID}/dns_records?type=CNAME&name=${host}")
  # Don't conflate "auth/zone error" with "no record exists". A GET that
  # doesn't return success=true would otherwise have `.result | length == 0`
  # and the script would happily POST a duplicate record (or fail loudly
  # only in real exec mode), masking misconfiguration.
  existing_ok=$(echo "$existing" | jq -r '.success // false')
  if [[ "$existing_ok" != "true" ]]; then
    echo "FAIL: GET dns_records for $host did not return success=true." >&2
    echo "$existing" | jq . >&2 2>/dev/null || echo "$existing" >&2
    exit 1
  fi
  count=$(echo "$existing" | jq -r '.result | length')
  desired_body=$(jq -nc \
    --arg name "$host" \
    --arg content "$TARGET" \
    '{type:"CNAME", name:$name, content:$content, ttl:1, proxied:true, comment:"managed by cloudflared-ensure-dns.sh"}')

  if [[ "$count" == "0" ]]; then
    if [[ "${DRY_RUN:-}" == "1" ]]; then
      echo "would CREATE  $host -> $TARGET"
    else
      resp=$(api POST "/zones/${CF_ZONE_ID}/dns_records" --data "$desired_body")
      ok=$(echo "$resp" | jq -r '.success')
      if [[ "$ok" != "true" ]]; then
        echo "FAIL create $host: $resp" >&2
        exit 1
      fi
      echo "created      $host -> $TARGET"
    fi
  else
    rec_id=$(echo "$existing" | jq -r '.result[0].id')
    rec_content=$(echo "$existing" | jq -r '.result[0].content')
    rec_proxied=$(echo "$existing" | jq -r '.result[0].proxied')
    if [[ "$rec_content" == "$TARGET" && "$rec_proxied" == "true" ]]; then
      echo "ok           $host (already CNAME -> $TARGET, proxied)"
      continue
    fi
    if [[ "${DRY_RUN:-}" == "1" ]]; then
      echo "would UPDATE $host: $rec_content (proxied=$rec_proxied) -> $TARGET (proxied=true)"
    else
      resp=$(api PUT "/zones/${CF_ZONE_ID}/dns_records/${rec_id}" --data "$desired_body")
      ok=$(echo "$resp" | jq -r '.success')
      if [[ "$ok" != "true" ]]; then
        echo "FAIL update $host: $resp" >&2
        exit 1
      fi
      echo "updated      $host -> $TARGET"
    fi
  fi
done

echo "done."

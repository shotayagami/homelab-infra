#!/usr/bin/env bash
#
# Clone a Cloudflare Access self-hosted application (app + policies) from an
# existing SRC domain to a DST domain, idempotently, via the CF API.
#
# Use case: stand up `dev-studio.yagamin.net` mirroring the Access policy of
# `studio.yagamin.net` ("踏襲"). Because the policies are copied verbatim from
# the live SRC app, the result tracks whatever SRC currently enforces (allowed
# emails / domains / Access Groups), without re-deriving them from .env.
#
# The Cloudflare Tunnel ingress route and DNS CNAME are handled separately by
#   scripts/cloudflared-push-tunnel-config.sh  (cloudflared/tunnel-config.yaml)
#   scripts/cloudflared-ensure-dns.sh
# This script only manages the Access application + its policies.
#
# Required env (from ENV_FILE / shell):
#   CF_API_TOKEN     token with Account:Access:Apps and Policies:Edit
#   CF_ACCOUNT_ID
#
# Optional env:
#   SRC_DOMAIN       default studio.yagamin.net
#   DST_DOMAIN       default dev-studio.yagamin.net
#   DST_APP_NAME     default: "<src app name> (dev)"
#   ENV_FILE         default ${HOME}/.env
#   DRY_RUN=1        plan only, no mutations
#
# Idempotency:
#   - DST app matched by domain; PUT if it exists, POST otherwise.
#   - DST policies matched by name; PUT if a same-name policy exists, POST otherwise.
#
# History:
#   2026-06-13 初版 (dev-studio.yagamin.net, studio.yagamin.net を踏襲)

set -euo pipefail

ENV_FILE="${ENV_FILE:-${HOME}/.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

SRC_DOMAIN="${SRC_DOMAIN:-studio.yagamin.net}"
DST_DOMAIN="${DST_DOMAIN:-dev-studio.yagamin.net}"

CF_API_BASE="https://api.cloudflare.com/client/v4"
CF_API_TOKEN="${CF_API_TOKEN:-}"
CF_ACCOUNT_ID="${CF_ACCOUNT_ID:-}"

require() { [[ -n "${!1:-}" ]] || { echo "ERROR: env $1 が未設定です" >&2; exit 1; }; }
require CF_API_TOKEN
require CF_ACCOUNT_ID

cf_api() {
  # NOTE: deliberately no `curl -f` — on HTTP 4xx/5xx the CF JSON error body
  # carries the actual reason; -f would discard it. We check `.success`/HTTP
  # code ourselves and surface .errors.
  local method="$1" path="$2" data="${3:-}" response http_code body
  if [[ -n "$data" ]]; then
    response="$(curl -sS -w $'\n%{http_code}' -X "$method" "${CF_API_BASE}${path}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json" --data "$data")" \
      || { echo "ERROR: curl $method ${path} failed (network)" >&2; return 1; }
  else
    response="$(curl -sS -w $'\n%{http_code}' -X "$method" "${CF_API_BASE}${path}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json")" \
      || { echo "ERROR: curl $method ${path} failed (network)" >&2; return 1; }
  fi
  http_code="${response##*$'\n'}"
  body="${response%$'\n'*}"
  if [[ "$(jq -r '.success // false' <<<"$body" 2>/dev/null)" != "true" ]]; then
    echo "ERROR: Cloudflare API failed for ${method} ${path} (HTTP ${http_code})" >&2
    jq '.errors // .' <<<"$body" >&2 2>/dev/null || echo "$body" >&2
    return 1
  fi
  echo "$body"
}

echo "==> Config"
echo "  SRC_DOMAIN = $SRC_DOMAIN"
echo "  DST_DOMAIN = $DST_DOMAIN"
echo "  DRY_RUN    = ${DRY_RUN:-0}"
echo

# ── 1. Locate the SRC Access app (match domain or self_hosted_domains) ─────────
apps="$(cf_api GET "/accounts/${CF_ACCOUNT_ID}/access/apps?per_page=1000")"

src_app="$(jq -c --arg d "$SRC_DOMAIN" \
  '[.result[] | select((.domain == $d) or ((.self_hosted_domains // []) | index($d)))][0] // empty' \
  <<<"$apps")"
if [[ -z "$src_app" ]]; then
  echo "ERROR: SRC Access app for domain '$SRC_DOMAIN' が見つかりません。" >&2
  echo "       先に studio.yagamin.net の Access App を用意してください。" >&2
  exit 1
fi
src_app_id="$(jq -r '.id' <<<"$src_app")"
src_app_name="$(jq -r '.name' <<<"$src_app")"
# Default DST name: drop a trailing "(<src domain>)" parenthetical from the SRC
# name, then append "(<DST domain>)". Keeps re-runs stable (PUT won't rename) and
# matches the SRC naming convention, e.g.
#   "ICS-TV Studio (studio.yagamin.net)" -> "ICS-TV Studio (dev-studio.yagamin.net)".
src_base="$src_app_name"
[[ "$src_base" =~ ^(.*[^[:space:]])[[:space:]]*\([^\)]*\)$ ]] && src_base="${BASH_REMATCH[1]}"
DST_APP_NAME="${DST_APP_NAME:-${src_base} (${DST_DOMAIN})}"
echo "==> SRC app: name='${src_app_name}' id=${src_app_id}"

# ── 2. Build the DST app payload from SRC (strip read-only / server fields) ────
# Copy SRC verbatim, then override identity (name/domain/destinations) and drop
# fields the API rejects on write or that are server-assigned.
# NOTE: the modern Access API keys self-hosted apps on `destinations` and
# requires `domain` to be one of them (error 12130 otherwise); we point all of
# domain / self_hosted_domains / destinations at the single DST public hostname.
dst_app_payload="$(jq -c \
  --arg name "$DST_APP_NAME" --arg d "$DST_DOMAIN" \
  'del(.id, .aud, .created_at, .updated_at, .uid, .domain_type, .policies, .scim_config)
   | .name = $name
   | .domain = $d
   | .self_hosted_domains = [$d]
   | .destinations = [{"type":"public","uri":$d}]' \
  <<<"$src_app")"

# ── 3. Locate existing DST app (idempotent by domain) ─────────────────────────
dst_app_id="$(jq -r --arg d "$DST_DOMAIN" \
  '[.result[] | select((.domain == $d) or ((.self_hosted_domains // []) | index($d)))][0].id // empty' \
  <<<"$apps")"

if [[ "${DRY_RUN:-}" == "1" ]]; then
  if [[ -n "$dst_app_id" ]]; then
    echo "would UPDATE DST app id=${dst_app_id} (domain=${DST_DOMAIN}, name='${DST_APP_NAME}')"
  else
    echo "would CREATE DST app (domain=${DST_DOMAIN}, name='${DST_APP_NAME}')"
  fi
else
  if [[ -n "$dst_app_id" ]]; then
    cf_api PUT "/accounts/${CF_ACCOUNT_ID}/access/apps/${dst_app_id}" "$dst_app_payload" >/dev/null
    echo "updated DST app id=${dst_app_id}"
  else
    created="$(cf_api POST "/accounts/${CF_ACCOUNT_ID}/access/apps" "$dst_app_payload")"
    dst_app_id="$(jq -r '.result.id' <<<"$created")"
    echo "created DST app id=${dst_app_id}"
  fi
fi

# ── 4. Clone policies (app-scoped) in SRC precedence order ─────────────────────
src_policies="$(cf_api GET "/accounts/${CF_ACCOUNT_ID}/access/apps/${src_app_id}/policies")"
n_pol="$(jq -r '.result | length' <<<"$src_policies")"
echo "==> SRC has ${n_pol} policy(ies); cloning to DST"

# DST policies snapshot for name-based idempotency (skip in dry-run / no app yet)
dst_policies='{"result":[]}'
if [[ -n "$dst_app_id" && "${DRY_RUN:-}" != "1" ]]; then
  dst_policies="$(cf_api GET "/accounts/${CF_ACCOUNT_ID}/access/apps/${dst_app_id}/policies")"
fi

# Iterate SRC policies sorted by precedence so DST ordering matches.
while IFS= read -r pol; do
  [[ -n "$pol" ]] || continue
  pname="$(jq -r '.name' <<<"$pol")"
  pol_payload="$(jq -c \
    'del(.id, .created_at, .updated_at, .uid, .app_id, .app_count, .reusable)' \
    <<<"$pol")"

  if [[ "${DRY_RUN:-}" == "1" ]]; then
    echo "  would CLONE policy '${pname}' (decision=$(jq -r '.decision' <<<"$pol"))"
    continue
  fi

  existing_pol_id="$(jq -r --arg n "$pname" \
    '[.result[] | select(.name == $n)][0].id // empty' <<<"$dst_policies")"
  if [[ -n "$existing_pol_id" ]]; then
    cf_api PUT "/accounts/${CF_ACCOUNT_ID}/access/apps/${dst_app_id}/policies/${existing_pol_id}" "$pol_payload" >/dev/null
    echo "  updated policy '${pname}'"
  else
    cf_api POST "/accounts/${CF_ACCOUNT_ID}/access/apps/${dst_app_id}/policies" "$pol_payload" >/dev/null
    echo "  created policy '${pname}'"
  fi
done < <(jq -c '.result | sort_by(.precedence // 0)[]' <<<"$src_policies")

echo
echo "done. DST app '${DST_APP_NAME}' (${DST_DOMAIN}) は SRC (${SRC_DOMAIN}) を踏襲。"
